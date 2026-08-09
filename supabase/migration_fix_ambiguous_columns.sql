-- Corrige "column reference is ambiguous" en las funciones del panel del cliente.
--
-- Causa: al declarar `returns table(..., valor_cuotaparte numeric, ...)`, Postgres crea una
-- variable interna con ese mismo nombre dentro de la función. Si adentro hay una consulta que
-- usa una columna real llamada igual (valuaciones_fondo.valor_cuotaparte) sin aclarar de qué
-- tabla es, no sabe si es la variable o la columna, y tira el error 42702.
--
-- La corrección es agregar `#variable_conflict use_column` como primera línea del cuerpo de
-- cada función: le dice a Postgres que, ante esa ambigüedad, siempre prefiera la columna de la
-- tabla (que es lo que queríamos en las cinco funciones de acá abajo).

create or replace function mis_fondos()
returns table(cuotapartista_id text, fondo_id text, fondo_nombre text, cuotapartes numeric, valor_cuotaparte numeric, valor_actual numeric)
language plpgsql security definer as $$
#variable_conflict use_column
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

create or replace function mi_ficha(p_cuotapartista_id text)
returns table(
  nombre text, fondo_nombre text, estado text,
  cuotapartes numeric, valor_cuotaparte numeric, valor_actual numeric, rendimiento_pct numeric
)
language plpgsql security definer as $$
#variable_conflict use_column
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
#variable_conflict use_column
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
#variable_conflict use_column
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

create or replace function historial_valor_cuotaparte(p_cuotapartista_id text)
returns table(fecha date, valor_cuotaparte numeric)
language plpgsql security definer as $$
#variable_conflict use_column
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
