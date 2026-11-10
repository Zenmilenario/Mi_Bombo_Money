import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, randomBytes } from 'node:crypto';
import { authenticate, mode, accountIdentity, seal, unseal } from '../src/security.mjs';
import { banks, exchange, verifySandbox, accountData } from '../src/provider.mjs';
import { personalConfiguration } from '../tools/setup-personal.mjs';

const { privateKey } = generateKeyPairSync('rsa', { modulusLength: 4096 });
const env = { PROVIDER_MODE: 'production', BANKING_AUTH: 'supabase-owner',
  PUBLIC_ORIGIN: 'https://bank-test.personal.workers.dev',
  SUPABASE_URL: 'https://coeicjffmpclqowsqeys.supabase.co', SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_fixture',
  SUPABASE_OWNER_ID: crypto.randomUUID(), ACCOUNT_IDENTITY_KEY: randomBytes(32).toString('base64'),
  ENABLE_APP_ID: crypto.randomUUID(), ENABLE_PRIVATE_KEY: privateKey.export({ type: 'pkcs8', format: 'pem' }) };
const application = { environment: 'PRODUCTION', kid: env.ENABLE_APP_ID, active: true, services: ['AIS'], redirect_urls: [`${env.PUBLIC_ORIGIN}/v1/callback`] };

test('encrypted production sessions cannot be reassigned by changing the configured owner', async () => {
  const configured = { ...env, DATA_ENCRYPTION_KEY: randomBytes(32).toString('base64') };
  const encrypted = await seal({ sessionID: 'fixture' }, 'connection:fixture', configured);
  assert.deepEqual(await unseal(encrypted, 'connection:fixture', configured), { sessionID: 'fixture' });
  await assert.rejects(unseal(encrypted, 'connection:fixture', { ...configured, SUPABASE_OWNER_ID: crypto.randomUUID() }), { code: 'invalid_connection' });
});

test('personal setup generates separate keys and never includes them in public configuration', () => {
  const options = { appID: crypto.randomUUID(), ownerID: crypto.randomUUID(), databaseID: crypto.randomUUID(),
    pem: env.ENABLE_PRIVATE_KEY, publishableKey: env.SUPABASE_PUBLISHABLE_KEY };
  const first = personalConfiguration(options); const other = personalConfiguration(options);
  assert.equal(first.config.name, 'mi-bombo-banking-personal');
  assert.notEqual(first.secrets.DATA_ENCRYPTION_KEY, other.secrets.DATA_ENCRYPTION_KEY);
  assert.notEqual(first.secrets.DATA_ENCRYPTION_KEY, first.secrets.ACCOUNT_IDENTITY_KEY);
  assert.equal(first.config.observability.enabled, false);
  assert.ok(!JSON.stringify(first.config).includes('PRIVATE KEY'));
  assert.throws(() => personalConfiguration({ ...options, databaseID: '00000000-0000-0000-0000-000000000000' }));
});

test('production fails closed without explicit identity, trusted Auth project and independent identity key', () => {
  assert.equal(mode(env), 'production');
  for (const field of ['BANKING_AUTH', 'SUPABASE_URL', 'SUPABASE_OWNER_ID', 'SUPABASE_PUBLISHABLE_KEY', 'ACCOUNT_IDENTITY_KEY']) {
    assert.throws(() => mode({ ...env, [field]: '' }), { code: 'live_banking_disabled' });
  }
  assert.throws(() => mode({ ...env, SUPABASE_URL: 'https://evil.test' }));
});

