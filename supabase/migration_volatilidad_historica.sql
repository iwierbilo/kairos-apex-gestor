-- Gestor de Opciones: volatilidad histórica (realizada) para comparar contra la IV cargada.
-- No borra nada existente.
alter table analisis_opciones add column if not exists volatilidad_historica numeric;
