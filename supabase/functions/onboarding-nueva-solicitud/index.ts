// Edge Function: onboarding-nueva-solicitud
//
// Punto de entrada para el proyecto de onboarding (app aparte, en Vercel). Recibe el payload
// del formulario, lo guarda como una solicitud "Pendiente" en onboarding_solicitudes, y
// devuelve un id. NO crea ningún cliente — eso lo hace un admin a mano desde el panel
// (Solicitudes → Aprobar), que recién ahí genera la persona, el cuotapartista y el número
// de cuenta. Este endpoint solo "deposita" la solicitud.
//
// ---------- AUTENTICACIÓN ----------
// No usa login de Supabase (quien llama es otra app, no una persona logueada acá) — usa una
// clave secreta compartida en el header Authorization: Bearer <ONBOARDING_API_KEY>.
// Por eso, al desplegar esta función, hay que DESTILDAR "Verify JWT with legacy secret" en
// Settings de la función (si no, Supabase rechaza el pedido antes de que este código corra,
// porque esa clave no es un JWT válido de Supabase).
//
// ---------- CÓMO DESPLEGAR ----------
// 1. Edge Functions → Deploy a new function → nombre: onboarding-nueva-solicitud → pegar
//    este archivo → Deploy.
// 2. En esa función → Settings → destildar "Verify JWT with legacy secret".
// 3. Edge Functions → Secrets → agregar ONBOARDING_API_KEY con una clave larga y random
//    (generála vos, ej. con `openssl rand -hex 32`). Esa misma clave va en el proyecto de
//    Vercel como variable de entorno, para mandarla en el header Authorization.
//
// ---------- CONTRATO ----------
// POST con header "Authorization: Bearer <ONBOARDING_API_KEY>" y este body (ver también
// apex_onboarding_integration_spec.md, sección 4 — los nombres de campo son los mismos):
// {
//   "fondoId": "apex",                    // opcional, default "apex"
//   "investorType": "individual" | "entity",
//   "usResident": boolean,
//   "identification": { "fullName", "entityName", "jurisdiction", "docType", "docNumber", "birthDate", "nationality" },
//   "contact": { "email", "phoneCountry", "phoneNumber" },
//   "address": { "street", "country", "state", "city", "zip" },
//   "profile": { "annualIncome", "netWorthTotal", "netWorthLiquid" },
//   "investment": { "amount" },
//   "agreement": { "signer", "signedAt" },
//   "docs": [ { "key", "method", "fileName"? "fileUrl"? } ]
// }
// Respuesta: { "solicitudId": "...", "status": "Pendiente" }
// (Nota: distinto del contrato original del spec, que esperaba subscriptionId/clientId —
// acá no se crea cliente todavía, por eso se devuelve solicitudId.)

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

Deno.serve(async (req) => {
  try {
    if (req.method !== 'POST') {
      return new Response(JSON.stringify({ error: 'Método no permitido' }), { status: 405, headers: { 'Content-Type': 'application/json' } });
    }

    const expectedKey = Deno.env.get('ONBOARDING_API_KEY');
    const authHeader = req.headers.get('Authorization') || '';
    const providedKey = authHeader.replace(/^Bearer\s+/i, '');
    if (!expectedKey || providedKey !== expectedKey) {
      return new Response(JSON.stringify({ error: 'No autorizado' }), { status: 401, headers: { 'Content-Type': 'application/json' } });
    }

    const body = await req.json();
    const fondoId = body.fondoId || 'apex';

    const investorType = body.investorType;
    const tipoPersona = investorType === 'entity' ? 'Jurídica' : 'Física';
    const ident = body.identification || {};
    const contact = body.contact || {};
    const address = body.address || {};

    const nombreRazonSocial = ident.entityName || ident.fullName;
    if (!nombreRazonSocial) {
      return new Response(JSON.stringify({ error: 'Falta identification.fullName o identification.entityName' }), { status: 400, headers: { 'Content-Type': 'application/json' } });
    }
    if (!contact.email) {
      return new Response(JSON.stringify({ error: 'Falta contact.email' }), { status: 400, headers: { 'Content-Type': 'application/json' } });
    }

    const documento = ident.docType && ident.docNumber ? `${ident.docType.toUpperCase()} ${ident.docNumber}` : (ident.docNumber || null);
    const telefono = contact.phoneCountry && contact.phoneNumber ? `${contact.phoneCountry} ${contact.phoneNumber}` : (contact.phoneNumber || null);
    const domicilio = [address.street, address.zip].filter(Boolean).join(', ') || null;

    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const sb = createClient(supabaseUrl, serviceKey);

    const { data, error } = await sb.from('onboarding_solicitudes').insert({
      fondo_id: fondoId,
      estado: 'Pendiente',
      nombre_razon_social: nombreRazonSocial,
      tipo_persona: tipoPersona,
      documento,
      email: contact.email,
      telefono,
      pais: address.country || null,
      provincia: address.state || null,
      localidad: address.city || null,
      domicilio,
      monto_solicitado: body.investment?.amount ?? null,
      datos: body,
    }).select('id').single();

    if (error) throw error;

    return new Response(JSON.stringify({ solicitudId: data.id, status: 'Pendiente' }), {
      status: 201,
      headers: { 'Content-Type': 'application/json' },
    });
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e) }), { status: 500, headers: { 'Content-Type': 'application/json' } });
  }
});