test('production authenticates the JWT against Supabase and allows only the configured owner', async () => {
  const request = new Request(env.PUBLIC_ORIGIN, { headers: { Authorization: 'Bearer fixture.payload.signature' } });
  const transport = async (url, options) => {
    assert.equal(url, `${env.SUPABASE_URL}/auth/v1/user`);
    assert.equal(options.redirect, 'manual');
    assert.equal(options.headers.Authorization, 'Bearer fixture.payload.signature');
    assert.equal(options.headers.apikey, env.SUPABASE_PUBLISHABLE_KEY);
    return Response.json({ id: env.SUPABASE_OWNER_ID });
  };
  assert.equal(await authenticate(request, env, transport), env.SUPABASE_OWNER_ID);
  await assert.rejects(authenticate(request, env, async () => Response.json({ id: crypto.randomUUID() })), { code: 'owner_required' });
  await assert.rejects(authenticate(request, env, async () => Response.json({ id: env.SUPABASE_OWNER_ID, is_anonymous: true })), { code: 'owner_required' });
  await assert.rejects(authenticate(request, env, async () => new Response(null, { status: 401 })), { code: 'unauthorized' });
  await assert.rejects(authenticate(request, env, async () => new Response(null, { status: 302 })), { code: 'identity_unavailable' });
  await assert.rejects(authenticate(new Request(env.PUBLIC_ORIGIN, { headers: { Authorization: `Bearer ${'a'.repeat(64)}` } }), env, transport), { code: 'unauthorized' });
});

test('production refuses sandbox keys, inactive applications, missing AIS and wrong callbacks', async () => {
  for (const change of [{ environment: 'SANDBOX' }, { active: false }, { services: ['PIS'] }, { services: ['AIS', 'PIS'] }, { redirect_urls: ['https://evil.test'] }]) {
    await assert.rejects(verifySandbox(env, async () => Response.json({ ...application, ...change })), { code: 'production_configuration_required' });
  }
});

test('catalogue is dynamic but constrained to Spain, personal use and provider data', async () => {
  const entry = (name, country = 'ES', psu_types = ['personal']) => ({ name, country, psu_types, maximum_consent_validity: 86400 });
  const result = await banks(env, async url => Response.json(url.endsWith('/application') ? application : {
    aspsps: [entry('Santander'), entry('ING'), entry('Bankinter'), entry('Banco de Sabadell'), entry('Only business', 'ES', ['business']), entry('Foreign', 'NL'), entry('ING')]
  }));
  assert.deepEqual(result.map(x => x.name), ['Banco de Sabadell', 'Bankinter', 'ING', 'Santander']);
});

test('renewed consent preserves account and transaction namespace without exposing IBAN or session UID', async () => {
  const transport = async url => Response.json(url.endsWith('/application') ? application : {
    session_id: crypto.randomUUID(), aspsp: { name: 'Bankinter', country: 'ES' }, psu_type: 'personal',
    access: { valid_until: new Date(Date.now() + 86400000).toISOString() },
    accounts: [{ uid: crypto.randomUUID(), currency: 'EUR', account_id: { iban: 'ES7620770024003102575766' } }]
  });
  const first = await exchange('fixture', 'Bankinter', env, transport);
  const renewed = await exchange('fixture', 'Bankinter', env, transport);
  assert.notEqual(first.sessionID, renewed.sessionID);
  assert.notEqual(first.accounts[0].uid, renewed.accounts[0].uid);
  assert.equal(first.accounts[0].id, renewed.accounts[0].id);
  assert.equal(first.accounts[0].ownershipKey, renewed.accounts[0].ownershipKey);
  assert.ok(!first.accounts[0].name.includes('ES76'));
  assert.notEqual(await accountIdentity('ES7620770024003102575766', env), await accountIdentity('ES7620770024003102575766', { ...env, ACCOUNT_IDENTITY_KEY: randomBytes(32).toString('base64') }));
});

