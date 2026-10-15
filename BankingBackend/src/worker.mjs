import { Fault, authenticate, origin, mode, readJSON, limitedBytes, UUID, isState, json, securityHeaders } from './security.mjs';
import { rateLimit, newAuthorization, claimAuthorization, saveConnection, connection, listConnections } from './store.mjs';
import { demoBanks, banks, startAuthorization, exchange, demoConnection, accountData, revoke } from './provider.mjs';

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
  return { id: c.id, bank: c.bank, validUntil: c.validUntil,
    accounts: c.accounts.map(a => ({ id: a.id, name: a.name, currency: a.currency, lastFour: a.lastFour })) };
}
async function callback(request, url, env) {
  await rateLimit(env, 'callbacks', 20);
  if (url.searchParams.getAll('state').length !== 1 || url.searchParams.getAll('code').length > 1
      || url.searchParams.getAll('error').length > 1) throw new Fault(400, 'invalid_authorization');
  const pending = await claimAuthorization(url.searchParams.get('state'), env);
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
    return new Response(`<!doctype html><html lang="es"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
      <title>Prueba de conexión</title><h1>Solo datos ficticios</h1>
      <p>Esta demostración no accede a ningún banco. No introduzcas claves bancarias.</p>
      <form method="post" action="/demo/complete"><input type="hidden" name="state" value="${state}">
      <button name="decision" value="allow">Conectar cuenta ficticia</button>
      <button name="decision" value="deny">Cancelar</button></form></html>`,
    { headers: securityHeaders({ 'Content-Type': 'text/html; charset=utf-8' }) });
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
  mode(env);
  if (url.origin !== origin(env) || url.hash || url.username || url.password) throw new Fault(400, 'invalid_host');
  if (url.pathname === '/health' && request.method === 'GET') return json({ status: 'ok' });
  if (url.pathname.startsWith('/demo/')) return demoConsent(request, url, env);
  if (url.pathname === '/v1/callback' && request.method === 'GET' && mode(env) === 'sandbox') return callback(request, url, env);
  // A native client does not need browser CORS. Even a correct token is refused in a browser-origin request.
  if (request.headers.has('origin')) throw new Fault(403, 'forbidden');
  await authenticate(request, env);
  await rateLimit(env, 'owner');
  if (request.method === 'GET' && url.pathname === '/v1/status') return json({ mode: mode(env), liveBankingEnabled: false, accountingImportEnabled: false });
  if (request.method === 'GET' && url.pathname === '/v1/banks') return json({ banks: await banks(env) });
  if (request.method === 'POST' && url.pathname === '/v1/authorizations') {
    await rateLimit(env, 'authorizations', 5);
    const { bank } = await readJSON(request, ['bank']);
    if (!demoBanks().some(b => b.name === bank)) throw new Fault(400, 'unsupported_bank');
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
      await revoke(conn, env);
      await env.DB.prepare('DELETE FROM connections WHERE id=?').bind(conn.id).run();
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
