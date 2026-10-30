import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, randomBytes } from 'node:crypto';
import { authenticate, mode, accountIdentity, seal, unseal } from '../src/security.mjs';
import { banks, exchange, verifySandbox } from '../src/provider.mjs';
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
