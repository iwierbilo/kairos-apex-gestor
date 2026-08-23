-- Documentos del fondo: informes periódicos, posiciones agregadas, etc. — subidos por el
-- admin desde el panel, guardados en Supabase Storage (privado) y listados en el portal
-- del cliente. Mismo modelo de seguridad que el resto: cada cliente solo ve/descarga los
-- documentos del fondo donde tiene una posición.

-- ============ 1. TABLA ============
create table if not exists documentos_fondo (
  id uuid primary key default gen_random_uuid(),
  fondo_id text not null references fondos(id) on delete cascade,
  titulo text not null,
  categoria text,
  storage_path text not null,
  fecha date default current_date,
  created_at timestamptz default now()
);

alter table documentos_fondo enable row level security;
drop policy if exists "admins acceso total" on documentos_fondo;
create policy "admins acceso total" on documentos_fondo for all using (es_admin()) with check (es_admin());

-- ============ 2. STORAGE: bucket privado ============
insert into storage.buckets (id, name, public)
values ('documentos-fondo', 'documentos-fondo', false)
on conflict (id) do nothing;

-- Los archivos se guardan con path "{fondo_id}/{nombre}", así que
-- (storage.foldername(name))[1] es el fondo_id del archivo.
drop policy if exists "admins acceso total documentos" on storage.objects;
create policy "admins acceso total documentos" on storage.objects
  for all using (bucket_id = 'documentos-fondo' and es_admin())
  with check (bucket_id = 'documentos-fondo' and es_admin());

drop policy if exists "cliente lee documentos de su fondo" on storage.objects;
create policy "cliente lee documentos de su fondo" on storage.objects
  for select using (
    bucket_id = 'documentos-fondo'
    and (storage.foldername(name))[1] in (
      select c.fondo_id from cuotapartistas c
      join personas p on p.id = c.persona_id
      where p.auth_user_id = auth.uid()
    )
  );

-- ============ 3. FUNCIÓN DEL PANEL DEL CLIENTE ============
create or replace function mis_documentos(p_cuotapartista_id text)
returns table(id uuid, titulo text, categoria text, storage_path text, fecha date)
language plpgsql security definer as $$
#variable_conflict use_column
declare
  v_fondo_id text;
begin
  select c.fondo_id into v_fondo_id
    from cuotapartistas c join personas p on p.id = c.persona_id
    where c.id = p_cuotapartista_id and p.auth_user_id = auth.uid();
  if v_fondo_id is null then return; end if;

  return query select d.id, d.titulo, d.categoria, d.storage_path, d.fecha
    from documentos_fondo d where d.fondo_id = v_fondo_id order by d.fecha desc, d.created_at desc;
end;
$$;

revoke execute on function mis_documentos(text) from public, anon;
grant execute on function mis_documentos(text) to authenticated;
