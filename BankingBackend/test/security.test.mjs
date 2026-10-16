import test from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes, generateKeyPairSync } from 'node:crypto';
import { authenticate, origin, mode, seal, unseal, sha256, readJSON, now } from '../src/security.mjs';
import { providerJWT, verifySandbox, amountMinor, normalizeTransaction, accountData } from '../src/provider.mjs';

const token = randomBytes(32).toString('hex');
const env = { PROVIDER_MODE: 'demo', PUBLIC_ORIGIN: 'https://bank-test.personal.workers.dev',
  ACCESS_TOKEN_SHA256: await sha256(token), DATA_ENCRYPTION_KEY: randomBytes(32).toString('base64') };

test('demo booking dates stay stable across queries and respect the requested history range', async () => {
  const connection = { validUntil: '2026-10-16T12:00:00.000Z' };
  const first = await accountData(connection, {}, '2026-10-01', '2026-10-15', null, env);
  const later = await accountData(connection, {}, '2026-10-01', '2026-10-16', null, env);
  assert.deepEqual(first, later);
  assert.equal(first.transactions[0].bookingDate, '2026-10-15');
  const outside = await accountData(connection, {}, '2026-10-16', '2026-10-16', null, env);
  assert.deepEqual(outside.transactions, []);
});

test('authentication refuses missing, malformed, truncated and wrong bearer credentials', async () => {
  for (const auth of [null, '', `Bearer ${'b'.repeat(64)}`, `Basic ${token}`, `Bearer ${token.slice(1)}`]) {
    const request = new Request(env.PUBLIC_ORIGIN, { headers: auth ? { Authorization: auth } : {} });
    await assert.rejects(authenticate(request, env), { code: 'unauthorized', status: 401 });
  }
  await authenticate(new Request(env.PUBLIC_ORIGIN, { headers: { Authorization: `Bearer ${token}` } }), env);
  await assert.rejects(authenticate(new Request(env.PUBLIC_ORIGIN), { ...env, ACCESS_TOKEN_SHA256: '' }), { code: 'not_configured' });
});

test('only an exact HTTPS workers.dev origin is accepted; production is never enabled', () => {
  assert.equal(origin(env), env.PUBLIC_ORIGIN);
  for (const PUBLIC_ORIGIN of ['http://bank-test.personal.workers.dev', 'https://evil.test',
    'https://bank-test.personal.workers.dev.evil.test', 'https://user:pass@bank-test.personal.workers.dev',
    'https://bank-test.personal.workers.dev/path', 'https://bank-test.personal.workers.dev?redirect=evil']) {
    assert.throws(() => origin({ ...env, PUBLIC_ORIGIN }), { code: 'not_configured' });
  }
  for (const PROVIDER_MODE of ['production', 'PRODUCTION', '', undefined]) {
    assert.throws(() => mode({ ...env, PROVIDER_MODE }), { code: 'live_banking_disabled' });
  }
});

test('encrypted sessions hide identifiers; tampering, row swaps, environment swaps and wrong keys fail', async () => {
  const value = { sessionID: 'sensitive-session', bank: 'Bankinter', iban: 'sensitive-iban' };
  const sealed = await seal(value, 'connection:first', env);
  assert.ok(!sealed.includes('sensitive'));
  assert.deepEqual(await unseal(sealed, 'connection:first', env), value);
  await assert.rejects(unseal(sealed, 'connection:other', env), { code: 'invalid_connection' });
  await assert.rejects(unseal(sealed, 'connection:first', { ...env, PROVIDER_MODE: 'sandbox' }), { code: 'invalid_connection' });
  await assert.rejects(unseal(sealed, 'connection:first', { ...env, DATA_ENCRYPTION_KEY: randomBytes(32).toString('base64') }), { code: 'invalid_connection' });
  const [iv, ciphertext] = sealed.split('.');
  const bytes = Buffer.from(ciphertext, 'base64url'); bytes[0] ^= 1;
  await assert.rejects(unseal(`${iv}.${bytes.toString('base64url')}`, 'connection:first', env), { code: 'invalid_connection' });
});

