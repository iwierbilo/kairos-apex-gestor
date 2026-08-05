// Edge Function: actualizar-valuacion-diaria
//
// Qué hace, en orden:
//   1. Junta los tickers de acciones con lotes abiertos (cantidad_restante > 0).
//   2. Pide la cotización actual de cada uno a Finnhub y actualiza posiciones_fondo.precio_actual
//      (las opciones NO se actualizan acá — Finnhub free no las cubre; usan el último precio cargado).
//   3. Recalcula patrimonio total (cartera a precio de mercado + liquidez) y cuotapartes en
//      circulación, y guarda (upsert) la fila del día en valuaciones_fondo.
//
// Es exactamente la misma lógica que los botones "Actualizar cotizaciones" + "Recalcular valor
// de cuotaparte" de index.html, para poder correrla sola todos los días vía un Cron Job.
//
// ---------- CÓMO DESPLEGAR (una sola vez) ----------
// 1. En el panel de Supabase → Edge Functions → "Deploy a new function".
// 2. Nombre: actualizar-valuacion-diaria. Pegá este archivo entero como el código. Deploy.
// 3. Edge Functions → actualizar-valuacion-diaria → Secrets → agregar:
//      FINNHUB_API_KEY = (la misma key que ya está en index.html)
//    (SUPABASE_URL y SUPABASE_SERVICE_ROLE_KEY ya están disponibles solos, Supabase los inyecta.)
// 4. Database → Cron Jobs → New cron job:
//      Type: Supabase Edge Function → elegí esta función
//      Schedule: por ejemplo "0 22 * * 1-5" (22:00 UTC, lunes a viernes — después del cierre
//      de Wall Street tanto en horario de verano como de invierno de EE.UU.)
//    Guardar. Listo — a partir de ahí corre sola todos los días de mercado.
//
// Podés probarla a mano antes de programarla: Edge Functions → actualizar-valuacion-diaria → "Invoke".

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const FONDO_ID = 'apex';

Deno.serve(async () => {
  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const finnhubKey = Deno.env.get('FINNHUB_API_KEY')!;
    const sb = createClient(supabaseUrl, serviceKey);

    // ---------- 1. Tickers de acciones con lotes abiertos ----------
    const { data: lotesAcciones, error: errLotes } = await sb
      .from('lotes_fondo')
      .select('ticker')
      .eq('fondo_id', FONDO_ID)
      .eq('tipo_activo', 'Acción')
      .gt('cantidad_restante', 0);
    if (errLotes) throw errLotes;
    const tickers = [...new Set((lotesAcciones ?? []).map((l: any) => l.ticker))];

    // ---------- 2. Cotización actual por ticker → posiciones_fondo ----------
    let actualizados = 0;
    for (const ticker of tickers) {
      try {
        const res = await fetch(
          `https://finnhub.io/api/v1/quote?symbol=${encodeURIComponent(ticker)}&token=${finnhubKey}`
        );
        const quote = await res.json();
        if (!quote || typeof quote.c !== 'number' || quote.c === 0) continue;

        const { data: existente } = await sb
          .from('posiciones_fondo')
          .select('id')
          .eq('fondo_id', FONDO_ID)
          .eq('tipo_activo', 'Acción')
          .eq('ticker', ticker)
          .maybeSingle();

        const ahora = new Date().toISOString();
        if (existente) {
          await sb.from('posiciones_fondo')
            .update({ precio_actual: quote.c, fecha_actualizacion: ahora })
            .eq('id', existente.id);
        } else {
          await sb.from('posiciones_fondo')
            .insert({ fondo_id: FONDO_ID, tipo_activo: 'Acción', ticker, precio_actual: quote.c, fecha_actualizacion: ahora });
        }
        actualizados++;
      } catch {
        // Un ticker que falla no debe frenar a los demás.
      }
    }

    // ---------- 3. Recalcular patrimonio total y valor de cuotaparte ----------
    const clave = (l: any) => `${l.ticker}|${l.tipo_opcion ?? ''}|${l.strike ?? ''}|${l.vencimiento ?? ''}`;

    const { data: lotesAbiertos } = await sb.from('lotes_fondo').select('*').eq('fondo_id', FONDO_ID).gt('cantidad_restante', 0);
    const { data: posiciones } = await sb.from('posiciones_fondo').select('*').eq('fondo_id', FONDO_ID);
    const { data: liquidez } = await sb.from('liquidez_fondo').select('saldo').eq('fondo_id', FONDO_ID).single();
    const { data: movimientos } = await sb.from('movimientos_cuotapartes').select('tipo,cantidad_cuotapartes').eq('fondo_id', FONDO_ID);

    const cantidadPorClave: Record<string, { cantidad: number; tipoActivo: string }> = {};
    for (const l of lotesAbiertos ?? []) {
      const k = clave(l);
      if (!cantidadPorClave[k]) cantidadPorClave[k] = { cantidad: 0, tipoActivo: l.tipo_activo };
      cantidadPorClave[k].cantidad += l.cantidad_restante;
    }

    let patrimonioCartera = 0;
    for (const k in cantidadPorClave) {
      const pos = (posiciones ?? []).find((p: any) => clave(p) === k);
      const precio = pos?.precio_actual ?? 0;
      const mult = cantidadPorClave[k].tipoActivo === 'Opción' ? 100 : 1;
      patrimonioCartera += cantidadPorClave[k].cantidad * precio * mult;
    }

    const patrimonioTotal = patrimonioCartera + (liquidez?.saldo ?? 0);
    const cuotapartesTotales = (movimientos ?? []).reduce(
      (s: number, m: any) => s + (m.tipo === 'Suscripción' ? m.cantidad_cuotapartes : -m.cantidad_cuotapartes),
      0
    );

    let valorCuotaparte: number | null = null;
    if (cuotapartesTotales > 0) {
      valorCuotaparte = patrimonioTotal / cuotapartesTotales;
      const hoy = new Date().toISOString().slice(0, 10);
      await sb.from('valuaciones_fondo').upsert(
        { fondo_id: FONDO_ID, fecha: hoy, patrimonio_total: patrimonioTotal, cuotapartes_totales: cuotapartesTotales, valor_cuotaparte: valorCuotaparte },
        { onConflict: 'fondo_id,fecha' }
      );
    }

    return new Response(
      JSON.stringify({ ok: true, tickers: tickers.length, cotizacionesActualizadas: actualizados, patrimonioTotal, valorCuotaparte }),
      { headers: { 'Content-Type': 'application/json' } }
    );
  } catch (e) {
    return new Response(JSON.stringify({ ok: false, error: String(e) }), {
      status: 500,
      headers: { 'Content-Type': 'application/json' },
    });
  }
});
