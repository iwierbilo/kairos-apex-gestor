-- Puente con el onboarding externo (proyecto aparte en Vercel).
--
-- El formulario de onboarding NO crea un cliente directo — manda el payload completo a una
-- Edge Function (ver supabase/functions/onboarding-nueva-solicitud), que lo guarda acá como
-- una solicitud "Pendiente". Un admin la revisa en el panel y decide Aprobar (recién ahí se
-- crea la persona + el cuotapartista + un número de cuenta secuencial, ej. APEX-0001) o
-- Rechazar. El onboarding nunca tiene acceso directo a crear clientes.

-- ============ 1. NÚMERO DE CUENTA POR CUOTAPARTISTA ============
alter table cuotapartistas add column if not exists numero_cuenta text unique;

-- Contador y prefijo por fondo para asignar el próximo número (ej. 'APEX' + 1 -> 'APEX-0001').
alter table fondos add column if not exists siguiente_numero_cuenta int not null default 1;
alter table fondos add column if not exists prefijo_cuenta text;
update fondos set prefijo_cuenta = upper(id) where prefijo_cuenta is null;

-- ============ 2. BANDEJA DE SOLICITUDES ============
create table if not exists onboarding_solicitudes (
  id uuid primary key default gen_random_uuid(),
  fondo_id text not null references fondos(id) on delete cascade,
  estado text not null default 'Pendiente' check (estado in ('Pendiente','Aprobada','Rechazada')),

  -- Campos principales para mostrar en la bandeja sin tener que abrir el JSON completo.
  nombre_razon_social text not null,
  tipo_persona text,
  documento text,
  email text,
  telefono text,
  pais text,
  provincia text,
  localidad text,
  domicilio text,
  monto_solicitado numeric,

  datos jsonb, -- payload completo tal como lo mandó el onboarding (KYC, perfil, docs, agreement...)

  persona_id text references personas(id),
  cuotapartista_id text references cuotapartistas(id),
  numero_cuenta text,
  motivo_rechazo text,

  created_at timestamptz default now(),
  revisado_at timestamptz,
  revisado_por uuid references auth.users(id)
);

alter table onboarding_solicitudes enable row level security;
drop policy if exists "admins acceso total" on onboarding_solicitudes;
create policy "admins acceso total" on onboarding_solicitudes for all using (es_admin()) with check (es_admin());
-- Sin policy para nadie más: la Edge Function inserta con la service role key (que salta RLS),
-- así que el onboarding externo no necesita ni puede tener acceso directo a esta tabla.

-- ============ 3. APROBAR / RECHAZAR (solo admins) ============
create or replace function aprobar_solicitud_onboarding(p_solicitud_id uuid)
returns table(persona_id text, cuotapartista_id text, numero_cuenta text)
language plpgsql security definer as $$
#variable_conflict use_column
declare
  v_sol record;
  v_persona_id text;
  v_cuotapartista_id text;
  v_prefijo text;
  v_numero int;
  v_numero_cuenta text;
begin
  if not es_admin() then
    raise exception 'No autorizado.';
  end if;

  select * into v_sol from onboarding_solicitudes where id = p_solicitud_id and estado = 'Pendiente';
  if v_sol.id is null then
    raise exception 'La solicitud no existe o ya fue revisada.';
  end if;

  -- Próximo número de cuenta del fondo, de forma atómica.
  update fondos set siguiente_numero_cuenta = siguiente_numero_cuenta + 1
    where id = v_sol.fondo_id
    returning prefijo_cuenta, siguiente_numero_cuenta - 1 into v_prefijo, v_numero;
  v_numero_cuenta := coalesce(v_prefijo, upper(v_sol.fondo_id)) || '-' || lpad(v_numero::text, 4, '0');

  v_persona_id := 'k_' || replace(gen_random_uuid()::text, '-', '');
  insert into personas (id, tipo_persona, nombre_razon_social, documento, pais, provincia, localidad, email, telefono, domicilio, fecha_alta, notas)
  values (v_persona_id, v_sol.tipo_persona, v_sol.nombre_razon_social, v_sol.documento, v_sol.pais, v_sol.provincia, v_sol.localidad, v_sol.email, v_sol.telefono, v_sol.domicilio, current_date,
    'Alta vía onboarding — solicitud ' || p_solicitud_id::text);

  v_cuotapartista_id := 'k_' || replace(gen_random_uuid()::text, '-', '');
  insert into cuotapartistas (id, fondo_id, persona_id, estado, numero_cuenta)
  values (v_cuotapartista_id, v_sol.fondo_id, v_persona_id, 'Activo', v_numero_cuenta);

  update onboarding_solicitudes set
    estado = 'Aprobada',
    persona_id = v_persona_id,
    cuotapartista_id = v_cuotapartista_id,
    numero_cuenta = v_numero_cuenta,
    revisado_at = now(),
    revisado_por = auth.uid()
  where id = p_solicitud_id;

  return query select v_persona_id, v_cuotapartista_id, v_numero_cuenta;
end;
$$;

create or replace function rechazar_solicitud_onboarding(p_solicitud_id uuid, p_motivo text)
returns void language plpgsql security definer as $$
begin
  if not es_admin() then
    raise exception 'No autorizado.';
  end if;
  update onboarding_solicitudes
    set estado = 'Rechazada', motivo_rechazo = p_motivo, revisado_at = now(), revisado_por = auth.uid()
    where id = p_solicitud_id and estado = 'Pendiente';
end;
$$;

revoke execute on function aprobar_solicitud_onboarding(uuid) from public, anon;
revoke execute on function rechazar_solicitud_onboarding(uuid, text) from public, anon;
grant execute on function aprobar_solicitud_onboarding(uuid) to authenticated;
grant execute on function rechazar_solicitud_onboarding(uuid, text) to authenticated;
