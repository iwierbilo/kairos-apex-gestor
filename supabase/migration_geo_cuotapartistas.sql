-- Cuotapartistas: separar la localización en Provincia/Estado y Localidad
-- (antes solo existía "país" + "domicilio" en texto libre).
-- No borra nada existente; domicilio sigue siendo la calle/altura/depto.

alter table cuotapartistas add column if not exists provincia text;
alter table cuotapartistas add column if not exists localidad text;
