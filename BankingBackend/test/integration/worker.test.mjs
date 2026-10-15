import { beforeEach, afterEach, test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createHash, randomBytes, generateKeyPairSync } from 'node:crypto';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';
import { fileURLToPath } from 'node:url';

let mf, db, token;
const host = 'https://bank-test.personal.workers.dev';
async function boot(overrides = {}, outboundService) {
  token = randomBytes(32).toString('hex');
  mf = new Miniflare(convertV4MiniflareOptions({
    sendMetrics: false,
    modules: ['worker', 'security', 'store', 'provider'].map(name => ({ type: 'ESModule',
      path: fileURLToPath(new URL(`../../src/${name}.mjs`, import.meta.url)) })),
    compatibilityDate: '2026-10-12', compatibilityFlags: ['nodejs_compat'],
    d1Databases: ['DB'],
    bindings: { PROVIDER_MODE: 'demo', PUBLIC_ORIGIN: host,
      ACCESS_TOKEN_SHA256: createHash('sha256').update(token).digest('hex'), DATA_ENCRYPTION_KEY: randomBytes(32).toString('base64'), ...overrides },
    outboundService: outboundService ?? (() => { throw new Error('A demonstration must never contact any bank or provider'); })
  }));
  db = await mf.getD1Database('DB');
  const sql = await readFile(new URL('../../migrations/0001_connections.sql', import.meta.url), 'utf8');
  await db.exec(sql.replace(/^--.*$/gm, '').replaceAll('\n', ' '));
}
beforeEach(() => boot());
afterEach(async () => { await mf?.dispose(); });
const call = (path, options = {}) => mf.dispatchFetch(`${host}${path}`, {
  ...options, headers: { Authorization: `Bearer ${token}`, ...options.headers }
});
async function start(bank = 'BBVA') {
  const response = await call('/v1/authorizations', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ bank }) });
  assert.equal(response.status, 201, await response.clone().text());
  return response.json();
}
async function complete(flow, decision = 'allow') {
  const state = new URL(flow.authorizationURL).searchParams.get('state');
  return mf.dispatchFetch(`${host}/demo/complete`, { method: 'POST', redirect: 'manual',
    headers: { Origin: host, 'Content-Type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams({ state, decision }) });
}

test('native API requires bearer credentials and rejects browser origins, arbitrary hosts, CORS and payment endpoints', async () => {
  assert.equal((await mf.dispatchFetch(`${host}/v1/connections`)).status, 401);
  assert.equal((await call('/v1/connections', { headers: { Origin: 'https://evil.test' } })).status, 403);
  assert.equal((await mf.dispatchFetch('https://evil.test/v1/connections', { headers: { Authorization: `Bearer ${token}` } })).status, 400);
  const response = await call('/v1/status');
  assert.equal(response.headers.get('Access-Control-Allow-Origin'), null);
  assert.match(response.headers.get('Cache-Control'), /no-store/);
  assert.match(response.headers.get('Content-Security-Policy'), /frame-ancestors 'none'/);
  assert.deepEqual(await response.json(), { mode: 'demo', liveBankingEnabled: false, accountingImportEnabled: false });
  assert.equal((await call('/v1/payments', { method: 'POST' })).status, 404);
});

test('end-to-end consent, encrypted persistence, read-only preview and revocation run in workerd with real D1', async () => {
  const flow = await start();
  const state = new URL(flow.authorizationURL).searchParams.get('state');
  const authRow = await db.prepare('SELECT * FROM auth_requests').first();
  assert.ok(!JSON.stringify(authRow).includes(state));
  assert.ok(!JSON.stringify(authRow).includes('BBVA'));
  const response = await complete(flow);
  assert.equal(response.status, 303);
  const redirect = new URL(response.headers.get('Location'));
  assert.equal(redirect.protocol, 'mibombomoney-bank:');
  assert.equal(redirect.searchParams.get('flow'), flow.id);
  assert.equal(redirect.searchParams.get('result'), 'ok');
  assert.deepEqual([...redirect.searchParams.keys()].sort(), ['flow', 'result']);
  const row = await db.prepare('SELECT * FROM connections').first();
  assert.ok(!JSON.stringify(row).includes('fictitious-session'));
  const { connections } = await (await call('/v1/connections')).json();
  assert.equal(connections.length, 1);
  assert.ok(!JSON.stringify(connections).includes('sessionID'));
  const c = connections[0]; const a = c.accounts[0];
  const to = new Date().toISOString().slice(0, 10);
  const from = new Date(Date.now() - 86400_000).toISOString().slice(0, 10);
  const preview = await call(`/v1/connections/${c.id}/accounts/${a.id}?from=${from}&to=${to}`);
  assert.equal(preview.status, 200);
  const data = await preview.json();
  assert.equal(data.transactions.length, 2);
  assert.equal(data.transactions.reduce((sum, t) => sum + t.signedAmountMinor, 0), data.balances[0].amountMinor);
  const columns = (await db.prepare('SELECT name FROM sqlite_master WHERE type=\'table\'').all()).results.map(r => r.name);
  assert.ok(!columns.includes('transactions'));
  assert.equal((await call(`/v1/connections/${c.id}`, { method: 'DELETE' })).status, 204);
  assert.equal((await call(`/v1/connections/${c.id}/accounts/${a.id}?from=${from}&to=${to}`)).status, 404);
  assert.equal((await db.prepare('SELECT COUNT(*) AS n FROM connections').first()).n, 0);
});

test('replayed and concurrent callbacks can only create one connection', async () => {
  const flow = await start('Bankinter');
  const results = await Promise.all([complete(flow), complete(flow)]);
  assert.deepEqual(results.map(r => r.status).sort(), [303, 400]);
  assert.equal((await db.prepare('SELECT COUNT(*) AS n FROM connections').first()).n, 1);
});

test('expired, denied, missing and foreign-origin consents cannot create sessions', async () => {
  const flow = await start();
  await db.prepare('UPDATE auth_requests SET expires_at=0').run();
  assert.equal((await complete(flow)).status, 400);
  const denied = await start();
  const result = await complete(denied, 'deny');
  assert.match(result.headers.get('Location'), /result=cancelled/);
  const state = new URL(denied.authorizationURL).searchParams.get('state');
  assert.equal((await mf.dispatchFetch(`${host}/demo/complete`, { method: 'POST',
    headers: { Origin: 'https://evil.test', 'Content-Type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams({ state, decision: 'allow' }) })).status, 403);
  assert.equal((await db.prepare('SELECT COUNT(*) AS n FROM connections').first()).n, 0);
});

test('unsupported banks, open redirects and excessive authorization starts are refused', async () => {
  for (const body of [{ bank: 'Unknown' }, { bank: 'BBVA', redirect: 'https://evil.test' }]) {
    assert.equal((await call('/v1/authorizations', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) })).status, 400);
  }
  await start(); await start(); await start();
  const response = await call('/v1/authorizations', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ bank: 'BBVA' }) });
  assert.equal(response.status, 429);
});

test('account ownership is checked and invalid date ranges or data writes are rejected', async () => {
  const flow = await start(); await complete(flow);
  const to = new Date().toISOString().slice(0, 10);
  assert.equal((await call(`/v1/connections/${flow.id}/accounts/other?from=${to}&to=${to}`)).status, 404);
  assert.equal((await call(`/v1/connections/${flow.id}/accounts/demo-cash?from=2026-02-30&to=${to}`)).status, 400);
  assert.equal((await call(`/v1/connections/${flow.id}/accounts/demo-cash`, { method: 'POST' })).status, 404);
});

async function sandboxFixture(environment = 'SANDBOX', options = {}) {
  await mf.dispose();
  const appID = crypto.randomUUID(); const accountID = crypto.randomUUID(); const sessionID = crypto.randomUUID();
  const { privateKey } = generateKeyPairSync('rsa', { modulusLength: 4096 });
  const calls = [];
  await boot({ PROVIDER_MODE: 'sandbox', ENABLE_APP_ID: appID,
    ENABLE_PRIVATE_KEY: privateKey.export({ format: 'pem', type: 'pkcs8' }) }, async request => {
    const url = new URL(request.url); calls.push(`${request.method} ${url.pathname}`);
    assert.equal(url.origin, 'https://api.enablebanking.com');
    assert.match(request.headers.get('Authorization'), /^Bearer [^.]+\.[^.]+\.[^.]+$/);
    if (url.pathname === '/application') {
      if (options.redirectApplication) return new Response(null, { status: 302, headers: { Location: 'https://evil.test/collect' } });
      return Response.json({ environment, kid: appID, active: true, services: ['AIS'], redirect_urls: [`${host}/v1/callback`] });
    }
    if (url.pathname === '/aspsps') return Response.json({ aspsps: [{ name: 'BBVA', country: 'ES', psu_types: ['personal'], maximum_consent_validity: 86400, beta: false }] });
    if (url.pathname === '/auth') {
      const body = await request.json();
      assert.equal(body.redirect_url, `${host}/v1/callback`);
      assert.equal(body.psu_type, 'personal');
      return Response.json({ url: `https://auth.enablebanking.com/authorize?state=${body.state}` });
    }
    if (url.pathname === '/sessions') {
      assert.deepEqual(await request.json(), { code: 'fictitious-code' });
      return Response.json({ session_id: sessionID, aspsp: { name: 'BBVA', country: 'ES' }, psu_type: 'personal', access: { valid_until: new Date(Date.now() + 86400_000).toISOString() },
        accounts: [{ uid: accountID, name: 'Sandbox account', currency: 'EUR', account_id: { iban: 'FICTITIOUS-IBAN-1234' } }] });
    }
    if (url.pathname.endsWith('/balances')) return Response.json({ balances: [{ balance_amount: { amount: '10.00', currency: 'EUR' }, balance_type: 'CLBD' }] });
    if (url.pathname.endsWith('/transactions')) return Response.json({ transactions: [{ status: 'BOOK', entry_reference: 'fixture-reference',
      transaction_amount: { amount: '10.00', currency: 'EUR' }, credit_debit_indicator: 'DBIT',
      booking_date: new Date().toISOString().slice(0, 10), remittance_information: ['Fictitious purchase'] }],
      continuation_key: url.searchParams.has('continuation_key') ? null : 'next-page' });
    if (url.pathname === `/sessions/${sessionID}` && request.method === 'DELETE') return new Response(null, { status: options.revokeStatus ?? 204 });
    throw new Error('Unexpected provider endpoint');
  });
  return { calls, sessionID, accountID };
}

test('sandbox uses signed provider requests, single-use code exchange, sanitized output and bounded pagination', async () => {
  const fixture = await sandboxFixture();
  const flow = await start();
  const state = new URL(flow.authorizationURL).searchParams.get('state');
  const result = await mf.dispatchFetch(`${host}/v1/callback?state=${state}&code=fictitious-code`, { redirect: 'manual' });
  assert.equal(result.status, 303);
  assert.match(result.headers.get('Location'), /result=ok/);
  assert.equal((await mf.dispatchFetch(`${host}/v1/callback?state=${state}&code=fictitious-code`)).status, 400);
  const response = await (await call('/v1/connections')).json();
  const encoded = JSON.stringify(response);
  assert.ok(!encoded.includes(fixture.accountID) && !encoded.includes(fixture.sessionID) && !encoded.includes('FICTITIOUS-IBAN'));
  const connection = response.connections[0];
  const today = new Date().toISOString().slice(0, 10);
  const path = `/v1/connections/${connection.id}/accounts/${connection.accounts[0].id}?from=${today}&to=${today}`;
  const first = await (await call(path)).json();
  assert.equal(first.transactions[0].signedAmountMinor, -1000);
  assert.equal(first.continuation, 'next-page');
  const second = await (await call(`${path}&continuation=next-page`)).json();
  assert.equal(second.continuation, null);
  assert.equal((await call(`/v1/connections/${connection.id}`, { method: 'DELETE' })).status, 204);
  assert.equal(fixture.calls.filter(x => x === 'POST /sessions').length, 1);
});

test('production credentials cannot accidentally enable real banking in the sandbox worker', async () => {
  const fixture = await sandboxFixture('PRODUCTION');
  const response = await call('/v1/authorizations', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ bank: 'BBVA' }) });
  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), { error: 'sandbox_configuration_required' });
  assert.deepEqual(fixture.calls, ['GET /application']);
  assert.equal((await db.prepare('SELECT COUNT(*) AS n FROM auth_requests').first()).n, 0);
});

test('provider redirects are rejected without forwarding the signed credential to another origin', async () => {
  const fixture = await sandboxFixture('SANDBOX', { redirectApplication: true });
  const response = await call('/v1/banks');
  assert.equal(response.status, 502);
  assert.deepEqual(fixture.calls, ['GET /application']);
});

test('a failed revocation retains the encrypted reference so the user can retry', async () => {
  await sandboxFixture('SANDBOX', { revokeStatus: 500 });
  const flow = await start();
  const state = new URL(flow.authorizationURL).searchParams.get('state');
  await mf.dispatchFetch(`${host}/v1/callback?state=${state}&code=fictitious-code`, { redirect: 'manual' });
  assert.equal((await call(`/v1/connections/${flow.id}`, { method: 'DELETE' })).status, 502);
  assert.equal((await db.prepare('SELECT COUNT(*) AS n FROM connections').first()).n, 1);
});
