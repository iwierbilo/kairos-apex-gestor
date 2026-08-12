-- Hace que el panel del cliente calcule el valor de cuotaparte EN VIVO (con los precios
-- actuales de la cartera), igual que el panel admin — en vez de leer la última valuación
-- diaria guardada (que puede estar desactualizada si los precios se movieron desde el
-- último cierre/cron). historial_valor_cuotaparte() no se toca: ese sigue mostrando el
-- histórico real día por día, que es lo correcto para el gráfico de evolución.

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
  v_patrimonio_cartera numeric;
  v_liquidez numeric;
  v_cuotapartes_totales numeric;
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

  -- Cartera a precio actual (misma lógica que composicion_cartera_publica / patrimonioCartera()
  -- del admin): suma cada lote abierto a su precio de mercado cacheado en posiciones_fondo.
  select coalesce(sum(
    (select coalesce(pr.precio_actual,0) from posiciones_fondo pr
     where pr.fondo_id = v_fondo_id
       and (pr.ticker||'|'||coalesce(pr.tipo_opcion,'')||'|'||coalesce(pr.strike::text,'')||'|'||coalesce(pr.vencimiento::text,''))
         = (l.ticker||'|'||coalesce(l.tipo_opcion,'')||'|'||coalesce(l.strike::text,'')||'|'||coalesce(l.vencimiento::text,''))
     limit 1
    ) * l.cantidad_restante * (case when l.tipo_activo='Opción' then 100 else 1 end)
  ),0) into v_patrimonio_cartera
  from lotes_fondo l where l.fondo_id = v_fondo_id and l.cantidad_restante > 0;

  select coalesce(saldo,0) into v_liquidez from liquidez_fondo where fondo_id = v_fondo_id;

  -- Cuotapartes totales de TODO el fondo (no solo las de esta persona) — es el denominador
  -- real del valor de cuotaparte, igual que cuotapartesTotalesFondo() en el admin.
  select coalesce(sum(case when m2.tipo='Suscripción' then m2.cantidad_cuotapartes else -m2.cantidad_cuotapartes end),0)
    into v_cuotapartes_totales
    from movimientos_cuotapartes m2
    join cuotapartistas c2 on c2.id = m2.cuotapartista_id
    where c2.fondo_id = v_fondo_id;

  if v_cuotapartes_totales > 0 then
    v_valor_cuota := (v_patrimonio_cartera + v_liquidez) / v_cuotapartes_totales;
  else
    v_valor_cuota := null;
  end if;

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
