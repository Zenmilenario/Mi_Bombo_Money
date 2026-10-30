import { timingSafeEqual } from 'node:crypto';
import { Buffer } from 'node:buffer';

const encoder = new TextEncoder();
export class Fault extends Error {
  constructor(status, code) { super(code); this.status = status; this.code = code; }
}
export const now = () => Math.floor(Date.now() / 1000);
export const randomID = () => crypto.randomUUID();
export const base64url = data => Buffer.from(data).toString('base64url');
export async function sha256(value) {
  return Buffer.from(await crypto.subtle.digest('SHA-256', encoder.encode(value))).toString('hex');
}
export async function authenticate(request, env, transport = fetch) {
  if (mode(env) === 'production') {
    const match = /^Bearer ([A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)$/.exec(request.headers.get('authorization') ?? '');
    if (!match || match[1].length > 8192) throw new Fault(401, 'unauthorized');
    // Verify with Auth, never trust a locally decoded JWT or a client-supplied user ID.
    const response = await transport(`${env.SUPABASE_URL}/auth/v1/user`, {
      headers: { Authorization: `Bearer ${match[1]}`, apikey: env.SUPABASE_PUBLISHABLE_KEY },
      redirect: 'manual', signal: AbortSignal.timeout(10_000)
    });
    if (!response.ok) {
      await response.body?.cancel();
      throw new Fault(response.status === 401 || response.status === 403 ? 401 : 503,
        response.status === 401 || response.status === 403 ? 'unauthorized' : 'identity_unavailable');
    }
    let user;
    try { user = JSON.parse(new TextDecoder().decode(await limitedBytes(response, 100_000))); }
    catch { throw new Fault(503, 'identity_unavailable'); }
    if (user.id !== env.SUPABASE_OWNER_ID || user.is_anonymous === true) throw new Fault(403, 'owner_required');
    return user.id;
  }
  const expected = env.ACCESS_TOKEN_SHA256;
  if (!/^[a-f0-9]{64}$/.test(expected ?? '')) throw new Fault(503, 'not_configured');
  const match = /^Bearer ([a-f0-9]{64})$/.exec(request.headers.get('authorization') ?? '');
  const actual = await sha256(match?.[1] ?? 'invalid');
  if (!timingSafeEqual(Buffer.from(expected, 'hex'), Buffer.from(actual, 'hex')) || !match) {
    throw new Fault(401, 'unauthorized');
  }
}
export function origin(env) {
  let url;
  try { url = new URL(env.PUBLIC_ORIGIN); } catch { throw new Fault(503, 'not_configured'); }
  if (url.protocol !== 'https:' || !/^[a-z0-9-]+\.[a-z0-9-]+\.workers\.dev$/.test(url.hostname)
      || url.port || url.username || url.password || url.pathname !== '/' || url.search || url.hash
      || /replace-me|your-subdomain/.test(url.hostname)) throw new Fault(503, 'not_configured');
  return url.origin;
}
export function mode(env) {
  if (env.PROVIDER_MODE === 'production') {
    // A separate deployment is mandatory: the sandbox token can never unlock real accounts.
    if (env.BANKING_AUTH !== 'supabase-owner'
        || env.SUPABASE_URL !== 'https://coeicjffmpclqowsqeys.supabase.co'
        || !/^sb_publishable_[A-Za-z0-9_-]+$/.test(env.SUPABASE_PUBLISHABLE_KEY ?? '')
        || !/^[a-f0-9-]{36}$/i.test(env.SUPABASE_OWNER_ID ?? '')
        || !/^[A-Za-z0-9+/]{43}=$/.test(env.ACCOUNT_IDENTITY_KEY ?? '')) throw new Fault(503, 'live_banking_disabled');
  } else if (!['demo', 'sandbox'].includes(env.PROVIDER_MODE)) throw new Fault(503, 'live_banking_disabled');
  return env.PROVIDER_MODE;
}
export async function accountIdentity(value, env) {
  if (mode(env) !== 'production') return sha256(value);
  const key = await crypto.subtle.importKey('raw', Buffer.from(env.ACCOUNT_IDENTITY_KEY, 'base64'),
    { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return Buffer.from(await crypto.subtle.sign('HMAC', key, encoder.encode(value))).toString('hex');
}
async function encryptionKey(env) {
  const raw = Buffer.from(env.DATA_ENCRYPTION_KEY ?? '', 'base64');
  if (raw.byteLength !== 32 || raw.toString('base64') !== env.DATA_ENCRYPTION_KEY) throw new Fault(503, 'not_configured');
  return crypto.subtle.importKey('raw', raw, 'AES-GCM', false, ['encrypt', 'decrypt']);
}
export async function seal(value, purpose, env) {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const bytes = await crypto.subtle.encrypt({ name: 'AES-GCM', iv, additionalData: encoder.encode(encryptionScope(purpose, env)) },
    await encryptionKey(env), encoder.encode(JSON.stringify(value)));
  return `${base64url(iv)}.${base64url(bytes)}`;
}
export async function unseal(value, purpose, env) {
  const [iv, data, extra] = value.split('.');
  if (!iv || !data || extra) throw new Fault(503, 'invalid_connection');
  try {
    const clear = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: Buffer.from(iv, 'base64url'),
      additionalData: encoder.encode(encryptionScope(purpose, env)) }, await encryptionKey(env), Buffer.from(data, 'base64url'));
    return JSON.parse(new TextDecoder().decode(clear));
  } catch { throw new Fault(503, 'invalid_connection'); }
}
function encryptionScope(purpose, env) {
  return mode(env) === 'production' ? `production:${env.SUPABASE_OWNER_ID}:${purpose}` : `${mode(env)}:${purpose}`;
}
export async function readJSON(request, allowedKeys) {
  if ((request.headers.get('content-type') ?? '').split(';')[0] !== 'application/json') throw new Fault(415, 'json_required');
  const bytes = await limitedBytes(request, 2048);
  let value;
  try { value = JSON.parse(new TextDecoder().decode(bytes)); } catch { throw new Fault(400, 'invalid_request'); }
  if (!value || Array.isArray(value) || typeof value !== 'object'
      || Object.keys(value).some(k => !allowedKeys.includes(k))) throw new Fault(400, 'invalid_request');
  return value;
}
export async function limitedBytes(response, limit) {
  if (Number(response.headers.get('content-length')) > limit) throw new Fault(413, 'payload_too_large');
  if (!response.body) return new Uint8Array();
  const reader = response.body.getReader();
  let length = 0; const chunks = [];
  try {
    while (true) {
      const { done, value } = await reader.read(); if (done) break;
      length += value.length;
      if (length > limit) { await reader.cancel(); throw new Fault(413, 'payload_too_large'); }
      chunks.push(value);
    }
  } finally { reader.releaseLock(); }
  const bytes = new Uint8Array(length); let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  return bytes;
}
export const UUID = /^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/;
export const isState = value => /^[A-Za-z0-9_-]{43}$/.test(value ?? '');
export function securityHeaders(extra = {}) {
  return {
    'Cache-Control': 'no-store, private, max-age=0', 'Pragma': 'no-cache',
    'Referrer-Policy': 'no-referrer', 'X-Content-Type-Options': 'nosniff',
    'Strict-Transport-Security': 'max-age=31536000; includeSubDomains',
    'Content-Security-Policy': "default-src 'none'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'",
    'X-Frame-Options': 'DENY', 'Permissions-Policy': 'camera=(), microphone=(), geolocation=()', ...extra
  };
}
export function json(value, status = 200) {
  return new Response(JSON.stringify(value), { status, headers: securityHeaders({ 'Content-Type': 'application/json; charset=utf-8' }) });
}
