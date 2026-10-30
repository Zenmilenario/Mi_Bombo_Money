import { beforeEach, afterEach, test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createHash, randomBytes, generateKeyPairSync } from 'node:crypto';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';
import { fileURLToPath } from 'node:url';
import { generateScenario } from '../../tools/generate-sandbox-scenario.mjs';

let mf, db, token;
const host = 'https://bank-test.personal.workers.dev';
async function boot(overrides = {}, outboundService) {
  token = randomBytes(32).toString('hex');
  mf = new Miniflare(convertV4MiniflareOptions({
    sendMetrics: false,
    modules: ['worker', 'security', 'store', 'provider', 'sandbox-scenario'].map(name => ({ type: 'ESModule',
      path: fileURLToPath(new URL(`../../src/${name}.mjs`, import.meta.url)) })),
    compatibilityDate: '2026-10-12', compatibilityFlags: ['nodejs_compat'],
    d1Databases: ['DB'],
    bindings: { PROVIDER_MODE: 'demo', PUBLIC_ORIGIN: host,
      ACCESS_TOKEN_SHA256: createHash('sha256').update(token).digest('hex'), DATA_ENCRYPTION_KEY: randomBytes(32).toString('base64'), ...overrides },
    outboundService: outboundService ?? (() => { throw new Error('A demonstration must never contact any bank or provider'); })
  }));
  db = await mf.getD1Database('DB');
  for (const name of ['0001_connections.sql', '0002_production.sql']) {
    const sql = await readFile(new URL(`../../migrations/${name}`, import.meta.url), 'utf8');
    await db.exec(sql.replace(/^--.*$/gm, '').replaceAll('\n', ' '));
  }
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

test('personal information pages work during setup while every real banking endpoint remains locked', async () => {
  await mf.dispose(); await boot({ PROVIDER_MODE: 'production' });
  for (const path of ['/privacy', '/terms']) {
    const response = await mf.dispatchFetch(`${host}${path}`);
    assert.equal(response.status, 200);
    assert.match(response.headers.get('Content-Type'), /text\/html/);
    assert.match(await response.text(), /Mi Bombo Money Personal/);
  }
  const response = await call('/v1/connections');
  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), { error: 'live_banking_disabled' });
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

test('consent page preserves the browser POST origin without exposing the authorization URL as referrer', async () => {
  const flow = await start();
  const response = await mf.dispatchFetch(flow.authorizationURL);
  assert.equal(response.status, 200);
  // no-referrer turns Origin into "null" on a browser form POST (Fetch standard).
  // strict-origin preserves the HTTPS origin, but omits path/query (including state).
  assert.equal(response.headers.get('Referrer-Policy'), 'strict-origin');
  assert.match(response.headers.get('Content-Security-Policy'), /form-action 'self'/);
  assert.match(response.headers.get('Cache-Control'), /no-store/);
  const html = await response.text();
  assert.match(html, /<form method="post" action="\/demo\/complete">/);
  const state = /name="state" value="([A-Za-z0-9_-]{43})"/.exec(html)?.[1];
  assert.equal(state, new URL(flow.authorizationURL).searchParams.get('state'));
  const result = await mf.dispatchFetch(`${host}/demo/complete`, {
    method: 'POST', redirect: 'manual',
    headers: { Origin: new URL(flow.authorizationURL).origin, 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ state, decision: 'allow' })
  });
  assert.equal(result.status, 303);
  assert.match(result.headers.get('Location'), /result=ok/);
  assert.equal(result.headers.get('Referrer-Policy'), 'no-referrer');
  assert.equal((await call('/v1/status')).headers.get('Referrer-Policy'), 'no-referrer');
});

