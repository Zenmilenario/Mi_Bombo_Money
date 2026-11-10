import { Fault, mode, origin, now, base64url, limitedBytes, sha256, accountIdentity } from './security.mjs';
import { Buffer } from 'node:buffer';
import { SCENARIO_ID, scenarioRole } from './sandbox-scenario.mjs';

const API = 'https://api.enablebanking.com';
const BANKS = ['Bankinter', 'BBVA', 'Trade Republic'];
let cachedJWT;
// Never forward the provider's free-text message/detail: these may contain account data.
const providerErrors = new Map([
  ['EXPIRED_SESSION', 'bank_session_expired'], ['REVOKED_SESSION', 'bank_session_expired'],
  ['CLOSED_SESSION', 'bank_session_expired'], ['SESSION_DOES_NOT_EXIST', 'bank_session_expired'],
  ['ASPSP_PSU_ACTION_REQUIRED', 'bank_action_required'],
  ['ASPSP_RATE_LIMIT_EXCEEDED', 'bank_rate_limited'], ['ASPSP_TIMEOUT', 'bank_timeout'],
  ['PSU_HEADER_NOT_PROVIDED', 'bank_psu_headers_required'], ['PSU_HEADER_INVALID', 'bank_psu_headers_required'],
  ['ASPSP_ACCOUNT_NOT_ACCESSIBLE', 'bank_account_unavailable'], ['ACCOUNT_DOES_NOT_EXIST', 'bank_account_unavailable'],
  ['WRONG_TRANSACTIONS_PERIOD', 'bank_history_unavailable'],
  ['WRONG_REQUEST_PARAMETERS', 'bank_request_rejected'], ['WRONG_CONTINUATION_KEY', 'bank_request_rejected'],
  ['ACCESS_DENIED', 'provider_access_denied'], ['UNAUTHORIZED_ACCESS', 'provider_access_denied'],
  ['UNAUTHORIZED_IP', 'provider_access_denied'], ['AUTHORIZATION_NOT_PROVIDED', 'provider_access_denied'],
  ['ASPSP_ERROR', 'bank_unavailable']
]);

async function providerFailure(response, path) {
  let providerCode = 'UNKNOWN';
  try {
    const body = JSON.parse(new TextDecoder().decode(await limitedBytes(response, 16_384)));
    if (providerErrors.has(body?.error)) providerCode = body.error;
  } catch { await response.body?.cancel().catch(() => {}); }
  const operation = /\/transactions(?:\?|$)/.test(path) ? 'transactions'
    : /\/balances$/.test(path) ? 'balances' : path === '/application' ? 'application'
    : path.startsWith('/aspsps?') ? 'catalogue' : path === '/auth' ? 'authorization' : 'session';
  // Fixed categories only, with no URL, bank/account/session ID, body or exception.
  console.warn(JSON.stringify({ event: 'banking_provider_failure', operation,
    status: response.status, code: providerCode }));
  const code = response.status === 429 ? 'bank_rate_limited' : providerErrors.get(providerCode) ?? 'bank_unavailable';
  const failure = new Fault(code === 'bank_rate_limited' ? 429 : 502, code);
  if (code === 'bank_rate_limited') {
    const retry = response.headers.get('Retry-After');
    const seconds = /^\d{1,8}$/.test(retry ?? '') ? Number(retry)
      : retry ? Math.ceil((Date.parse(retry) - Date.now()) / 1000) : NaN;
    failure.retryAfter = Number.isFinite(seconds) ? Math.max(60, Math.min(604800, seconds)) : 21600;
  }
  return failure;
}
export function demoBanks() { return BANKS.map(name => ({ name, country: 'ES', beta: name === 'Trade Republic', maximumConsentValidity: 86400 })); }
export function acceptsBankName(name, env) {
  return mode(env) === 'demo' ? BANKS.includes(name)
    : typeof name === 'string' && name.length > 0 && name.length <= 200 && !/[\x00-\x1f]/.test(name);
}

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
    headers: { ...options.headers, 'Authorization': `Bearer ${await providerJWT(env)}`, 'Accept': 'application/json',
      ...(options.body ? { 'Content-Type': 'application/json' } : {}) }
  });
  if (options.method === 'DELETE' && [404, 410].includes(response.status)) { await response.body?.cancel(); return {}; }
  if (!response.ok) throw await providerFailure(response, path);
  if (options.method === 'DELETE') { await response.body?.cancel(); return {}; }
  const bytes = await limitedBytes(response, 2_000_000);
  try { return JSON.parse(new TextDecoder().decode(bytes)); }
  catch {
    if (path.includes('/transactions?')) throw invalidFeed('transactions', 'json');
    if (path.endsWith('/balances')) throw invalidFeed('balances', 'json');
    throw new Fault(502, 'invalid_provider_data');
  }
}

