import { Fault, now, randomID, seal, unseal, sha256, isState } from './security.mjs';
import { Buffer } from 'node:buffer';

export async function rateLimit(env, scope, limit = 60) {
  const time = now();
  const bucket = `${scope}:${Math.floor(time / 60)}`;
  const result = await env.DB.prepare(`INSERT INTO rate_limits(bucket,count,expires_at) VALUES (?,1,?)
    ON CONFLICT(bucket) DO UPDATE SET count=count+1 WHERE count < ? RETURNING count`)
    .bind(bucket, time + 120, limit).first();
  if (!result) throw new Fault(429, 'rate_limited');
  await env.DB.batch([
    env.DB.prepare('DELETE FROM rate_limits WHERE expires_at < ?').bind(time),
    env.DB.prepare('DELETE FROM auth_requests WHERE expires_at < ?').bind(time),
    env.DB.prepare('DELETE FROM connections WHERE expires_at < ?').bind(time)
  ]);
}
export async function newAuthorization(bank, env) {
  const state = Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString('base64url');
  const id = randomID(); const expiresAt = now() + 600;
  await env.DB.prepare('INSERT INTO auth_requests(id,state_hash,encrypted_data,expires_at) VALUES (?,?,?,?)')
    .bind(id, await sha256(state), await seal({ bank, owner: env.SUPABASE_OWNER_ID }, `auth:${id}`, env), expiresAt).run();
  return { id, state };
}
export async function claimAuthorization(state, env) {
  if (!isState(state)) throw new Fault(400, 'invalid_authorization');
  // Atomic compare-and-set: concurrent callbacks cannot exchange the same code twice.
  const row = await env.DB.prepare(`UPDATE auth_requests SET claimed=1
    WHERE state_hash=? AND claimed=0 AND expires_at>=? RETURNING id,encrypted_data`)
    .bind(await sha256(state), now()).first();
  if (!row) throw new Fault(400, 'invalid_authorization');
  return { id: row.id, ...await unseal(row.encrypted_data, `auth:${row.id}`, env) };
}
export async function assertPendingAuthorization(state, env) {
  if (!isState(state)) throw new Fault(400, 'invalid_authorization');
  // Viewing the form must not consume it; submitting still uses the atomic claim.
  const row = await env.DB.prepare('SELECT 1 AS pending FROM auth_requests WHERE state_hash=? AND claimed=0 AND expires_at>=?')
    .bind(await sha256(state), now()).first();
  if (!row) throw new Fault(400, 'invalid_authorization');
}
export async function saveConnection(id, value, env) {
  const expiresAt = Math.floor(Date.parse(value.validUntil) / 1000);
  if (!Number.isSafeInteger(expiresAt) || expiresAt <= now()) throw new Fault(502, 'invalid_provider_data');
  await env.DB.prepare('INSERT INTO connections(id,mode,encrypted_data,created_at,expires_at) VALUES (?,?,?,?,?)')
    .bind(id, env.PROVIDER_MODE, await seal(value, `connection:${id}`, env), Date.now(), expiresAt).run();
}
export async function connection(id, env) {
  const row = await env.DB.prepare('SELECT * FROM connections WHERE id=? AND mode=? AND expires_at>?')
    .bind(id, env.PROVIDER_MODE, now()).first();
  if (!row) throw new Fault(404, 'connection_not_found');
  return { id, ...await unseal(row.encrypted_data, `connection:${id}`, env) };
}
export async function listConnections(env, includeSuperseded = false) {
  const { results } = await env.DB.prepare('SELECT id FROM connections WHERE mode=? AND expires_at>? ORDER BY created_at DESC')
    .bind(env.PROVIDER_MODE, now()).all();
  const connections = await Promise.all(results.map(row => connection(row.id, env)));
  if (env.PROVIDER_MODE !== 'production' || includeSuperseded) return connections;
  const seen = new Set();
  // A renewed consent has new provider UIDs but the same stable account IDs.
  // Prefer the newest session rather than importing two copies of one account.
  return connections.map(conn => ({ ...conn, accounts: conn.accounts.filter(account => {
    if (seen.has(account.id)) return false;
    seen.add(account.id); return true;
  }) })).filter(conn => conn.accounts.length > 0);
}
