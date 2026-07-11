-- Kairos Asset Management — esquema inicial de base de datos (Apex Strategy Fund)
-- Ejecutar en Supabase: SQL Editor > New query > pegar todo > Run

-- ============ FONDOS ============
-- id: generado por la app (texto), pensado para poder sumar más fondos en el futuro
create table fondos (
  id text primary key,
  nombre text not null,
  moneda text default 'USD',
  fecha_inicio date,
  estado text default 'Activo' check (estado in ('Activo','Inactivo')),
  notas text,
  created_at timestamptz default now()
);

-- ============ CUOTAPARTISTAS (inversores del fondo) ============
create table cuotapartistas (
  id text primary key,
  fondo_id text not null references fondos(id) on delete cascade,
  tipo_persona text check (tipo_persona in ('Física','Jurídica')),
  nombre_razon_social text not null,
  documento text,
  pais text,
  email text,
  telefono text,
  domicilio text,
  fecha_alta date default now(),
  estado text default 'Activo' check (estado in ('Activo','Inactivo')),
  notas text,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

-- ============ MOVIMIENTOS DE CUOTAPARTES (suscripciones y rescates — histórico, se acumula) ============
-- La cantidad_cuotapartes se calcula al momento de la carga: monto / valor_cuotaparte.
-- Suscripción sube la liquidez del fondo y las cuotapartes en circulación; Rescate a la inversa.
create table movimientos_cuotapartes (
  id text primary key,
  fondo_id text not null references fondos(id) on delete cascade,
  cuotapartista_id text not null references cuotapartistas(id) on delete cascade,
  fecha date not null,
  tipo text not null check (tipo in ('Suscripción','Rescate')),
  monto numeric not null,
  valor_cuotaparte numeric not null,
  cantidad_cuotapartes numeric not null,
  numero_comprobante text,
  notas text,
  created_at timestamptz default now()
);

-- ============ POSICIONES DEL FONDO (cartera actual — se reemplaza en cada actualización) ============
create table posiciones_fondo (
  id uuid primary key default gen_random_uuid(),
  fondo_id text not null references fondos(id) on delete cascade,
  tipo_activo text not null check (tipo_activo in ('Acción','Opción')),
  ticker text not null,
  subyacente text,
  tipo_opcion text check (tipo_opcion in ('Call','Put')),
  strike numeric,
  vencimiento date,
  cantidad numeric not null,
  precio_promedio numeric,
  precio_actual numeric,
  moneda text default 'USD',
  fecha_actualizacion timestamptz default now()
);

-- ============ OPERACIONES DEL FONDO (registro histórico — se acumula) ============
create table operaciones_fondo (
  id text primary key,
  fondo_id text not null references fondos(id) on delete cascade,
  fecha date not null,
  tipo_activo text check (tipo_activo in ('Acción','Opción')),
  ticker text not null,
  subyacente text,
  tipo_opcion text check (tipo_opcion in ('Call','Put')),
  strike numeric,
  vencimiento date,
  tipo_operacion text not null check (tipo_operacion in ('Compra','Venta')),
  cantidad numeric not null,
  precio numeric not null,
  comision numeric default 0,
  notas text,
  created_at timestamptz default now()
);

-- ============ LIQUIDEZ DEL FONDO (saldo de caja, una fila por fondo) ============
create table liquidez_fondo (
  fondo_id text primary key references fondos(id) on delete cascade,
  saldo numeric default 0,
  actualizado_el timestamptz default now()
);

-- ============ VALUACIONES HISTÓRICAS (snapshot de valor de cuotaparte en cada actualización) ============
create table valuaciones_fondo (
  id uuid primary key default gen_random_uuid(),
  fondo_id text not null references fondos(id) on delete cascade,
  fecha date not null,
  patrimonio_total numeric not null,
  cuotapartes_totales numeric not null,
  valor_cuotaparte numeric not null,
  created_at timestamptz default now()
);

-- ============ SEGURIDAD (RLS) ============
-- 1-2 usuarios internos, todos con acceso total.
alter table fondos enable row level security;
alter table cuotapartistas enable row level security;
alter table movimientos_cuotapartes enable row level security;
alter table posiciones_fondo enable row level security;
alter table operaciones_fondo enable row level security;
alter table liquidez_fondo enable row level security;
alter table valuaciones_fondo enable row level security;

create policy "usuarios logueados acceso total" on fondos for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "usuarios logueados acceso total" on cuotapartistas for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "usuarios logueados acceso total" on movimientos_cuotapartes for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "usuarios logueados acceso total" on posiciones_fondo for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "usuarios logueados acceso total" on operaciones_fondo for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "usuarios logueados acceso total" on liquidez_fondo for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "usuarios logueados acceso total" on valuaciones_fondo for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');

-- ============ FONDO INICIAL: APEX STRATEGY FUND ============
insert into fondos (id, nombre, moneda, fecha_inicio) values ('apex', 'Apex Strategy Fund', 'USD', current_date);
insert into liquidez_fondo (fondo_id, saldo) values ('apex', 0);