test('consent rejects missing, null and foreign origins without consuming the valid single-use authorization', async () => {
  const flow = await start();
  const state = new URL(flow.authorizationURL).searchParams.get('state');
  for (const origin of [undefined, 'null', 'https://evil.test', `${host}.evil.test`, 'http://bank-test.personal.workers.dev']) {
    const headers = { 'Content-Type': 'application/x-www-form-urlencoded' };
    if (origin !== undefined) headers.Origin = origin;
    const response = await mf.dispatchFetch(`${host}/demo/complete`, {
      method: 'POST', headers, body: new URLSearchParams({ state, decision: 'allow' })
    });
    assert.equal(response.status, 403);
    assert.deepEqual(await response.json(), { error: 'forbidden' });
  }
  assert.equal((await db.prepare('SELECT COUNT(*) AS n FROM connections').first()).n, 0);
  assert.equal((await complete(flow)).status, 303);
  assert.equal((await complete(flow)).status, 400);
  assert.equal((await db.prepare('SELECT COUNT(*) AS n FROM connections').first()).n, 1);
});

test('replayed and concurrent callbacks can only create one connection', async () => {
  const flow = await start('Bankinter');
  const results = await Promise.all([complete(flow), complete(flow)]);
  assert.deepEqual(results.map(r => r.status).sort(), [303, 400]);
  assert.equal((await db.prepare('SELECT COUNT(*) AS n FROM connections').first()).n, 1);
});

