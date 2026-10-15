import { Fault, mode, origin, now, base64url, limitedBytes, sha256 } from './security.mjs';
import { Buffer } from 'node:buffer';

const API = 'https://api.enablebanking.com';
const BANKS = ['Bankinter', 'BBVA', 'Trade Republic'];
let cachedJWT;
export function demoBanks() { return BANKS.map(name => ({ name, country: 'ES', beta: name === 'Trade Republic', maximumConsentValidity: 86400 })); }

export async function providerJWT(env) {
  if (!/^[a-f0-9-]{36}$/i.test(env.ENABLE_APP_ID ?? '') || !env.ENABLE_PRIVATE_KEY) throw new Fault(503, 'not_configured');
  const keyID = await sha256(`${env.ENABLE_APP_ID}:${env.ENABLE_PRIVATE_KEY}`);
  if (cachedJWT?.keyID === keyID && cachedJWT.expiresAt > now() + 30) return cachedJWT.value;
  let privateKey;
  try {
    const key = env.ENABLE_PRIVATE_KEY.replaceAll('\\n', '\n');
    if (!key.startsWith('-----BEGIN PRIVATE KEY-----')) throw new Error();
    const der = Buffer.from(key.replace(/-----[^-]+-----|\s/g, ''), 'base64');
    privateKey = await crypto.subtle.importKey('pkcs8', der, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign']);
    if (privateKey.algorithm.modulusLength < 4096) throw new Error();
  } catch { throw new Fault(503, 'invalid_signing_key'); }
  const encoded = v => base64url(new TextEncoder().encode(JSON.stringify(v)));
  const expiresAt = now() + 300;
  const payload = `${encoded({ typ: 'JWT', alg: 'RS256', kid: env.ENABLE_APP_ID })}.${encoded({ iss: 'enablebanking.com', aud: 'api.enablebanking.com', iat: now(), exp: expiresAt })}`;
  const signature = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', privateKey, new TextEncoder().encode(payload));
  const value = `${payload}.${base64url(signature)}`;
  cachedJWT = { keyID, expiresAt, value };
  return value;
}
async function api(path, env, options = {}, transport = fetch) {
  // Only constant API paths built here reach this function; redirects never receive the JWT.
  if (!path.startsWith('/') || path.startsWith('//')) throw new Fault(500, 'invalid_route');
  const response = await transport(`${API}${path}`, {
    ...options, redirect: 'manual', signal: AbortSignal.timeout(20_000),
    headers: { 'Authorization': `Bearer ${await providerJWT(env)}`, 'Accept': 'application/json',
      ...(options.body ? { 'Content-Type': 'application/json' } : {}) }
  });
  if (options.method === 'DELETE' && [404, 410].includes(response.status)) { await response.body?.cancel(); return {}; }
  if (!response.ok) { await response.body?.cancel(); throw new Fault(response.status === 429 ? 429 : 502, 'bank_unavailable'); }
  if (options.method === 'DELETE') { await response.body?.cancel(); return {}; }
  const bytes = await limitedBytes(response, 2_000_000);
  try { return JSON.parse(new TextDecoder().decode(bytes)); } catch { throw new Fault(502, 'invalid_provider_data'); }
}
export async function verifySandbox(env, transport = fetch) {
  if (mode(env) === 'demo') return;
  const app = await api('/application', env, {}, transport);
  if (app.environment !== 'SANDBOX' || app.kid !== env.ENABLE_APP_ID || app.active !== true
      || !app.services?.includes('AIS') || !app.redirect_urls?.includes(`${origin(env)}/v1/callback`)) {
    throw new Fault(503, 'sandbox_configuration_required');
  }
}
export async function banks(env) {
  if (mode(env) === 'demo') return demoBanks();
  await verifySandbox(env);
  const data = await api('/aspsps?country=ES', env);
  if (!Array.isArray(data.aspsps)) throw new Fault(502, 'invalid_provider_data');
  return data.aspsps.filter(b => b.country === 'ES' && BANKS.includes(b.name) && b.psu_types?.includes('personal'))
    .map(b => ({ name: b.name, country: b.country, beta: b.beta === true, maximumConsentValidity: b.maximum_consent_validity }));
}
export async function startAuthorization(bank, state, env) {
  if (mode(env) === 'demo') return `${origin(env)}/demo/consent?state=${encodeURIComponent(state)}`;
  const available = await banks(env);
  const selected = available.find(b => b.name === bank);
  if (!selected) throw new Fault(400, 'unsupported_bank');
  const duration = Math.min(86400, selected.maximumConsentValidity);
  if (!(duration > 0)) throw new Fault(502, 'invalid_provider_data');
  const response = await api('/auth', env, { method: 'POST', body: JSON.stringify({
    access: { valid_until: new Date((now() + duration) * 1000).toISOString() },
    aspsp: { name: bank, country: 'ES' }, state, redirect_url: `${origin(env)}/v1/callback`, psu_type: 'personal'
  }) });
  let url;
  try { url = new URL(response.url); } catch { throw new Fault(502, 'invalid_provider_data'); }
  if (url.protocol !== 'https:' || url.hostname !== 'auth.enablebanking.com' || url.username || url.password || url.port) {
    throw new Fault(502, 'invalid_provider_data');
  }
  return url.href;
}
export async function exchange(code, bank, env) {
  await verifySandbox(env);
  const data = await api('/sessions', env, { method: 'POST', body: JSON.stringify({ code }) });
  if (!Array.isArray(data.accounts) || data.accounts.length > 30
      || !/^[a-f0-9-]{36}$/i.test(data.session_id ?? '') || !data.access?.valid_until
      || data.aspsp?.name !== bank || data.aspsp?.country !== 'ES' || data.psu_type !== 'personal') throw new Fault(502, 'invalid_provider_data');
  const accounts = await Promise.all(data.accounts.map(async (account, index) => ({
    id: await sha256(`${data.session_id}:${account.uid}`), uid: account.uid,
    // Do not persist account-holder names or a full IBAN embedded in the bank's account label.
    name: `Cuenta de prueba ${index + 1}`, currency: account.currency,
    lastFour: String(account.account_id?.iban ?? '').replace(/\s/g, '').slice(-4)
  })));
  if (accounts.length > 30 || accounts.some(a => !/^[a-f0-9-]{36}$/i.test(a.uid ?? '') || !/^[A-Z]{3}$/.test(a.currency ?? ''))) throw new Fault(502, 'invalid_provider_data');
  return { bank, sessionID: data.session_id, validUntil: data.access.valid_until, accounts };
}
export function demoConnection(bank) {
  return { bank, sessionID: 'fictitious-session', validUntil: new Date((now() + 86400) * 1000).toISOString(),
    accounts: [{ id: 'demo-cash', uid: 'fictitious-account', name: 'Efectivo de prueba', currency: 'EUR', lastFour: '0000' }] };
}
export function amountMinor(value) {
  if (typeof value !== 'string' || !/^-?\d{1,14}(\.\d{1,2})?$/.test(value)) throw new Fault(502, 'invalid_provider_data');
  const negative = value.startsWith('-');
  const [units, fraction = ''] = value.replace('-', '').split('.');
  const number = Number(BigInt(units) * 100n + BigInt(fraction.padEnd(2, '0')));
  if (!Number.isSafeInteger(number)) throw new Fault(502, 'invalid_provider_data');
  return negative ? -number : number;
}
export async function normalizeTransaction(t, account) {
  if (t.status !== 'BOOK') return null;
  const amount = amountMinor(t.transaction_amount?.amount);
  if (amount < 0 || !['CRDT', 'DBIT'].includes(t.credit_debit_indicator)
      || t.transaction_amount?.currency !== account.currency
      || !/^\d{4}-\d{2}-\d{2}$/.test(t.booking_date ?? '') || !Number.isFinite(Date.parse(t.booking_date))
      || new Date(t.booking_date).toISOString().slice(0, 10) !== t.booking_date) throw new Fault(502, 'invalid_provider_data');
  const description = (Array.isArray(t.remittance_information) ? t.remittance_information : []).filter(s => typeof s === 'string').join(' ').slice(0, 500)
    || String(t.creditor?.name ?? t.debtor?.name ?? 'Movimiento bancario').slice(0, 500);
  const reference = t.entry_reference || t.transaction_id;
  return { id: reference ? await sha256(`${account.id}:${reference}`) : null,
    bookingDate: t.booking_date, signedAmountMinor: t.credit_debit_indicator === 'DBIT' ? -amount : amount,
    currency: account.currency, description };
}
export async function accountData(conn, account, from, to, continuation, env) {
  if (mode(env) === 'demo') return {
    balances: [{ amountMinor: 123456, currency: 'EUR', type: 'CLBD' }],
    transactions: [
      { id: 'demo-income', bookingDate: to, signedAmountMinor: 150000, currency: 'EUR', description: 'Nómina ficticia' },
      { id: 'demo-expense', bookingDate: to, signedAmountMinor: -26544, currency: 'EUR', description: 'Compra ficticia' }
    ], continuation: null
  };
  await verifySandbox(env);
  const path = `/accounts/${encodeURIComponent(account.uid)}`;
  const query = new URLSearchParams({ date_from: from, date_to: to, transaction_status: 'BOOK' });
  if (continuation) query.set('continuation_key', continuation);
  const transactionResponse = await api(`${path}/transactions?${query}`, env);
  if (!Array.isArray(transactionResponse.transactions)) throw new Fault(502, 'invalid_provider_data');
  const transactions = (await Promise.all(transactionResponse.transactions.map(t => normalizeTransaction(t, account)))).filter(Boolean);
  const balanceResponse = continuation ? { balances: [] } : await api(`${path}/balances`, env);
  if (!Array.isArray(balanceResponse.balances)) throw new Fault(502, 'invalid_provider_data');
  const balances = balanceResponse.balances.filter(b => b.balance_amount?.currency === account.currency)
    .map(b => ({ amountMinor: amountMinor(b.balance_amount.amount), currency: b.balance_amount.currency, type: b.balance_type }));
  return { balances, transactions, continuation: transactionResponse.continuation_key || null };
}
export async function revoke(conn, env) {
  if (mode(env) === 'demo') return;
  await verifySandbox(env);
  if (!/^[a-f0-9-]{36}$/i.test(conn.sessionID)) throw new Fault(503, 'invalid_connection');
  await api(`/sessions/${encodeURIComponent(conn.sessionID)}`, env, { method: 'DELETE' });
}
