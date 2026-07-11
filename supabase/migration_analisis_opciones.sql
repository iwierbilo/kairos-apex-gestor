-- Gestor de Opciones: workspace de análisis de ideas de opciones (independiente de la cartera real).
-- No borra nada existente.

create table analisis_opciones (
  id text primary key,
  fondo_id text not null references fondos(id) on delete cascade,
  fecha_analisis date not null,
  subyacente text not null,
  tipo_opcion text not null check (tipo_opcion in ('Call','Put')),
  posicion text not null check (posicion in ('Comprada','Vendida')),
  strike numeric not null,
  vencimiento date not null,
  prima numeric not null,
  contratos numeric default 1,
  delta numeric,
  gamma numeric,
  theta numeric,
  vega numeric,
  rho numeric,
  iv numeric,
  volumen numeric,
  interes_abierto numeric,
  notas text,
  created_at timestamptz default now()
);

alter table analisis_opciones enable row level security;
create policy "usuarios logueados acceso total" on analisis_opciones for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