test('consent page refuses unknown, expired or used authorizations and explains how to restart', async () => {
  async function expectRestart(response) {
    assert.equal(response.status, 400);
    assert.match(response.headers.get('Content-Type'), /^text\/html/);
    const html = await response.text();
    assert.match(html, /Vuelve a iniciar la conexión/);
    assert.match(html, /vuelve a elegir el banco en la app/);
    assert.ok(!html.includes('invalid_authorization'));
  }
  await expectRestart(await mf.dispatchFetch(`${host}/demo/consent?state=${'A'.repeat(43)}`));
  const expired = await start();
  await db.prepare('UPDATE auth_requests SET expires_at=0').run();
  await expectRestart(await mf.dispatchFetch(expired.authorizationURL));
  await expectRestart(await complete(expired));
  const fresh = await start();
  // Viewing or reloading a valid form must not consume the one-use authorization.
  assert.equal((await mf.dispatchFetch(fresh.authorizationURL)).status, 200);
  assert.equal((await mf.dispatchFetch(fresh.authorizationURL)).status, 200);
  assert.equal((await complete(fresh)).status, 303);
  await expectRestart(await mf.dispatchFetch(fresh.authorizationURL));
  await expectRestart(await complete(fresh));
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
  const owner = crypto.randomUUID();
  const production = options.production === true;
  await boot({ PROVIDER_MODE: production ? 'production' : 'sandbox', ENABLE_APP_ID: appID,
    ...(production ? { BANKING_AUTH: 'supabase-owner', SUPABASE_URL: 'https://coeicjffmpclqowsqeys.supabase.co',
      SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_fixture', SUPABASE_OWNER_ID: owner,
      ACCOUNT_IDENTITY_KEY: randomBytes(32).toString('base64') } : {}),
    ENABLE_PRIVATE_KEY: privateKey.export({ format: 'pem', type: 'pkcs8' }) }, async request => {
    const url = new URL(request.url); calls.push(`${request.method} ${url.pathname}`);
    if (url.origin === 'https://coeicjffmpclqowsqeys.supabase.co') {
      assert.equal(url.pathname, '/auth/v1/user');
      assert.equal(request.headers.get('apikey'), 'sb_publishable_fixture');
      return Response.json({ id: request.headers.get('Authorization') === 'Bearer fixture.payload.signature' ? owner : crypto.randomUUID() });
    }
    assert.equal(url.origin, 'https://api.enablebanking.com');
    assert.notEqual(request.headers.get('Authorization'), 'Bearer fixture.payload.signature');
    assert.match(request.headers.get('Authorization'), /^Bearer [^.]+\.[^.]+\.[^.]+$/);
    if (url.pathname === '/application') {
      if (options.redirectApplication) return new Response(null, { status: 302, headers: { Location: 'https://evil.test/collect' } });
      return Response.json({ environment, kid: appID, active: true, services: ['AIS'], redirect_urls: [`${host}/v1/callback`] });
    }
    if (url.pathname === '/aspsps') return Response.json({ aspsps: options.aspsps ?? [{ name: 'BBVA', country: 'ES', psu_types: ['personal'], maximum_consent_validity: 86400, beta: false }] });
    if (url.pathname === '/auth') {
      const body = await request.json();
      assert.equal(body.redirect_url, `${host}/v1/callback`);
      assert.equal(body.psu_type, 'personal');
      assert.equal(body.aspsp.name, options.bankName ?? 'BBVA');
      return Response.json({ url: `${options.authorizationOrigin ?? (production ? 'https://tilisy.enablebanking.com' : 'https://auth.enablebanking.com')}/authorize?state=${body.state}` });
    }
    if (url.pathname === '/sessions') {
      assert.deepEqual(await request.json(), { code: 'fictitious-code' });
      return Response.json({ session_id: sessionID, aspsp: { name: options.bankName ?? 'BBVA', country: 'ES' }, psu_type: 'personal', access: { valid_until: new Date(Date.now() + 86400_000).toISOString() },
        accounts: options.scenario?.accounts.map(a => ({ ...a.info, uid: a.info.resource_id })) ?? [{ uid: accountID, name: 'Sandbox account', currency: 'EUR', account_id: { iban: production ? 'ES7620770024003102575766' : 'FICTITIOUS-IBAN-1234' } }] });
    }
    if (options.scenario && url.pathname.startsWith('/accounts/')) {
      const data = options.scenario.accounts.find(a => url.pathname.split('/')[2] === a.info.resource_id);
      assert.ok(data, 'Only authorized provider accounts can be queried');
      if (url.pathname.endsWith('/balances')) return Response.json({ balances: data.balances });
      const offset = Number(url.searchParams.get('continuation_key') ?? 0);
      return Response.json({ transactions: data.transactions.slice(offset, offset + 10),
        continuation_key: offset + 10 < data.transactions.length ? String(offset + 10) : null });
    }
    if (url.pathname.endsWith('/balances')) return Response.json({ balances: [{ balance_amount: { amount: '10.00', currency: 'EUR' }, balance_type: 'CLBD' }] });
    if (url.pathname.endsWith('/transactions')) return Response.json({ transactions: [{ status: 'BOOK', entry_reference: 'fixture-reference',
      transaction_amount: { amount: '10.00', currency: 'EUR' }, credit_debit_indicator: 'DBIT',
      booking_date: new Date().toISOString().slice(0, 10), remittance_information: ['Fictitious purchase'] }],
      continuation_key: url.searchParams.has('continuation_key') ? null : 'next-page' });
    if (url.pathname === `/sessions/${sessionID}` && request.method === 'DELETE') return new Response(null, { status: options.revokeStatus ?? 204 });
    throw new Error('Unexpected provider endpoint');
  });
  if (production) token = 'fixture.payload.signature';
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

test('sandbox exposes verified Spanish personal test banks and supports Mock ASPSP through consent and revocation', async () => {
  const entry = (name, country = 'ES', psu_types = ['personal']) => ({ name, country, psu_types, maximum_consent_validity: 86400, beta: false });
  await sandboxFixture('SANDBOX', { bankName: 'Mock ASPSP', authorizationOrigin: 'https://tilisy-sandbox.enablebanking.com', aspsps: [
    entry('BBVA'), entry('Banco de Sabadell'), entry('Mock ASPSP'), entry('Mock ASPSP', 'DE'),
    entry('ING'), entry('Bankinter'), entry('Trade Republic'), entry('BBVA', 'ES', ['business'])
  ] });
  const catalog = await call('/v1/banks');
  assert.equal(catalog.status, 200);
  assert.deepEqual((await catalog.json()).banks.map(bank => bank.name), ['Banco de Sabadell', 'Bankinter', 'BBVA', 'ING', 'Mock ASPSP', 'Trade Republic']);
  const flow = await start('Mock ASPSP');
  assert.equal(new URL(flow.authorizationURL).origin, 'https://tilisy-sandbox.enablebanking.com');
  const state = new URL(flow.authorizationURL).searchParams.get('state');
  const completed = await mf.dispatchFetch(`${host}/v1/callback?state=${state}&code=fictitious-code`, { redirect: 'manual' });
  assert.equal(completed.status, 303);
  assert.match(completed.headers.get('Location'), /result=ok/);
  const sessions = (await (await call('/v1/connections')).json()).connections;
  assert.equal(sessions.length, 1);
  assert.equal(sessions[0].bank, 'Mock ASPSP');
  assert.equal((await call(`/v1/connections/${sessions[0].id}`, { method: 'DELETE' })).status, 204);
  const forbidden = await call('/v1/authorizations', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ bank: 'Unknown' }) });
  assert.equal(forbidden.status, 400);
});