function invalidFeed(operation, field) {
  // Only call with fixed diagnostic labels, never with fields supplied by a bank.
  const fault = new Fault(502, 'invalid_provider_data');
  fault.feedValidation = { operation, field };
  return fault;
}
export async function verifySandbox(env, transport = fetch) {
  if (mode(env) === 'demo') return;
  const app = await api('/application', env, {}, transport);
  const production = mode(env) === 'production';
  // The pilot application is inactive until its first accounts are linked in the control panel:
  // invited people get their own message instead of a configuration error.
  if (env.GUEST_APPLICATION && app.kid === env.ENABLE_APP_ID && app.environment === 'PRODUCTION' && app.active !== true) {
    throw new Fault(503, 'guest_application_inactive');
  }
  if (app.environment !== (production ? 'PRODUCTION' : 'SANDBOX') || app.kid !== env.ENABLE_APP_ID || app.active !== true
      || (production && app.services?.length !== 1)
      || !app.services?.includes('AIS') || !app.redirect_urls?.includes(`${origin(env)}/v1/callback`)) {
    throw new Fault(503, production ? 'production_configuration_required' : 'sandbox_configuration_required');
  }
}
export async function banks(env, transport = fetch) {
  if (mode(env) === 'demo') return demoBanks();
  await verifySandbox(env, transport);
  const data = await api('/aspsps?country=ES', env, {}, transport);
  if (!Array.isArray(data.aspsps)) throw new Fault(502, 'invalid_provider_data');
  return data.aspsps.filter(b => b.country === 'ES' && acceptsBankName(b.name, env) && b.psu_types?.includes('personal'))
    .map(b => ({ name: b.name, country: b.country, beta: b.beta === true, maximumConsentValidity: b.maximum_consent_validity }))
    .filter((bank, index, all) => all.findIndex(b => b.name === bank.name) === index)
    .sort((a, b) => a.name.localeCompare(b.name, 'es'));
}
export async function startAuthorization(bank, state, env) {
  if (mode(env) === 'demo') return `${origin(env)}/demo/consent?state=${encodeURIComponent(state)}`;
  const available = await banks(env);
  const selected = available.find(b => b.name === bank);
  if (!selected) throw new Fault(400, 'unsupported_bank');
  const duration = Math.min(mode(env) === 'production' ? 180 * 86400 : 86400, selected.maximumConsentValidity);
  if (!(duration > 0)) throw new Fault(502, 'invalid_provider_data');
  const response = await api('/auth', env, { method: 'POST', body: JSON.stringify({
    access: { valid_until: new Date((now() + duration) * 1000).toISOString() },
    aspsp: { name: bank, country: 'ES' }, state, redirect_url: `${origin(env)}/v1/callback`, psu_type: 'personal'
  }) });
  let url;
  try { url = new URL(response.url); } catch { throw new Fault(502, 'invalid_provider_data'); }
  // Enable Banking is migrating production authorizations between these two exact origins.
  const allowedHosts = mode(env) === 'production' ? ['auth.enablebanking.com', 'tilisy.enablebanking.com'] : ['auth.enablebanking.com', 'tilisy-sandbox.enablebanking.com'];
  if (url.protocol !== 'https:' || !allowedHosts.includes(url.hostname)
      || url.username || url.password || url.port) {
    throw new Fault(502, 'authorization_destination_rejected');
  }
  return url.href;
}
export async function exchange(code, bank, env, transport = fetch) {
  await verifySandbox(env, transport);
  const data = await api('/sessions', env, { method: 'POST', body: JSON.stringify({ code }) }, transport);
  try {
  if (!Array.isArray(data.accounts) || data.accounts.length > 30
      || !/^[a-f0-9-]{36}$/i.test(data.session_id ?? '') || !data.access?.valid_until
      || data.aspsp?.name !== bank || data.aspsp?.country !== 'ES' || data.psu_type !== 'personal') throw new Fault(502, 'invalid_provider_data');
  const accounts = await Promise.all(data.accounts.map(async (account, index) => {
    const iban = String(account.account_id?.iban ?? '').replace(/\s/g, '').toUpperCase();
    const live = mode(env) === 'production';
    // No session-derived identity in production: renewal must not create a second account.
    if (live && !/^[A-Z]{2}\d{2}[A-Z0-9]{11,30}$/.test(iban)) throw new Fault(502, 'stable_account_identity_required');
    const testRole = live ? undefined : scenarioRole(bank, iban);
    return {
      // Only this named synthetic fixture keeps its identity through renewed consents.
      id: live ? await accountIdentity(`${bank}:${iban}`, env)
        : await sha256(testRole ? `${SCENARIO_ID}:${testRole}` : `${data.session_id}:${account.uid}`), uid: account.uid,
      name: live ? `Cuenta •••• ${iban.slice(-4)}` : `Cuenta de prueba ${index + 1}`, currency: account.currency,
      lastFour: iban.slice(-4), ownershipKey: iban ? await accountIdentity(iban, env) : undefined, testRole
    };
  }));
  if (accounts.length > 30 || accounts.some(a => !/^[a-f0-9-]{36}$/i.test(a.uid ?? '') || !/^[A-Z]{3}$/.test(a.currency ?? ''))) throw new Fault(502, 'invalid_provider_data');
  // A restricted application only returns accounts linked in its control panel. A session without any
  // is not stored (the provider session is revoked below) instead of leaving an empty bank behind.
  if (mode(env) === 'production' && accounts.length === 0) throw new Fault(409, 'no_linked_accounts');
  const testScenario = accounts.length === 3 && new Set(accounts.map(a => a.testRole).filter(Boolean)).size === 3 ? SCENARIO_ID : undefined;
  return { bank, sessionID: data.session_id, validUntil: data.access.valid_until, accounts, testScenario };
  } catch (error) {
    // A valid provider session must not be orphaned if validation or persistence fails.
    if (/^[a-f0-9-]{36}$/i.test(data.session_id ?? '')) {
      try { await api(`/sessions/${encodeURIComponent(data.session_id)}`, env, { method: 'DELETE' }, transport); }
      catch { /* Do not expose provider data through logs or error messages. */ }
    }
    throw error;
  }
}
export function demoConnection(bank) {
  return { bank, sessionID: 'fictitious-session', validUntil: new Date((now() + 86400) * 1000).toISOString(),
    accounts: [{ id: 'demo-cash', uid: 'fictitious-account', name: 'Efectivo de prueba', currency: 'EUR', lastFour: '0000' }] };
}
export function amountMinor(value, operation) {
  if (value == null) throw invalidFeed(operation, 'amount_missing');
  if (typeof value !== 'string') throw invalidFeed(operation, 'amount_type');
  if (!/^-?\d{1,14}(\.\d{1,18})?$/.test(value)) throw invalidFeed(operation, 'amount_format');
  const negative = value.startsWith('-');
  const [units, fraction = ''] = value.replace('-', '').split('.');
  if (/[1-9]/.test(fraction.slice(2))) throw invalidFeed(operation, 'amount_subcent');
  const number = Number(BigInt(units) * 100n + BigInt(fraction.slice(0, 2).padEnd(2, '0')));
  if (!Number.isSafeInteger(number)) throw invalidFeed(operation, 'amount_range');
  return negative ? -number : number;
}
function transactionDescription(t) {
  return (Array.isArray(t.remittance_information) ? t.remittance_information : []).filter(s => typeof s === 'string').join(' ').slice(0, 500)
    || String(t.creditor?.name ?? t.debtor?.name ?? 'Movimiento bancario').slice(0, 500);
}
function validTransactionDate(date) {
  return /^\d{4}-\d{2}-\d{2}$/.test(date ?? '') && Number.isFinite(Date.parse(date))
    && new Date(date).toISOString().slice(0, 10) === date;
}
export async function normalizeTransaction(t, account, env) {
  if (!t || typeof t !== 'object') throw invalidFeed('transactions', 'row');
  if (t.status !== 'BOOK') return null;
  const amount = amountMinor(t.transaction_amount?.amount, 'transactions');
  if (!['CRDT', 'DBIT'].includes(t.credit_debit_indicator)) throw invalidFeed('transactions', 'direction');
  const debit = t.credit_debit_indicator === 'DBIT';
  if (!debit && amount < 0) throw invalidFeed('transactions', 'amount_sign');
  if (t.transaction_amount?.currency !== account.currency) throw invalidFeed('transactions', 'currency');
  if (!validTransactionDate(t.booking_date)) throw invalidFeed('transactions', 'booking_date');
  const description = transactionDescription(t);
  const reference = t.entry_reference || t.transaction_id;
  const otherIBAN = (t.credit_debit_indicator === 'DBIT' ? t.creditor_account?.iban : t.debtor_account?.iban);
  const pairReference = t.end_to_end_id || t.reference_number;
  return { id: reference ? await sha256(`${account.id}:${reference}`) : null,
    bookingDate: t.booking_date, signedAmountMinor: debit ? -Math.abs(amount) : amount,
    currency: account.currency, description,
    counterpartyKey: typeof otherIBAN === 'string' ? (env ? await accountIdentity(otherIBAN.replace(/\s/g, '').toUpperCase(), env)
      : await sha256(otherIBAN.replace(/\s/g, '').toUpperCase())) : undefined,
    transferKey: typeof pairReference === 'string' && pairReference && pairReference !== 'NOTPROVIDED' ? await sha256(pairReference) : undefined };
}
async function pendingTransaction(t, account) {
  if (!['PDNG', 'HOLD'].includes(t?.status) || t.transaction_amount?.currency !== account.currency) return null;
  const debit = t.credit_debit_indicator === 'DBIT';
  if (!debit && t.credit_debit_indicator !== 'CRDT') return null;
  let amount;
  try { amount = amountMinor(t.transaction_amount.amount, 'transactions'); }
  catch (error) { if (error instanceof Fault) return null; throw error; }
  if (!debit && amount < 0) return null;
  // Only the provider's stable entry reference can identify the same pending and booked entry.
  const id = typeof t.entry_reference === 'string' && t.entry_reference ? await sha256(`${account.id}:${t.entry_reference}`) : null;
  return { id, date: [t.transaction_date, t.booking_date].find(validTransactionDate) ?? null,
    signedAmountMinor: debit ? -Math.abs(amount) : amount, currency: account.currency,
    description: transactionDescription(t), status: t.status };
}
export function countIgnoredStatuses(rows) {
  const counts = {};
  for (const row of rows) {
    const raw = typeof row?.status === 'string' ? row.status : '';
    if (['BOOK', 'PDNG', 'HOLD'].includes(raw)) continue;
    const status = raw === '' ? 'NONE' : (/^[A-Z]{2,8}$/.test(raw) ? raw : 'OTHER');
    counts[status] = (counts[status] ?? 0) + 1;
  }
  return counts;
}
export async function accountData(conn, account, from, to, continuation, env, transport = fetch, psu = {}, includePending = false) {
  if (mode(env) === 'demo') {
    // Fixtures belong to the connection's creation day, not to the query's end
    // date. Changing the date range must never invent another salary/purchase.
    const bookingDate = new Date(Date.parse(conn.validUntil) - 86400_000).toISOString().slice(0, 10);
    return {
      balances: [{ amountMinor: 123456, currency: 'EUR', type: 'CLBD' }],
      transactions: [
        { id: 'demo-income', bookingDate, signedAmountMinor: 150000, currency: 'EUR', description: 'Nómina ficticia' },
        { id: 'demo-expense', bookingDate, signedAmountMinor: -26544, currency: 'EUR', description: 'Compra ficticia' }
      ].filter(row => row.bookingDate >= from && row.bookingDate <= to), continuation: null
    };
  }
  await verifySandbox(env, transport);
  const path = `/accounts/${encodeURIComponent(account.uid)}`;
  const query = new URLSearchParams({ date_from: from, date_to: to });
  if (!includePending) query.set('transaction_status', 'BOOK');
  if (continuation) query.set('continuation_key', continuation);
  try {
    const transactionResponse = await api(`${path}/transactions?${query}`, env, { headers: psu }, transport);
    if (!Array.isArray(transactionResponse?.transactions)) throw invalidFeed('transactions', 'list');
    const transactions = (await Promise.all(transactionResponse.transactions.map(t => normalizeTransaction(t, account, env)))).filter(Boolean);
    const pendingTransactions = includePending
      ? (await Promise.all(transactionResponse.transactions.map(t => pendingTransaction(t, account)))).filter(Boolean)
      : undefined;
    // Entries with another status (cancelled, rejected, informative, none…) are not imported. Count them so the
    // app can say "the bank sent N entries with status X": only the status and a count, never the entry itself.
    const ignoredStatuses = includePending ? countIgnoredStatuses(transactionResponse.transactions) : undefined;
    if (ignoredStatuses && Object.keys(ignoredStatuses).length) {
      console.log(JSON.stringify({ event: 'banking_ignored_statuses', statuses: ignoredStatuses }));
    }
    const balanceResponse = continuation ? { balances: [] } : await api(`${path}/balances`, env, { headers: psu }, transport);
    if (!Array.isArray(balanceResponse?.balances)) throw invalidFeed('balances', 'list');
    const balances = balanceResponse.balances.filter(b => b?.balance_amount?.currency === account.currency).map(b => {
      const amount = amountMinor(b.balance_amount.amount, 'balances');
      if (typeof b.balance_type !== 'string') throw invalidFeed('balances', 'type');
      return { amountMinor: amount, currency: b.balance_amount.currency, type: b.balance_type };
    });
    return { balances, transactions, pendingTransactions, ignoredStatuses, continuation: transactionResponse.continuation_key || null };
  } catch (error) {
    if (error instanceof Fault && error.feedValidation) {
      console.warn(JSON.stringify({ event: 'banking_feed_validation', ...error.feedValidation }));
    }
    throw error;
  }
}
export async function revoke(conn, env) {
  if (mode(env) === 'demo') return;
  await verifySandbox(env);
  if (!/^[a-f0-9-]{36}$/i.test(conn.sessionID)) throw new Fault(503, 'invalid_connection');
  await api(`/sessions/${encodeURIComponent(conn.sessionID)}`, env, { method: 'DELETE' });
}
