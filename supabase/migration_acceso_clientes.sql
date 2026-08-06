-- Acceso de clientes al panel propio (portal de solo lectura, cliente.html).
--
-- Hasta ahora TODAS las tablas tenían una sola policy ("usuarios logueados acceso total")
-- que le daba acceso total a cualquiera que estuviera logueado. Eso alcanzaba mientras el
-- único login era el tuyo. Para darle acceso a los clientes hace falta distinguir "admin"
-- (acceso total, vos) de "cliente" (solo puede ver su propia ficha y su propio historial,
-- nunca los montos totales del fondo ni los de otros clientes).
--
-- Después de esta migración:
--   - Vos seguís teniendo acceso total (quedás en la tabla admins automáticamente).
--   - Un cliente nuevo NO tiene ningún acceso hasta que:
--       1) le creás su usuario en Authentication → Users (email + contraseña), y
--       2) desde su ficha en el panel admin, usás "Vincular acceso de cliente" con ese email.
--   - Un cliente logueado solo puede LEER (nunca escribir) su propia fila de cuotapartistas
--     y sus propios movimientos — nunca los de otro cliente.
--   - Un cliente NO tiene acceso directo a posiciones_fondo, lotes_fondo, liquidez_fondo,
--     operaciones_fondo, valuaciones_fondo, resultados_realizados_fondo ni analisis_opciones
--     (ahí es donde están los montos totales del fondo). Para su panel, en cambio, usa las
--     funciones de abajo (mi_ficha, composicion_cartera_publica, mis_movimientos), que
--     calculan del lado del servidor y devuelven solo lo que le corresponde ver.

-- ============ VINCULACIÓN CLIENTE ↔ USUARIO DE LOGIN ============
alter table cuotapartistas add column if not exists auth_user_id uuid unique references auth.users(id) on delete set null;

-- ============ ADMINS (staff interno — acceso total) ============
create table if not exists admins (
  auth_user_id uuid primary key references auth.users(id) on delete cascade,
  nombre text,
  created_at timestamptz default now()
);
alter table admins enable row level security;
drop policy if exists "un admin se ve a si mismo" on admins;
create policy "un admin se ve a si mismo" on admins for select using (auth_user_id = auth.uid());

-- Deja como admin a todo el que ya esté logueado hoy (o sea: vos). Cualquier cuenta nueva que
-- se cree DESPUÉS de correr esta migración (los clientes) no entra acá — hay que agregarla a mano.
insert into admins (auth_user_id) select id from auth.users on conflict do nothing;

create or replace function es_admin()
returns boolean language sql stable security definer as $$
  select exists(select 1 from admins where auth_user_id = auth.uid());
$$;

-- ============ REEMPLAZO DE POLICIES: admins acceso total + clientes acceso acotado ============
drop policy if exists "usuarios logueados acceso total" on fondos;
create policy "admins acceso total" on fondos for all using (es_admin()) with check (es_admin());

drop policy if exists "usuarios logueados acceso total" on cuotapartistas;
create policy "admins acceso total" on cuotapartistas for all using (es_admin()) with check (es_admin());
create policy "cliente ve su propia ficha" on cuotapartistas for select using (auth_user_id = auth.uid());

drop policy if exists "usuarios logueados acceso total" on movimientos_cuotapartes;
create policy "admins acceso total" on movimientos_cuotapartes for all using (es_admin()) with check (es_admin());
create policy "cliente ve sus propios movimientos" on movimientos_cuotapartes for select using (
  cuotapartista_id in (select id from cuotapartistas where auth_user_id = auth.uid())
);

-- Estas quedan solo para admins — sin policy de cliente (RLS deniega por defecto lo que no
-- matchea ninguna policy). El panel del cliente accede a esto indirectamente vía las
-- funciones más abajo, nunca leyendo la tabla entera.
drop policy if exists "usuarios logueados acceso total" on posiciones_fondo;
create policy "admins acceso total" on posiciones_fondo for all using (es_admin()) with check (es_admin());

drop policy if exists "usuarios logueados acceso total" on operaciones_fondo;
create policy "admins acceso total" on operaciones_fondo for all using (es_admin()) with check (es_admin());

drop policy if exists "usuarios logueados acceso total" on liquidez_fondo;
create policy "admins acceso total" on liquidez_fondo for all using (es_admin()) with check (es_admin());

drop policy if exists "usuarios logueados acceso total" on valuaciones_fondo;
create policy "admins acceso total" on valuaciones_fondo for all using (es_admin()) with check (es_admin());

drop policy if exists "usuarios logueados acceso total" on lotes_fondo;
create policy "admins acceso total" on lotes_fondo for all using (es_admin()) with check (es_admin());

drop policy if exists "usuarios logueados acceso total" on resultados_realizados_fondo;
create policy "admins acceso total" on resultados_realizados_fondo for all using (es_admin()) with check (es_admin());

