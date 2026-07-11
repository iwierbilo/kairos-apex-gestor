-- Kairos / Apex Strategy Fund: lotes FIFO y resultados realizados por operación cerrada.
-- No borra datos existentes (posiciones_fondo no tiene cantidad/precio_promedio en uso todavía).

-- ============ LOTES (cada compra sin cerrar del todo — fondo long-only) ============
create table lotes_fondo (
  id uuid primary key default gen_random_uuid(),
  fondo_id text not null references fondos(id) on delete cascade,
  tipo_activo text not null check (tipo_activo in ('Acción','Opción')),
  ticker text not null,
  subyacente text,
  tipo_opcion text check (tipo_opcion in ('Call','Put')),
  strike numeric,
  vencimiento date,
  fecha_apertura date not null,
  cantidad_original numeric not null,
  cantidad_restante numeric not null,
  precio_apertura numeric not null,
  comision_apertura numeric default 0,
  operacion_apertura_id text,
  created_at timestamptz default now()
);

-- ============ RESULTADOS REALIZADOS (cada cierre FIFO, total o parcial) ============
create table resultados_realizados_fondo (
  id uuid primary key default gen_random_uuid(),
  fondo_id text not null references fondos(id) on delete cascade,
  tipo_activo text not null check (tipo_activo in ('Acción','Opción')),
  ticker text not null,
  subyacente text,
  tipo_opcion text check (tipo_opcion in ('Call','Put')),
  strike numeric,
  vencimiento date,
  fecha_apertura date not null,
  fecha_cierre date not null,
  cantidad numeric not null,
  precio_apertura numeric not null,
  precio_cierre numeric not null,
  comision_apertura numeric default 0,
  comision_cierre numeric default 0,
  resultado numeric not null,
  dias_en_posicion int,
  operacion_cierre_id text,
  created_at timestamptz default now()
);

-- posiciones_fondo pasa a ser solo una caché de precio de mercado por instrumento
-- (la cantidad y el precio de entrada ahora se derivan de los lotes abiertos).
alter table posiciones_fondo drop column if exists cantidad;
alter table posiciones_fondo drop column if exists precio_promedio;

alter table lotes_fondo enable row level security;
alter table resultados_realizados_fondo enable row level security;
create policy "usuarios logueados acceso total" on lotes_fondo for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "usuarios logueados acceso total" on resultados_realizados_fondo for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
