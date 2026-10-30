import { Fault, authenticate, origin, mode, readJSON, limitedBytes, UUID, isState, json, securityHeaders } from './security.mjs';
import { rateLimit, newAuthorization, claimAuthorization, assertPendingAuthorization, saveConnection, connection, listConnections } from './store.mjs';
import { acceptsBankName, banks, startAuthorization, exchange, demoConnection, accountData, revoke } from './provider.mjs';

function appRedirect(id, result) {
  // No bank code, state, token or session identifier enters the app URL.
  return new Response(null, { status: 303, headers: securityHeaders({
    Location: `mibombomoney-bank://callback?flow=${encodeURIComponent(id)}&result=${result}`
  }) });
}
function assertDate(value) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value ?? '') || !Number.isFinite(Date.parse(value))
      || new Date(value).toISOString().slice(0, 10) !== value) throw new Fault(400, 'invalid_date_range');
}
function projectConnection(c) {
  return { id: c.id, bank: c.bank, validUntil: c.validUntil, testScenario: c.testScenario,
    accounts: c.accounts.map(a => ({ id: a.id, name: a.name, currency: a.currency, lastFour: a.lastFour,
      ownershipKey: a.ownershipKey, testRole: a.testRole })) };
}
function personalInformation(path) {
  const privacy = path === '/privacy';
  const title = privacy ? 'Privacidad de Mi Bombo Money Personal' : 'Uso de Mi Bombo Money Personal';
  const body = privacy
    ? `<p>Aplicación privada para que su propietario consulte sus propias cuentas y organice sus finanzas.</p>
      <h2>Datos y servicios</h2><p>El banco y Enable Banking gestionan la autorización. El servidor de Cloudflare recibe identificadores de cuentas, saldos y movimientos. La app guarda la contabilidad en el dispositivo y la sincroniza con la cuenta personal de Supabase.</p>
      <p>Las contraseñas bancarias y los códigos de autorización se introducen en el flujo del banco, nunca en un formulario de esta app. Las claves del proveedor y las sesiones bancarias permanecen en el servidor; las sesiones se cifran y se vinculan al propietario.</p>
      <h2>Acceso y conservación</h2><p>El acceso bancario del servidor se limita a una identidad de Supabase configurada por el propietario. Solo se consultan datos; el servidor no tiene funciones para iniciar pagos.</p>
      <p>Desconectar un banco revoca su sesión disponible en el servidor. Los movimientos ya incorporados permanecen en la contabilidad. La eliminación contable utiliza marcas de borrado en la nube y no equivale a una eliminación física inmediata de copias o registros. El propietario administra también los datos y copias en su proyecto Supabase.</p>
      <h2>Contacto</h2><p>El contacto del propietario para cuestiones de protección de datos figura en el registro de esta aplicación en Enable Banking. Este prototipo no ofrece registro público a terceros.</p>`
    : `<p>Prototipo privado de uso personal. Su finalidad es consultar las cuentas propias que el propietario autorice y organizar saldos, movimientos, categorías, reservas y presupuestos.</p>
      <h2>Conexión bancaria</h2><p>El acceso requiere una aplicación de Enable Banking de producción restringida a cuentas propias y una autorización vigente del banco. La app utiliza únicamente información de cuentas: no permite ordenar pagos ni transferencias bancarias.</p>
      <h2>Comprobación de los datos</h2><p>La disponibilidad, el historial y los campos recibidos dependen del banco. La primera importación requiere revisión; las posibles coincidencias con movimientos existentes se resuelven antes de incorporarlas. La conexión de una cuenta de efectivo no incluye una cartera de valores.</p>
      <h2>Control del propietario</h2><p>El propietario puede desconectar el banco desde la app y gestionar su consentimiento con el banco o el proveedor. Desconectar no borra los movimientos ya guardados. El prototipo no ofrece acceso comercial ni conexión de cuentas de otras personas.</p>`;
  return new Response(`<!doctype html><html lang="es"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${title}</title><main><h1>${title}</h1>${body}<p>Versión informativa: 30 de octubre de 2026.</p></main></html>`,
    { headers: securityHeaders({ 'Content-Type': 'text/html; charset=utf-8' }) });
}
async function callback(request, url, env) {
  await rateLimit(env, 'callbacks', 20);
  if (url.searchParams.getAll('state').length !== 1 || url.searchParams.getAll('code').length > 1
      || url.searchParams.getAll('error').length > 1) throw new Fault(400, 'invalid_authorization');
  const pending = await claimAuthorization(url.searchParams.get('state'), env);
  if (mode(env) === 'production' && pending.owner !== env.SUPABASE_OWNER_ID) throw new Fault(403, 'owner_required');
  if (url.searchParams.has('error')) return appRedirect(pending.id, 'cancelled');
  const code = url.searchParams.get('code');
  if (typeof code !== 'string' || code.length < 1 || code.length > 4096) return appRedirect(pending.id, 'failed');
  try {
    const value = await exchange(code, pending.bank, env);
    try { await saveConnection(pending.id, value, env); }
    catch (error) { await revoke(value, env); throw error; }
    return appRedirect(pending.id, 'ok');
  } catch { return appRedirect(pending.id, 'failed'); }
}
async function demoConsent(request, url, env) {
  if (mode(env) !== 'demo') throw new Fault(404, 'not_found');
  if (request.method === 'GET' && url.pathname === '/demo/consent') {
    const state = url.searchParams.get('state');
    if (!isState(state) || url.searchParams.getAll('state').length !== 1) throw new Fault(400, 'invalid_authorization');
    await assertPendingAuthorization(state, env);
    return new Response(`<!doctype html><html lang="es"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
      <title>Prueba de conexión</title><h1>Solo datos ficticios</h1>
      <p>Esta demostración no accede a ningún banco. No introduzcas claves bancarias.</p>
      <form method="post" action="/demo/complete"><input type="hidden" name="state" value="${state}">
      <button name="decision" value="allow">Conectar cuenta ficticia</button>
      <button name="decision" value="deny">Cancelar</button></form></html>`,
    // A no-referrer page makes browser form POSTs send Origin: null. Preserve
    // only the HTTPS origin so the strict check below works without leaking state.
    { headers: securityHeaders({ 'Content-Type': 'text/html; charset=utf-8', 'Referrer-Policy': 'strict-origin' }) });
  }
  if (request.method !== 'POST' || url.pathname !== '/demo/complete') throw new Fault(404, 'not_found');
  if (request.headers.get('origin') !== origin(env)
      || (request.headers.get('content-type') ?? '').split(';')[0] !== 'application/x-www-form-urlencoded') throw new Fault(403, 'forbidden');
  await rateLimit(env, 'callbacks', 20);
  const body = new URLSearchParams(new TextDecoder().decode(await limitedBytes(request, 2048)));
  if (body.getAll('state').length !== 1 || body.getAll('decision').length !== 1
      || !['allow', 'deny'].includes(body.get('decision'))) throw new Fault(400, 'invalid_request');
  const pending = await claimAuthorization(body.get('state'), env);
  if (body.get('decision') === 'deny') return appRedirect(pending.id, 'cancelled');
  await saveConnection(pending.id, demoConnection(pending.bank), env);
  return appRedirect(pending.id, 'ok');
}
export async function handle(request, env) {
  const url = new URL(request.url);
  if (url.origin !== origin(env) || url.hash || url.username || url.password) throw new Fault(400, 'invalid_host');
  // Public factual pages remain available during setup. Every banking API still fails closed.
  if (env.PROVIDER_MODE === 'production' && request.method === 'GET' && ['/privacy', '/terms'].includes(url.pathname)) return personalInformation(url.pathname);
  mode(env);
  if (url.pathname === '/health' && request.method === 'GET') return json({ status: 'ok' });
  if (url.pathname.startsWith('/demo/')) {
    try { return await demoConsent(request, url, env); }
    catch (error) {
      if (!(error instanceof Fault) || error.code !== 'invalid_authorization') throw error;
      return new Response(`<!doctype html><html lang="es"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Vuelve a iniciar la conexión</title><h1>Vuelve a iniciar la conexión</h1>
        <p>Esta autorización ha caducado, ya se ha utilizado o no es válida.</p>
        <p>Cierra esta ventana con Cancelar o el botón de cierre. Después, vuelve a elegir el banco en la app para abrir una autorización nueva.</p>
        <p>No recargues ni vuelvas atrás en este formulario. No se han modificado tus datos financieros.</p></html>`,
      { status: 400, headers: securityHeaders({ 'Content-Type': 'text/html; charset=utf-8' }) });
    }
  }
  if (url.pathname === '/v1/callback' && request.method === 'GET' && mode(env) !== 'demo') return callback(request, url, env);
  // A native client does not need browser CORS. Even a correct token is refused in a browser-origin request.
  if (request.headers.has('origin')) throw new Fault(403, 'forbidden');
  await authenticate(request, env);
  await rateLimit(env, 'owner');
  if (request.method === 'GET' && url.pathname === '/v1/status') return json({ mode: mode(env),
    liveBankingEnabled: mode(env) === 'production', accountingImportEnabled: mode(env) === 'production' });
  if (request.method === 'GET' && url.pathname === '/v1/banks') return json({ banks: await banks(env) });
  if (request.method === 'POST' && url.pathname === '/v1/authorizations') {
    await rateLimit(env, 'authorizations', 5);
    const { bank } = await readJSON(request, ['bank']);
    if (!acceptsBankName(bank, env)) throw new Fault(400, 'unsupported_bank');
    if ((await listConnections(env)).length >= 6) throw new Fault(409, 'connection_limit');
    const pending = await newAuthorization(bank, env);
    try { return json({ id: pending.id, authorizationURL: await startAuthorization(bank, pending.state, env) }, 201); }
    catch (error) { await env.DB.prepare('DELETE FROM auth_requests WHERE id=?').bind(pending.id).run(); throw error; }
  }
  if (request.method === 'GET' && url.pathname === '/v1/connections') return json({ connections: (await listConnections(env)).map(projectConnection) });
  const match = /^\/v1\/connections\/([a-f0-9-]+)(?:\/accounts\/([a-zA-Z0-9_-]+))?$/.exec(url.pathname);
  if (match && UUID.test(match[1])) {
    const conn = await connection(match[1], env);
    if (!match[2] && request.method === 'DELETE') {
      const targets = mode(env) === 'production' ? (await listConnections(env, true)).filter(c => c.bank === conn.bank) : [conn];
      for (const target of targets) {
        await revoke(target, env);
        await env.DB.prepare('DELETE FROM connections WHERE id=?').bind(target.id).run();
      }
      return new Response(null, { status: 204, headers: securityHeaders() });
    }
    if (match[2] && request.method === 'GET') {
      const account = conn.accounts.find(a => a.id === match[2]);
      if (!account) throw new Fault(404, 'account_not_found');
      const from = url.searchParams.get('from'); const to = url.searchParams.get('to');
      assertDate(from); assertDate(to);
      if (from > to || to > new Date().toISOString().slice(0, 10) || Date.parse(to) - Date.parse(from) > 90 * 86400_000) throw new Fault(400, 'invalid_date_range');
      const next = url.searchParams.get('continuation');
      if (next && next.length > 1024) throw new Fault(400, 'invalid_request');
      return json(await accountData(conn, account, from, to, next, env));
    }
  }
  // No proxy endpoint, arbitrary provider URL, payment or transaction-write routes exist.
  throw new Fault(404, 'not_found');
}
export default {
  async fetch(request, env) {
    try { return await handle(request, env); }
    catch (error) {
      // Deliberately never log requests, provider bodies, URLs, tokens or exceptions.
      return json({ error: error instanceof Fault ? error.code : 'service_unavailable' }, error instanceof Fault ? error.status : 503);
    }
  }
};
