-- Valuación diaria automática: evita duplicar la valuación de un mismo día
-- (hasta ahora "Recalcular valor de cuotaparte" hacía un INSERT simple; si se
-- corre más de una vez el mismo día —a mano o por el cron diario— quedaban
-- varias filas para la misma fecha).

-- Por si ya hay más de una fila para el mismo fondo+fecha, nos quedamos con la más nueva.
delete from valuaciones_fondo a using valuaciones_fondo b
  where a.fondo_id = b.fondo_id and a.fecha = b.fecha and a.created_at < b.created_at;

alter table valuaciones_fondo add constraint valuaciones_fondo_fondo_fecha_key unique (fondo_id, fecha);
