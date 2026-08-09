-- Comisión de suscripción: se descuenta del monto antes de convertirlo en cuotapartes.
-- El capital invertido (monto) sigue siendo siempre el bruto — eso no cambia y sigue siendo
-- lo que se usa para calcular el rendimiento. Lo que cambia es que cantidad_cuotapartes ahora
-- se calcula sobre (monto - comisión), no sobre el monto completo.
--
-- La comisión es ingreso de Kairos, no se invierte: la liquidez del fondo sube solo por el
-- monto neto en las suscripciones nuevas (ver guardarMovimiento en index.html).
--
-- Filas viejas quedan con comision_pct=0 y comision_monto=0 (no se les recalcula nada).

alter table movimientos_cuotapartes add column if not exists comision_pct numeric default 0;
alter table movimientos_cuotapartes add column if not exists comision_monto numeric default 0;

update movimientos_cuotapartes set comision_pct = 0 where comision_pct is null;
update movimientos_cuotapartes set comision_monto = 0 where comision_monto is null;