test('demo cannot select a sandbox-only bank', async () => {
  const response = await call('/v1/authorizations', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ bank: 'Mock ASPSP' }) });
  assert.equal(response.status, 400);
  assert.deepEqual(await response.json(), { error: 'unsupported_bank' });
});

test('sandbox rejects a provider authorization URL on a lookalike host and removes its pending request', async () => {
  await sandboxFixture('SANDBOX', { authorizationOrigin: 'https://tilisy-sandbox.enablebanking.com.evil.test' });
  const response = await call('/v1/authorizations', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ bank: 'BBVA' }) });
  assert.equal(response.status, 502);
  assert.deepEqual(await response.json(), { error: 'authorization_destination_rejected' });
  assert.equal((await db.prepare('SELECT COUNT(*) AS n FROM auth_requests').first()).n, 0);
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


test('complete Mock scenario survives D1 encryption, pagination and renewed consents without leaking IBANs', async () => {
  const { fixture, expected } = generateScenario();
  await sandboxFixture('SANDBOX', { bankName: 'Mock ASPSP', scenario: fixture,
    aspsps: [{ name: 'Mock ASPSP', country: 'ES', psu_types: ['personal'], maximum_consent_validity: 86400 }] });
  const connections = [];
  for (let renewal = 0; renewal < 2; renewal++) {
    const flow = await start('Mock ASPSP');
    const state = new URL(flow.authorizationURL).searchParams.get('state');
    const result = await mf.dispatchFetch(`${host}/v1/callback?state=${state}&code=fictitious-code`, { redirect: 'manual' });
    assert.match(result.headers.get('Location'), /result=ok/);
    const all = (await (await call('/v1/connections')).json()).connections;
    connections.push(all.find(c => c.id === flow.id));
  }
  const [first, renewed] = connections;
  assert.equal(first.testScenario, 'mi-patrimonio-v1');
  assert.equal(first.accounts.length, 3);
  assert.deepEqual(first.accounts.map(a => a.id).sort(), renewed.accounts.map(a => a.id).sort());
  assert.equal(new Set(first.accounts.map(a => a.ownershipKey)).size, 3);
  const today = new Date().toISOString().slice(0, 10);
  const from = new Date(Date.now() - 89 * 86400_000).toISOString().slice(0, 10);
  let count = 0, pairedLegs = 0;
  for (const account of renewed.accounts) {
    let cursor, rows = [], balance;
    do {
      const path = `/v1/connections/${renewed.id}/accounts/${account.id}?from=${from}&to=${today}` + (cursor ? `&continuation=${cursor}` : '');
      const response = await call(path); assert.equal(response.status, 200);
      const data = await response.json();
      if (!cursor) balance = data.balances[0]; else assert.deepEqual(data.balances, []);
      rows.push(...data.transactions); cursor = data.continuation;
    } while (cursor);
    count += rows.length;
    pairedLegs += rows.filter(r => r.counterpartyKey && r.transferKey).length;
    assert.equal(new Set(rows.map(r => r.id)).size, rows.length);
    assert.equal(balance.amountMinor, expected.balances.find(b => b.role === account.testRole).balanceMinor);
    const encoded = JSON.stringify({ account, rows });
    for (const a of fixture.accounts) assert.ok(!encoded.includes(a.info.account_id.iban));
  }
  assert.equal(count, expected.statementRows);
  assert.equal(pairedLegs, expected.transferPairs * 2);
  const stored = JSON.stringify((await db.prepare('SELECT * FROM connections').all()).results);
  for (const a of fixture.accounts) assert.ok(!stored.includes(a.info.account_id.iban));
});


