-- Separar "persona" (identidad) de "cuotapartista" (posición en UN fondo puntual).
--
-- Hasta ahora una fila de `cuotapartistas` mezclaba los datos personales (nombre, documento,
-- país, email...) con la posición en el fondo (fondo_id, estado, movimientos). Como Kairos va a
-- tener más de un fondo, una misma persona podría invertir en varios — con el modelo viejo
-- necesitaría una ficha completa duplicada por cada fondo. Esta migración separa eso:
--
--   personas          → identidad de la persona/empresa (una fila por cliente real, sin importar
--                        en cuántos fondos invierta). Acá vive el login (auth_user_id).
--   cuotapartistas     → una fila por (persona, fondo): solo fondo_id, persona_id y estado. Los
--                        movimientos, lotes, etc. siguen colgando de cuotapartistas.id como antes
--                        (los ids no cambian, así que no hace falta tocar movimientos_cuotapartes).
--
-- Es seguro re-correrla si se corta a mitad de camino: los pasos son idempotentes donde se pudo
-- (create table if not exists, add column if not exists), salvo los "alter table ... drop column"
-- del final, que fallan silenciosamente la segunda vez si la columna ya no existe — no rompen nada.

-- ============ 1. CREAR personas Y COPIAR LOS DATOS ACTUALES ============
create table if not exists personas (
  id text primary key,
  tipo_persona text check (tipo_persona in ('Física','Jurídica')),
  nombre_razon_social text not null,
  documento text,
  pais text,
  provincia text,
  localidad text,
  email text,
  telefono text,
  domicilio text,
  fecha_alta date default now(),
  notas text,
  auth_user_id uuid unique references auth.users(id) on delete set null,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

insert into personas (id, tipo_persona, nombre_razon_social, documento, pais, provincia, localidad, email, telefono, domicilio, fecha_alta, notas, auth_user_id, created_at)
select id, tipo_persona, nombre_razon_social, documento, pais, provincia, localidad, email, telefono, domicilio, fecha_alta, notas, auth_user_id, created_at
from cuotapartistas
on conflict (id) do nothing;

-- ============ 2. VINCULAR cuotapartistas A SU PERSONA (mismo id — es 1 a 1 hoy) ============
alter table cuotapartistas add column if not exists persona_id text references personas(id);
update cuotapartistas set persona_id = id where persona_id is null;
alter table cuotapartistas alter column persona_id set not null;

-- ============ 3. QUITAR DE cuotapartistas LO QUE AHORA VIVE EN personas ============
-- Primero hay que soltar las policies viejas que todavía dependen de cuotapartistas.auth_user_id
-- (si no, Postgres no deja borrar la columna).
drop policy if exists "cliente ve su propia ficha" on cuotapartistas;
drop policy if exists "cliente ve sus propios movimientos" on movimientos_cuotapartes;

alter table cuotapartistas
  drop column if exists tipo_persona,
  drop column if exists nombre_razon_social,
  drop column if exists documento,
  drop column if exists pais,
  drop column if exists provincia,
  drop column if exists localidad,
  drop column if exists email,
  drop column if exists telefono,
  drop column if exists domicilio,
  drop column if exists fecha_alta,
  drop column if exists notas,
  drop column if exists auth_user_id,
  drop column if exists updated_at;

-- ============ 4. RLS DE personas ============
alter table personas enable row level security;
drop policy if exists "admins acceso total" on personas;
create policy "admins acceso total" on personas for all using (es_admin()) with check (es_admin());
drop policy if exists "cliente ve su propia persona" on personas;
create policy "cliente ve su propia persona" on personas for select using (auth_user_id = auth.uid());

-- ============ 5. ACTUALIZAR POLICIES QUE APUNTABAN A cuotapartistas.auth_user_id ============
drop policy if exists "cliente ve su propia ficha" on cuotapartistas;
create policy "cliente ve sus posiciones" on cuotapartistas for select using (
  persona_id in (select id from personas where auth_user_id = auth.uid())
);

drop policy if exists "cliente ve sus propios movimientos" on movimientos_cuotapartes;
create policy "cliente ve sus propios movimientos" on movimientos_cuotapartes for select using (
  cuotapartista_id in (
    select c.id from cuotapartistas c join personas p on p.id = c.persona_id
    where p.auth_user_id = auth.uid()
  )
);

-- ============ 6. FUNCIONES DEL PANEL DEL CLIENTE — ahora multi-fondo ============
-- Todas reciben (cuando corresponde) el id de la posición puntual (cuotapartista_id) y
-- verifican que esa posición pertenezca a la persona logueada antes de devolver nada.

drop function if exists mi_ficha();
drop function if exists mis_movimientos();
drop function if exists composicion_cartera_publica();

-- Lista de fondos donde la persona logueada tiene una posición — para "Tu cartera de inversión".
create or replace function mis_fondos()
returns table(cuotapartista_id text, fondo_id text, fondo_nombre text, cuotapartes numeric, valor_cuotaparte numeric, valor_actual numeric)
language plpgsql security definer as $$
declare
  v_persona_id text;
begin
  select id into v_persona_id from personas where auth_user_id = auth.uid();
  if v_persona_id is null then return; end if;

  return query
    select
      c.id,
      c.fondo_id,
      f.nombre,
      coalesce(tenencia.cantidad, 0) as cuotapartes,
      vf.valor_cuotaparte,
      coalesce(tenencia.cantidad, 0) * coalesce(vf.valor_cuotaparte, 0) as valor_actual
    from cuotapartistas c
    join fondos f on f.id = c.fondo_id
    left join lateral (
      select sum(case when m.tipo='Suscripción' then m.cantidad_cuotapartes else -m.cantidad_cuotapartes end) as cantidad
      from movimientos_cuotapartes m where m.cuotapartista_id = c.id
    ) tenencia on true
    left join lateral (
      select valor_cuotaparte from valuaciones_fondo where fondo_id = c.fondo_id order by fecha desc limit 1
    ) vf on true
    where c.persona_id = v_persona_id;
end;
$$;

-- Detalle de UNA posición puntual (un fondo) — para cuando el cliente entra a ver ese fondo.
create or replace function mi_ficha(p_cuotapartista_id text)
returns table(
  nombre text, fondo_nombre text, estado text,
  cuotapartes numeric, valor_cuotaparte numeric, valor_actual numeric, rendimiento_pct numeric
)
language plpgsql security definer as $$
declare
  v_persona_id text;
  v_fondo_id text;
  v_tenencia numeric;
  v_valor_cuota numeric;
  v_susc numeric;
  v_resc numeric;
begin
  select c.persona_id, c.fondo_id into v_persona_id, v_fondo_id
    from cuotapartistas c join personas p on p.id = c.persona_id
    where c.id = p_cuotapartista_id and p.auth_user_id = auth.uid();
  if v_persona_id is null then return; end if;

  select coalesce(sum(case when tipo='Suscripción' then cantidad_cuotapartes else -cantidad_cuotapartes end),0)
    into v_tenencia from movimientos_cuotapartes where cuotapartista_id = p_cuotapartista_id;

  select coalesce(sum(case when tipo='Suscripción' then monto else 0 end),0),
         coalesce(sum(case when tipo='Rescate' then monto else 0 end),0)
    into v_susc, v_resc from movimientos_cuotapartes where cuotapartista_id = p_cuotapartista_id;

  select vf.valor_cuotaparte into v_valor_cuota from valuaciones_fondo vf
    where vf.fondo_id = v_fondo_id order by vf.fecha desc limit 1;

  return query
    select p.nombre_razon_social, f.nombre, c.estado,
      v_tenencia,
      v_valor_cuota,
      (v_tenencia * coalesce(v_valor_cuota,0)),
      (case when v_susc>0 then ((v_tenencia*coalesce(v_valor_cuota,0) + v_resc - v_susc)/v_susc*100) else null end)
    from cuotapartistas c
    join personas p on p.id = c.persona_id
    join fondos f on f.id = c.fondo_id
    where c.id = p_cuotapartista_id;
end;
$$;

create or replace function mis_movimientos(p_cuotapartista_id text)
returns table(fecha date, tipo text, monto numeric, valor_cuotaparte numeric, cantidad_cuotapartes numeric, numero_comprobante text)
language plpgsql security definer as $$
declare
  v_ok boolean;
begin
  select exists(
    select 1 from cuotapartistas c join personas p on p.id = c.persona_id
    where c.id = p_cuotapartista_id and p.auth_user_id = auth.uid()
  ) into v_ok;
  if not v_ok then return; end if;

  return query
    select m.fecha, m.tipo, m.monto, m.valor_cuotaparte, m.cantidad_cuotapartes, m.numero_comprobante
    from movimientos_cuotapartes m where m.cuotapartista_id = p_cuotapartista_id order by m.fecha desc;
end;
$$;

create or replace function composicion_cartera_publica(p_cuotapartista_id text)
returns table(instrumento text, pct numeric)
language plpgsql security definer as $$
declare
  v_fondo_id text;
  v_total numeric;
begin
  select c.fondo_id into v_fondo_id
    from cuotapartistas c join personas p on p.id = c.persona_id
    where c.id = p_cuotapartista_id and p.auth_user_id = auth.uid();
  if v_fondo_id is null then return; end if;

  with agregados as (
    select
      (l.ticker || '|' || coalesce(l.tipo_opcion,'') || '|' || coalesce(l.strike::text,'') || '|' || coalesce(l.vencimiento::text,'')) as clave,
      l.ticker, l.tipo_activo,
      sum(l.cantidad_restante) as cantidad
    from lotes_fondo l
    where l.fondo_id = v_fondo_id and l.cantidad_restante > 0
    group by clave, l.ticker, l.tipo_activo
  ),
  precios as (
    select
      (p.ticker || '|' || coalesce(p.tipo_opcion,'') || '|' || coalesce(p.strike::text,'') || '|' || coalesce(p.vencimiento::text,'')) as clave,
      p.precio_actual
    from posiciones_fondo p where p.fondo_id = v_fondo_id
  ),
  valores as (
    select a.ticker as label, (a.cantidad * coalesce(pr.precio_actual,0) * (case when a.tipo_activo='Opción' then 100 else 1 end)) as valor
    from agregados a left join precios pr using (clave)
  ),
  con_liquidez as (
    select label, valor from valores where valor > 0
    union all
    select 'Liquidez' as label, saldo as valor from liquidez_fondo where fondo_id = v_fondo_id and saldo > 0
  )
  select coalesce(sum(valor),0) into v_total from con_liquidez;

  if v_total <= 0 then return; end if;

  return query
    with agregados as (
      select
        (l.ticker || '|' || coalesce(l.tipo_opcion,'') || '|' || coalesce(l.strike::text,'') || '|' || coalesce(l.vencimiento::text,'')) as clave,
        l.ticker, l.tipo_activo,
        sum(l.cantidad_restante) as cantidad
      from lotes_fondo l
      where l.fondo_id = v_fondo_id and l.cantidad_restante > 0
      group by clave, l.ticker, l.tipo_activo
    ),
    precios as (
      select
        (p.ticker || '|' || coalesce(p.tipo_opcion,'') || '|' || coalesce(p.strike::text,'') || '|' || coalesce(p.vencimiento::text,'')) as clave,
        p.precio_actual
      from posiciones_fondo p where p.fondo_id = v_fondo_id
    ),
    valores as (
      select a.ticker as label, (a.cantidad * coalesce(pr.precio_actual,0) * (case when a.tipo_activo='Opción' then 100 else 1 end)) as valor
      from agregados a left join precios pr using (clave)
    ),
    con_liquidez as (
      select label, valor from valores where valor > 0
      union all
      select 'Liquidez' as label, saldo as valor from liquidez_fondo where fondo_id = v_fondo_id and saldo > 0
    )
    select label as instrumento, (valor/v_total*100) as pct from con_liquidez order by valor desc;
end;
$$;

-- Historial del valor de cuotaparte de UN fondo (para el gráfico de evolución del cliente).
-- Solo valor_cuotaparte + fecha — nunca patrimonio_total ni cuotapartes_totales (revelarían AUM).
create or replace function historial_valor_cuotaparte(p_cuotapartista_id text)
returns table(fecha date, valor_cuotaparte numeric)
language plpgsql security definer as $$
declare
  v_fondo_id text;
begin
  select c.fondo_id into v_fondo_id
    from cuotapartistas c join personas p on p.id = c.persona_id
    where c.id = p_cuotapartista_id and p.auth_user_id = auth.uid();
  if v_fondo_id is null then return; end if;

  return query
    select vf.fecha, vf.valor_cuotaparte from valuaciones_fondo vf
    where vf.fondo_id = v_fondo_id order by vf.fecha asc;
end;
$$;

-- ============ 7. VINCULAR ACCESO — ahora vincula el email a la PERSONA, no a la posición ============
create or replace function vincular_acceso_cliente(p_cuotapartista_id text, p_email text)
returns void language plpgsql security definer as $$
declare
  v_user_id uuid;
  v_persona_id text;
begin
  if not es_admin() then
    raise exception 'No autorizado.';
  end if;
  select persona_id into v_persona_id from cuotapartistas where id = p_cuotapartista_id;
  if v_persona_id is null then
    raise exception 'No existe esa ficha.';
  end if;
  select id into v_user_id from auth.users where lower(email) = lower(p_email) limit 1;
  if v_user_id is null then
    raise exception 'No existe ningún usuario con ese email — creálo primero en Authentication → Users.';
  end if;
  update personas set auth_user_id = v_user_id where id = v_persona_id;
end;
$$;

-- ============ 8. PERMISOS ============
revoke execute on function mis_fondos() from public, anon;
revoke execute on function mi_ficha(text) from public, anon;
revoke execute on function mis_movimientos(text) from public, anon;
revoke execute on function composicion_cartera_publica(text) from public, anon;
revoke execute on function historial_valor_cuotaparte(text) from public, anon;
revoke execute on function vincular_acceso_cliente(text, text) from public, anon;
grant execute on function mis_fondos() to authenticated;
grant execute on function mi_ficha(text) to authenticated;
grant execute on function mis_movimientos(text) to authenticated;
grant execute on function composicion_cartera_publica(text) to authenticated;
grant execute on function historial_valor_cuotaparte(text) to authenticated;
grant execute on function vincular_acceso_cliente(text, text) to authenticated;