test('JSON validation rejects large, ambiguous and extra configuration fields', async () => {
  const request = value => new Request(env.PUBLIC_ORIGIN, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: value });
  await assert.rejects(readJSON(request(JSON.stringify({ bank: 'BBVA', redirectURL: 'https://evil.test' })), ['bank']), { code: 'invalid_request' });
  await assert.rejects(readJSON(request('['), ['bank']), { code: 'invalid_request' });
  await assert.rejects(readJSON(request(JSON.stringify({ bank: 'x'.repeat(3000) })), ['bank']), { code: 'payload_too_large' });
  await assert.rejects(readJSON(new Request(env.PUBLIC_ORIGIN, { method: 'POST', body: '{}' }), ['bank']), { code: 'json_required' });
});

test('bank amounts use exact cents and debit direction; pending or malformed data never become booked movements', async () => {
  assert.equal(amountMinor('1234.56'), 123456);
  assert.equal(amountMinor('-0.01'), -1);
  for (const invalid of ['1,23', '12.345', 'NaN', '1e3', '99999999999999.99', null]) assert.throws(() => amountMinor(invalid));
  const account = { id: 'account', currency: 'EUR' };
  const booked = { status: 'BOOK', entry_reference: 'reference', transaction_amount: { amount: '12.30', currency: 'EUR' },
    credit_debit_indicator: 'DBIT', booking_date: '2026-10-10', remittance_information: ['Compra de prueba'] };
  const actual = await normalizeTransaction(booked, account);
  assert.equal(actual.signedAmountMinor, -1230);
  assert.ok(!actual.id.includes('reference'));
  assert.equal(await normalizeTransaction({ ...booked, status: 'PDNG' }, account), null);
  await assert.rejects(normalizeTransaction({ ...booked, credit_debit_indicator: 'invalid' }, account));
  await assert.rejects(normalizeTransaction({ ...booked, booking_date: '2026-02-30' }, account));
  await assert.rejects(normalizeTransaction({ ...booked, transaction_amount: { amount: '-12.30', currency: 'EUR' } }, account));
});

test('RSA JWT has short lifetime, correct audience and verified signature; production application keys cannot authorize a sandbox', async () => {
  const { privateKey, publicKey } = generateKeyPairSync('rsa', { modulusLength: 4096 });
  const sandbox = { ...env, PROVIDER_MODE: 'sandbox', ENABLE_APP_ID: crypto.randomUUID(),
    ENABLE_PRIVATE_KEY: privateKey.export({ type: 'pkcs8', format: 'pem' }) };
  const jwt = await providerJWT(sandbox);
  const [header, payload, signature] = jwt.split('.');
  assert.equal(JSON.parse(Buffer.from(header, 'base64url')).alg, 'RS256');
  const claims = JSON.parse(Buffer.from(payload, 'base64url'));
  assert.equal(claims.aud, 'api.enablebanking.com');
  assert.ok(claims.exp <= now() + 300);
  const verificationKey = await crypto.subtle.importKey('spki', publicKey.export({ type: 'spki', format: 'der' }),
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['verify']);
  assert.ok(await crypto.subtle.verify('RSASSA-PKCS1-v1_5', verificationKey, Buffer.from(signature, 'base64url'), new TextEncoder().encode(`${header}.${payload}`)));
  const requests = [];
  await assert.rejects(verifySandbox(sandbox, async (url, options) => {
    requests.push(url);
    assert.equal(options.redirect, 'manual');
    return Response.json({ environment: 'PRODUCTION', kid: sandbox.ENABLE_APP_ID, active: true, services: ['AIS'],
      redirect_urls: [`${env.PUBLIC_ORIGIN}/v1/callback`] });
  }), { code: 'sandbox_configuration_required' });
  assert.deepEqual(requests, ['https://api.enablebanking.com/application']);
});
