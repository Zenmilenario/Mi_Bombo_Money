import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { readFileSync, readdirSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { authenticate, allowedUsers, mode, seal } from '../src/security.mjs';
import { newAuthorization, claimAuthorization, saveConnection, connection, listConnections, ownerTag, rateLimit } from '../src/store.mjs';

/// A D1-shaped wrapper over Node's SQLite, with the real migrations applied.
function database() {
  const db = new DatabaseSync(':memory:');
  for (const file of readdirSync(new URL('../migrations/', import.meta.url)).sort()) {
    db.exec(readFileSync(new URL(`../migrations/${file}`, import.meta.url), 'utf8'));
  }
  const statement = (sql, args = []) => ({
    bind: (...values) => statement(sql, values),
    first: async () => db.prepare(sql).get(...args) ?? null,
    all: async () => ({ results: db.prepare(sql).all(...args) }),
    run: async () => db.prepare(sql).run(...args)
  });
  return { prepare: sql => statement(sql), batch: async statements => Promise.all(statements.map(s => s.run())), raw: db };
}

const owner = crypto.randomUUID(), guestA = crypto.randomUUID(), guestB = crypto.randomUUID(), stranger = crypto.randomUUID();
function environment(guests = `${guestA}, ${guestB.toUpperCase()}`) {
  return { PROVIDER_MODE: 'production', BANKING_AUTH: 'supabase-owner', PUBLIC_ORIGIN: 'https://bank-test.personal.workers.dev',
    SUPABASE_URL: 'https://coeicjffmpclqowsqeys.supabase.co', SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_fixture',
    SUPABASE_OWNER_ID: owner, SUPABASE_GUEST_IDS: guests, ACCOUNT_IDENTITY_KEY: randomBytes(32).toString('base64'),
    DATA_ENCRYPTION_KEY: randomBytes(32).toString('base64'), DB: database() };
}
const validUntil = new Date(Date.now() + 30 * 86400_000).toISOString();
const fictitious = bank => ({ bank, validUntil, sessionID: `session-${bank}`, accounts: [{ id: `acc-${bank}`, name: 'Cuenta ficticia', currency: 'EUR', lastFour: '0000' }] });

test('the owner and any number of invited users are admitted; nobody else, and malformed lists fail closed', async () => {
  const env = environment();
  assert.deepEqual(allowedUsers(env), new Set([owner, guestA, guestB]));
  const request = new Request(env.PUBLIC_ORIGIN, { headers: { Authorization: 'Bearer fixture.payload.signature' } });
  for (const id of [owner, guestA, guestB]) {
    assert.equal(await authenticate(request, env, async () => Response.json({ id })), id);
  }
  await assert.rejects(authenticate(request, env, async () => Response.json({ id: stranger })), { code: 'owner_required' });
  await assert.rejects(authenticate(request, env, async () => Response.json({ id: guestA, is_anonymous: true })), { code: 'owner_required' });
  assert.equal(mode(environment('')), 'production', 'Without guests the server keeps working for its owner');
  const many = Array.from({ length: 25 }, () => crypto.randomUUID()).join(',');
  assert.equal(allowedUsers(environment(many)).size, 26, 'No fixed number of invited users');
  assert.throws(() => mode(environment(`${guestA},no-es-un-id`)), { code: 'live_banking_disabled' });
});

test('each user only lists, opens and decrypts their own bank connections', async () => {
  const env = environment();
  await saveConnection(crypto.randomUUID(), fictitious('Banco del dueño'), env, owner);
  const guestConnection = crypto.randomUUID();
  await saveConnection(guestConnection, fictitious('Banco invitado A'), env, guestA);
  await saveConnection(crypto.randomUUID(), fictitious('Banco invitado B'), env, guestB);
  assert.deepEqual((await listConnections(env, false, owner)).map(c => c.bank), ['Banco del dueño']);
  assert.deepEqual((await listConnections(env, false, guestA)).map(c => c.bank), ['Banco invitado A']);
  assert.deepEqual((await listConnections(env, false, guestB.toUpperCase())).map(c => c.bank), ['Banco invitado B']);
  assert.equal((await connection(guestConnection, env, guestA)).sessionID, 'session-Banco invitado A');
  await assert.rejects(connection(guestConnection, env, owner), { code: 'connection_not_found' }, 'The owner cannot open a guest connection');
  await assert.rejects(connection(guestConnection, env, guestB), { code: 'connection_not_found' });
  await assert.rejects(saveConnection(crypto.randomUUID(), fictitious('Intruso'), env, stranger), { code: 'owner_required' });
  // Even with the owner marker swapped in the table, another user's key scope cannot decrypt the row.
  env.DB.raw.prepare('UPDATE connections SET owner=? WHERE id=?').run(await ownerTag(guestB), guestConnection);
  await assert.rejects(connection(guestConnection, env, guestB), { code: 'invalid_connection' });
  const stored = env.DB.raw.prepare('SELECT owner FROM connections').all().map(row => row.owner);
  assert.ok(stored.every(tag => /^[a-f0-9]{64}$/.test(tag)) && !stored.some(tag => [owner, guestA, guestB].includes(tag)),
    'The table stores digests, never the users\' IDs');
});

test('connections saved before invited users existed still belong to the owner', async () => {
  const env = environment();
  const legacy = crypto.randomUUID();
  env.DB.raw.prepare('INSERT INTO connections(id,mode,encrypted_data,created_at,expires_at) VALUES (?,?,?,?,?)')
    .run(legacy, 'production', await seal(fictitious('Banco previo'), `connection:${legacy}`, env), Date.now(), Math.floor(Date.now() / 1000) + 86400);
  assert.deepEqual((await listConnections(env, false, owner)).map(c => c.bank), ['Banco previo'], 'No reconnection needed');
  assert.deepEqual(await listConnections(env, false, guestA), []);
  await assert.rejects(connection(legacy, env, guestA), { code: 'connection_not_found' });
});

test('a bank authorization returns to the person who started it', async () => {
  const env = environment();
  const pending = await newAuthorization('Banco invitado A', env, guestA);
  const claimed = await claimAuthorization(pending.state, env);
  assert.equal(claimed.owner, guestA);
  assert.equal(claimed.bank, 'Banco invitado A');
  await assert.rejects(claimAuthorization(pending.state, env), { code: 'invalid_authorization' }, 'Used only once');
});

test('rate limits are counted separately for each user', async () => {
  const env = environment();
  for (let i = 0; i < 3; i++) await rateLimit(env, `user:${(await ownerTag(guestA)).slice(0, 32)}`, 3);
  await assert.rejects(rateLimit(env, `user:${(await ownerTag(guestA)).slice(0, 32)}`, 3), { code: 'rate_limited' });
  await rateLimit(env, `user:${(await ownerTag(guestB)).slice(0, 32)}`, 3);
});

test('sandbox keeps one shared space with no Supabase identity, including connections saved before', async () => {
  const env = { PROVIDER_MODE: 'sandbox', PUBLIC_ORIGIN: 'https://bank-test.sandbox.workers.dev',
    DATA_ENCRYPTION_KEY: randomBytes(32).toString('base64'), DB: database() };
  const legacy = crypto.randomUUID();
  env.DB.raw.prepare('INSERT INTO connections(id,mode,encrypted_data,created_at,expires_at) VALUES (?,?,?,?,?)')
    .run(legacy, 'sandbox', await seal(fictitious('Banco de prueba previo'), `connection:${legacy}`, env), Date.now(), Math.floor(Date.now() / 1000) + 86400);
  const fresh = crypto.randomUUID();
  await saveConnection(fresh, fictitious('Banco de prueba'), env);
  assert.equal(env.DB.raw.prepare('SELECT owner FROM connections WHERE id=?').get(fresh).owner, null);
  assert.deepEqual((await listConnections(env)).map(c => c.bank).sort(), ['Banco de prueba', 'Banco de prueba previo']);
  assert.equal((await connection(legacy, env)).sessionID, 'session-Banco de prueba previo');
  const pending = await newAuthorization('Banco de prueba', env);
  assert.equal((await claimAuthorization(pending.state, env)).bank, 'Banco de prueba');
});

test('invited people use the pilot application; the owner keeps the personal one; nobody falls back', async () => {
  const { providerEnvironment } = await import('../src/security.mjs');
  const { verifySandbox } = await import('../src/provider.mjs');
  const { generateKeyPairSync } = await import('node:crypto');
  const pem = () => generateKeyPairSync('rsa', { modulusLength: 4096 }).privateKey.export({ type: 'pkcs8', format: 'pem' });
  const personalApp = crypto.randomUUID(), pilotApp = crypto.randomUUID();
  const env = { ...environment(), ENABLE_APP_ID: personalApp, ENABLE_PRIVATE_KEY: pem() };
  assert.equal(providerEnvironment(env, owner), env, 'The owner keeps the personal application');
  assert.throws(() => providerEnvironment(env, guestA), { code: 'guest_banking_not_configured' }, 'No silent fallback to the owner application');
  const configured = { ...env, ENABLE_GUEST_APP_ID: pilotApp, ENABLE_GUEST_PRIVATE_KEY: pem() };
  const guest = providerEnvironment(configured, guestA.toUpperCase());
  assert.equal(guest.ENABLE_APP_ID, pilotApp);
  assert.equal(guest.ENABLE_PRIVATE_KEY, configured.ENABLE_GUEST_PRIVATE_KEY);
  assert.equal(guest.DB, configured.DB, 'Same database: connections stay separated by user');
  assert.equal(providerEnvironment(configured, owner).ENABLE_APP_ID, personalApp);
  assert.throws(() => providerEnvironment(configured, stranger), { code: 'owner_required' });
  assert.throws(() => providerEnvironment({ ...configured, ENABLE_GUEST_APP_ID: personalApp }, guestA), { code: 'guest_banking_not_configured' },
    'The pilot must be a different application');
  const sandbox = { PROVIDER_MODE: 'sandbox', ENABLE_APP_ID: personalApp };
  assert.equal(providerEnvironment(sandbox, undefined), sandbox);

  // Each request is signed with the application of the person who makes it.
  const kid = options => JSON.parse(Buffer.from(options.headers.Authorization.split(' ')[1].split('.')[0], 'base64url').toString()).kid;
  const application = (app, active) => async (url, options) => {
    assert.equal(kid(options), app.kid, 'Signed with this application');
    return Response.json({ environment: 'PRODUCTION', kid: app.kid, active, services: ['AIS'],
      redirect_urls: [`${configured.PUBLIC_ORIGIN}/v1/callback`] });
  };
  await verifySandbox(guest, application({ kid: pilotApp }, true));
  await verifySandbox(providerEnvironment(configured, owner), application({ kid: personalApp }, true));
  await assert.rejects(verifySandbox(guest, application({ kid: pilotApp }, false)), { code: 'guest_application_inactive' },
    'Until its first accounts are linked, guests are told so');
  await assert.rejects(verifySandbox(providerEnvironment(configured, owner), application({ kid: personalApp }, false)),
    { code: 'production_configuration_required' }, 'The owner keeps the usual message');
});

test('guest list and pilot credentials tools validate before touching the configuration', async () => {
  const { updateGuests } = await import('../tools/guests.mjs');
  const { pilotSecrets } = await import('../tools/pilot-app.mjs');
  const { generateKeyPairSync } = await import('node:crypto');
  assert.equal(updateGuests('', 'add', guestA.toUpperCase(), owner), guestA);
  assert.equal(updateGuests(guestA, 'add', guestA, owner), guestA, 'Adding twice keeps one entry');
  assert.equal(updateGuests(`${guestA},${guestB}`, 'remove', guestA, owner), guestB);
  assert.throws(() => updateGuests('', 'add', 'no-es-un-id', owner), /no es válido/);
  assert.throws(() => updateGuests('', 'add', owner, owner), /propio usuario/);
  assert.throws(() => updateGuests(guestA, 'remove', guestB, owner), /no está en la lista/);
  assert.equal(mode(environment(updateGuests(guestA, 'add', guestB, owner))), 'production', 'The result is a valid server list');

  const pem = generateKeyPairSync('rsa', { modulusLength: 4096 }).privateKey.export({ type: 'pkcs8', format: 'pem' });
  const pilot = crypto.randomUUID(), personal = crypto.randomUUID();
  const secrets = pilotSecrets({ appID: pilot.toUpperCase(), pem, personalAppID: personal });
  assert.deepEqual(Object.keys(secrets).sort(), ['ENABLE_GUEST_APP_ID', 'ENABLE_GUEST_PRIVATE_KEY']);
  assert.equal(secrets.ENABLE_GUEST_APP_ID, pilot);
  assert.throws(() => pilotSecrets({ appID: personal, pem, personalAppID: personal }), /aplicación personal/);
  assert.throws(() => pilotSecrets({ appID: pilot, pem: 'no es una clave' }), error => !error.message.includes('no es una clave'));
  const small = generateKeyPairSync('rsa', { modulusLength: 2048 }).privateKey.export({ type: 'pkcs8', format: 'pem' });
  assert.throws(() => pilotSecrets({ appID: pilot, pem: small }), /4096/);
});