test('provider failures distinguish actionable causes without exposing provider bodies or identifiers', async t => {
  const logs = [];
  t.mock.method(console, 'warn', value => logs.push(JSON.parse(value)));
  const cases = [
    ['EXPIRED_SESSION', 'bank_session_expired'], ['REVOKED_SESSION', 'bank_session_expired'],
    ['ASPSP_PSU_ACTION_REQUIRED', 'bank_action_required'], ['ASPSP_TIMEOUT', 'bank_timeout'],
    ['ASPSP_RATE_LIMIT_EXCEEDED', 'bank_rate_limited'], ['PSU_HEADER_NOT_PROVIDED', 'bank_psu_headers_required'],
    ['PSU_HEADER_INVALID', 'bank_psu_headers_required'], ['ASPSP_ACCOUNT_NOT_ACCESSIBLE', 'bank_account_unavailable'],
    ['WRONG_TRANSACTIONS_PERIOD', 'bank_history_unavailable'], ['WRONG_CONTINUATION_KEY', 'bank_request_rejected'],
    ['ACCESS_DENIED', 'provider_access_denied'], ['ASPSP_ERROR', 'bank_unavailable'],
    ['private-unrecognized-code', 'bank_unavailable']
  ];
  const remote = { id: 'private-stable-account', uid: 'private-provider-uid', currency: 'EUR' };
  for (const [error, expected] of cases) {
    await assert.rejects(accountData({}, remote, '2026-09-01', '2026-11-03', null, env,
      async url => url.endsWith('/application') ? Response.json(application)
        : Response.json({ error, message: 'private-bank-message', detail: { iban: 'private-iban', token: 'private-token' } }, { status: 400 })),
    { code: expected, status: expected === 'bank_rate_limited' ? 429 : 502 });
    assert.deepEqual(logs.at(-1), { event: 'banking_provider_failure', operation: 'transactions', status: 400,
      code: error === 'private-unrecognized-code' ? 'UNKNOWN' : error });
  }
  assert.ok(!JSON.stringify(logs).includes('private-'));
});

test('provider cooldown honours numeric and date Retry-After, with a six-hour fallback', async t => {
  t.mock.method(console, 'warn', () => {});
  const now = Date.now();
  for (const [header, minimum, maximum] of [[null, 21600, 21600], ['900', 900, 900],
    ['bad-private-value', 21600, 21600], ['0', 60, 60], ['99999999', 604800, 604800],
    [new Date(now + 3600000).toUTCString(), 3590, 3600]]) {
    await assert.rejects(verifySandbox(env, async () => Response.json({ error: 'ASPSP_RATE_LIMIT_EXCEEDED' },
      { status: 429, headers: header ? { 'Retry-After': header } : {} })), error => {
      assert.equal(error.code, 'bank_rate_limited');
      assert.ok(error.retryAfter >= minimum && error.retryAfter <= maximum);
      return true;
    });
  }
});

test('invalid bank feed reports one fixed diagnostic without exposing transaction data', async t => {
  const logs = [];
  t.mock.method(console, 'warn', value => logs.push(JSON.parse(value)));
  const remote = { id: 'private-account', uid: 'private-uid', currency: 'EUR' };
  const invalid = { status: 'BOOK', booking_date: 'private-date', credit_debit_indicator: 'CRDT',
    transaction_amount: { amount: '12.30', currency: 'EUR' }, remittance_information: ['private-description'] };
  await assert.rejects(accountData({}, remote, '2026-09-01', '2026-11-03', null, env, async url => {
    if (url.endsWith('/application')) return Response.json(application);
    assert.ok(url.includes('/transactions?'));
    return Response.json({ transactions: [invalid, invalid] });
  }), { code: 'invalid_provider_data' });
  assert.deepEqual(logs, [{ event: 'banking_feed_validation', operation: 'transactions', field: 'booking_date' }]);
});