test('personal production verifies owner identity end-to-end, encrypts consent, imports only authorised reads and revokes', async () => {
  await sandboxFixture('PRODUCTION', { production: true, bankName: 'Bankinter',
    aspsps: [{ name: 'Bankinter', country: 'ES', psu_types: ['personal'], maximum_consent_validity: 180 * 86400 }] });
  assert.deepEqual(await (await call('/v1/status')).json(), { mode: 'production', liveBankingEnabled: true, accountingImportEnabled: true });
  assert.equal((await call('/v1/connections', { headers: { Authorization: 'Bearer other.payload.signature' } })).status, 403);
  assert.equal((await call('/v1/connections', { headers: { Authorization: `Bearer ${'a'.repeat(64)}` } })).status, 401);
  const flow = await start('Bankinter');
  assert.equal(new URL(flow.authorizationURL).origin, 'https://tilisy.enablebanking.com', 'The real production authorization origin must work');
  const state = new URL(flow.authorizationURL).searchParams.get('state');
  const callback = await mf.dispatchFetch(`${host}/v1/callback?state=${state}&code=fictitious-code`, { redirect: 'manual' });
  assert.equal(callback.status, 303);
  assert.match(callback.headers.get('Location'), /result=ok/);
  assert.equal((await mf.dispatchFetch(`${host}/v1/callback?state=${state}&code=fictitious-code`)).status, 400);
  const stored = JSON.stringify((await db.prepare('SELECT * FROM connections').all()).results);
  assert.ok(!stored.includes('ES7620770024003102575766'));
  const first = (await (await call('/v1/connections')).json()).connections[0];
  assert.equal(first.accounts[0].name, 'Cuenta •••• 5766');
  assert.ok(!JSON.stringify(first).includes('sessionID'));
  const to = new Date().toISOString().slice(0, 10);
  const query = `/v1/connections/${first.id}/accounts/${first.accounts[0].id}?from=${to}&to=${to}`;
  const data = await call(query);
  assert.equal(data.status, 200);
  assert.equal((await data.json()).transactions[0].signedAmountMinor, -1000);
  const renewal = await start('Bankinter');
  const renewedState = new URL(renewal.authorizationURL).searchParams.get('state');
  await mf.dispatchFetch(`${host}/v1/callback?state=${renewedState}&code=fictitious-code`, { redirect: 'manual' });
  const renewed = (await (await call('/v1/connections')).json()).connections;
  assert.equal(renewed.length, 1, 'Renewed consents must not expose two copies of the same account');
  assert.equal(renewed[0].id, renewal.id);
  assert.equal(renewed[0].accounts[0].id, first.accounts[0].id);
  assert.equal((await call('/v1/payments', { method: 'POST' })).status, 404);
  assert.equal((await call(`/v1/connections/${renewal.id}`, { method: 'DELETE' })).status, 204);
  assert.equal((await db.prepare('SELECT count(*) AS n FROM connections').first()).n, 0, 'Disconnect revokes superseded permissions from the same bank too');
});


test('production also accepts the new official auth origin during the provider migration', async () => {
  await sandboxFixture('PRODUCTION', { production: true, authorizationOrigin: 'https://auth.enablebanking.com' });
  const flow = await start();
  assert.equal(new URL(flow.authorizationURL).origin, 'https://auth.enablebanking.com');
});

test('production refuses sandbox, lookalike hosts, HTTP, credentials and alternate ports', async () => {
  for (const authorizationOrigin of ['https://tilisy-sandbox.enablebanking.com', 'https://tilisy.enablebanking.com.evil.test',
    'http://tilisy.enablebanking.com', 'https://user:password@tilisy.enablebanking.com', 'https://tilisy.enablebanking.com:8443']) {
    await sandboxFixture('PRODUCTION', { production: true, authorizationOrigin });
    const response = await call('/v1/authorizations', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ bank: 'BBVA' }) });
    assert.equal(response.status, 502);
    assert.deepEqual(await response.json(), { error: 'authorization_destination_rejected' });
    assert.equal((await db.prepare('SELECT count(*) AS n FROM auth_requests').first()).n, 0, 'Rejected destinations leave no pending flow');
  }
});