drop policy if exists "usuarios logueados acceso total" on analisis_opciones;
create policy "admins acceso total" on analisis_opciones for all using (es_admin()) with check (es_admin());

-- ============ FUNCIONES PARA EL PANEL DEL CLIENTE ============
-- Todas son security definer (corren con permisos elevados) pero cada una arranca
-- ubicando al cuotapartista del usuario logueado (auth.uid()) — si no hay ficha vinculada,
-- devuelven vacío. Nunca reciben ni devuelven el id de otro cliente ni montos totales del fondo.

create or replace function mi_ficha()
returns table(
  nombre text, tipo_persona text, estado text,
  cuotapartes numeric, valor_cuotaparte numeric, valor_actual numeric, rendimiento_pct numeric
)
language plpgsql security definer as $$
declare
  v_id text;
  v_fondo_id text;
  v_tenencia numeric;
  v_valor_cuota numeric;
  v_susc numeric;
  v_resc numeric;
begin
  select id, fondo_id into v_id, v_fondo_id from cuotapartistas where auth_user_id = auth.uid();
  if v_id is null then return; end if;

  select coalesce(sum(case when tipo='Suscripción' then cantidad_cuotapartes else -cantidad_cuotapartes end),0)
    into v_tenencia from movimientos_cuotapartes where cuotapartista_id = v_id;

  select coalesce(sum(case when tipo='Suscripción' then monto else 0 end),0),
         coalesce(sum(case when tipo='Rescate' then monto else 0 end),0)
    into v_susc, v_resc from movimientos_cuotapartes where cuotapartista_id = v_id;

  select vf.valor_cuotaparte into v_valor_cuota from valuaciones_fondo vf
    where vf.fondo_id = v_fondo_id order by vf.fecha desc limit 1;

  return query
    select c.nombre_razon_social, c.tipo_persona, c.estado,
      v_tenencia,
      v_valor_cuota,
      (v_tenencia * coalesce(v_valor_cuota,0)),
      (case when v_susc>0 then ((v_tenencia*coalesce(v_valor_cuota,0) + v_resc - v_susc)/v_susc*100) else null end)
    from cuotapartistas c where c.id = v_id;
end;
$$;

create or replace function mis_movimientos()
returns table(fecha date, tipo text, monto numeric, valor_cuotaparte numeric, cantidad_cuotapartes numeric, numero_comprobante text)
language plpgsql security definer as $$
declare
  v_id text;
begin
  select id into v_id from cuotapartistas where auth_user_id = auth.uid();
  if v_id is null then return; end if;
  return query
    select m.fecha, m.tipo, m.monto, m.valor_cuotaparte, m.cantidad_cuotapartes, m.numero_comprobante
    from movimientos_cuotapartes m where m.cuotapartista_id = v_id order by m.fecha desc;
end;
$$;

-- % de cada instrumento sobre el patrimonio del fondo (cartera a precio actual + liquidez).
-- Deliberadamente NO devuelve ningún monto en dólares, solo el nombre y el %.
-- Nota: a diferencia del panel admin, esta versión no agrupa en "Otros" pasado 8 rubros —
-- con la cantidad de posiciones actual no hace falta; si el fondo crece mucho en variedad
-- de instrumentos, conviene revisarlo.
create or replace function composicion_cartera_publica()
returns table(instrumento text, pct numeric)
language plpgsql security definer as $$
declare
  v_fondo_id text;
  v_total numeric;
begin
  select fondo_id into v_fondo_id from cuotapartistas where auth_user_id = auth.uid() limit 1;
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

-- ============ VINCULAR EL LOGIN DE UN CLIENTE A SU FICHA (solo admins) ============
create or replace function vincular_acceso_cliente(p_cuotapartista_id text, p_email text)
returns void language plpgsql security definer as $$
declare
  v_user_id uuid;
begin
  if not es_admin() then
    raise exception 'No autorizado.';
  end if;
  select id into v_user_id from auth.users where lower(email) = lower(p_email) limit 1;
  if v_user_id is null then
    raise exception 'No existe ningún usuario con ese email — creálo primero en Authentication → Users.';
  end if;
  update cuotapartistas set auth_user_id = v_user_id where id = p_cuotapartista_id;
end;
$$;

revoke execute on function mi_ficha() from public, anon;
revoke execute on function mis_movimientos() from public, anon;
revoke execute on function composicion_cartera_publica() from public, anon;
revoke execute on function vincular_acceso_cliente(text, text) from public, anon;
grant execute on function mi_ficha() to authenticated;
grant execute on function mis_movimientos() to authenticated;
grant execute on function composicion_cartera_publica() to authenticated;
grant execute on function vincular_acceso_cliente(text, text) to authenticated;