test('balance failures, throttling and malformed error bodies stay bounded and retain only fixed diagnostics', async t => {
  const logs = [];
  t.mock.method(console, 'warn', value => logs.push(JSON.parse(value)));
  const remote = { id: 'private-account', uid: 'private-uid', currency: 'EUR' };
  for (const [body, status, expected, safeCode] of [
    [JSON.stringify({ error: 'ASPSP_RATE_LIMIT_EXCEEDED' }), 429, 'bank_rate_limited', 'ASPSP_RATE_LIMIT_EXCEEDED'],
    ['not-json-private', 503, 'bank_unavailable', 'UNKNOWN'],
    [JSON.stringify({ error: 'ASPSP_ERROR', detail: 'private'.repeat(5000) }), 502, 'bank_unavailable', 'UNKNOWN']
  ]) {
    await assert.rejects(accountData({}, remote, '2026-09-01', '2026-11-03', null, env, async url => {
      if (url.endsWith('/application')) return Response.json(application);
      if (url.includes('/transactions?')) return Response.json({ transactions: [] });
      return new Response(body, { status });
    }), { code: expected, status: status === 429 ? 429 : 502 });
    assert.deepEqual(logs.at(-1), { event: 'banking_provider_failure', operation: 'balances', status, code: safeCode });
  }
  assert.ok(!JSON.stringify(logs).includes('private'));
});

test('pending and held entries are read alongside bookings and kept out of the booked feed', async () => {
  const remote = { id: 'fixture-account', uid: 'fixture-uid', currency: 'EUR' };
  const amount = { transaction_amount: { amount: '12.30', currency: 'EUR' }, credit_debit_indicator: 'DBIT' };
  const held = { ...amount, status: 'HOLD', entry_reference: 'fixture-hold',
    transaction_date: '2026-11-02', remittance_information: ['Compra ficticia'] };
  const booked = { ...amount, status: 'BOOK', booking_date: '2026-11-03', entry_reference: 'fixture-booked' };
  const pending = { ...amount, status: 'PDNG', transaction_date: '2026-11-02' };
  const balances = [{ balance_amount: { amount: '100.00', currency: 'EUR' }, balance_type: 'ITBD' },
    { balance_amount: { amount: '87.70', currency: 'EUR' }, balance_type: 'ITAV' }];
  async function download(includePending, rows) {
    let movementRequests = 0;
    const result = await accountData({}, remote, '2026-11-01', '2026-11-03', null, env, async url => {
      if (url.endsWith('/application')) return Response.json(application);
      if (url.endsWith('/balances')) return Response.json({ balances });
      movementRequests++;
      assert.equal(new URL(url).searchParams.get('transaction_status'), includePending ? null : 'BOOK');
      return Response.json({ transactions: rows });
    }, {}, includePending);
    assert.equal(movementRequests, 1);
    return result;
  }
  const first = await download(true, [booked, held, pending, { ...pending, status: 'CNCL' },
    { ...pending, transaction_amount: { amount: 'invalid', currency: 'EUR' } }]);
  assert.equal(first.transactions.length, 1);
  assert.deepEqual(first.pendingTransactions.map(row => [row.status, row.signedAmountMinor, row.date]),
    [['HOLD', -1230, '2026-11-02'], ['PDNG', -1230, '2026-11-02']]);
  assert.equal(first.pendingTransactions[1].id, null);
  assert.deepEqual(first.ignoredStatuses, { CNCL: 1 }, 'Entries with other statuses are counted, not imported');
  assert.deepEqual(first.balances.map(row => row.amountMinor), [10000, 8770]);
  const settled = await download(true, [booked, { ...held, status: 'BOOK', booking_date: '2026-11-03' }]);
  assert.deepEqual(settled.pendingTransactions, []);
  assert.equal(settled.transactions[1].id, first.pendingTransactions[0].id);
  const legacy = await download(false, [booked, held]);
  assert.equal(legacy.transactions.length, 1);
  assert.equal(legacy.pendingTransactions, undefined);
  assert.equal(legacy.ignoredStatuses, undefined);
  const odd = await download(true, [booked, { ...pending, status: undefined }, { ...pending, status: 'info' }, { ...pending, status: 'OTHR' }]);
  assert.deepEqual(odd.ignoredStatuses, { NONE: 1, OTHER: 1, OTHR: 1 });
  assert.equal(odd.transactions.length, 1);
});
