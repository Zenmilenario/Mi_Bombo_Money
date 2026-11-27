// Evaluates Don Bigotes' interpreter with fictitious conversations (26 November 2026): the repository's prompt,
// schema and validation, run on Workers AI. The sentences are written as the app sends them (masked: amounts and the
// person's names are markers). It checks the capability chosen and its arguments, not how the answer sounds. Varied on
// purpose: long stories, colloquial and misspelled sentences, corrections, several things at once, new capabilities.
// Uses the free daily allocation (about 100 neurons a request, 24 requests). Nothing is stored.
//
//   .personal/cloudflare-ai.json: {"accountId": "...", "token": "..."} (a token with Workers AI permission; outside Git)
//   or the variables CLOUDFLARE_ACCOUNT_ID and CLOUDFLARE_API_TOKEN
//   node tools/evaluate-assistant.mjs [model]
import { existsSync, readFileSync } from 'node:fs';
import { messages, INTENT_SCHEMA, validateIntent, MODEL } from '../src/assistant.mjs';

const model = process.argv[2] ?? MODEL;
// From the environment, or from .personal/cloudflare-ai.json ({"accountId": "...", "token": "..."}, outside Git).
// Never printed.
let saved = {};
const file = new URL('../.personal/cloudflare-ai.json', import.meta.url);
if (existsSync(file)) {
  try { saved = JSON.parse(readFileSync(file, 'utf8')); } catch { console.error('.personal/cloudflare-ai.json no es un JSON válido.'); process.exit(2); }
}
const accountId = process.env.CLOUDFLARE_ACCOUNT_ID || saved.accountId, token = process.env.CLOUDFLARE_API_TOKEN || saved.token;
if (!accountId || !token) {
  console.error('Faltan el identificador de cuenta y el token (variables de entorno o .personal/cloudflare-ai.json).');
  process.exit(2);
}
async function interpret(context) {
  const started = Date.now();
  const res = await fetch(`https://api.cloudflare.com/client/v4/accounts/${accountId}/ai/run/${model}`, {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    signal: AbortSignal.timeout(60000),
    body: JSON.stringify({ messages: messages(context), response_format: { type: 'json_schema', json_schema: INTENT_SCHEMA }, max_tokens: 400, temperature: 0 })
  });
  const body = await res.json();
  const raw = body.result?.response ?? body.result;
  return { ms: Date.now() - started, intent: body.success ? validateIntent(raw) : null, raw, error: body.success ? null : JSON.stringify(body.errors) };
}

const base = {
  today: '2026-11-26',
  accounts: ['CUENTA_1: corriente (nomina)', 'CUENTA_2: ahorro (ahorro)', 'TARJETA_1: tarjeta de CUENTA_1'],
  plans: ['PLAN_1: préstamo'],
  goals: ['OBJETIVO_1'],
};
const shown = ['MOV_1: gasto de [N1] el 2026-11-25 en CUENTA_1, sin categoría', 'MOV_2: gasto de [N2] el 2026-11-24 en CUENTA_1, categoría CATEGORIA_1'];
const cases = [
  // Stories and colloquial sentences
  ['Ayer pagué la cena, unos [N1], y me devolvieron [N2] de la entrada del cine', {}, { kind: 'expense', amount: 'N1', also: [{ kind: 'income' }] }],
  ['buah vaya día, fui a echar gasolina que estaba carísima, [N1] me costó llenar el depósito con la [CUENTA_1]', {}, { kind: 'expense', amount: 'N1', account: 'CUENTA_1' }],
  ['éramos [N1] y al final pagué yo toda la cena, [N2] en total', {}, { kind: 'expense', amount: 'N2' }],
  ['oye q me e dejado [N1] pavos en el super esta mañana', {}, { kind: 'expense', amount: 'N1' }],
  ['me acaban de ingresar la nómina, [N1]', {}, { kind: 'income', amount: 'N1' }],
  ['quiero guardar [N1] para las vacaciones, en la de ahorro', {}, { kind: 'reserve', amount: 'N1', account: 'CUENTA_2' }],
  // Answers and corrections with something open
  ['con la de nómina', { draft: 'el gasto de [N1] € (Cena) ; pregunta pendiente: ¿Con qué cuenta o tarjeta?' }, { kind: 'correction', account: 'CUENTA_1' }],
  ['uy no, fueron [N2]', { draft: 'el gasto de [N1] € (Cena) ; enseñado para confirmar' }, { kind: 'correction', amount: 'N2' }],
  ['el 5 de cada mes', { draft: 'Préstamo de [N1] € en total en [N2] cuotas ; pregunta pendiente: ¿Qué día del mes se paga cada cuota?' }, { kind: 'correction', dueDay: 5 }],
  ['déjalo, no lo apuntes', { draft: 'el gasto de [N1] € ; enseñado para confirmar' }, { kind: 'cancel' }],
  ['gracias crack', {}, { kind: 'courtesy' }],
  // Existing movements: what is on screen and by amount
  ['el segundo era de [N3], no de [N2]', { shown }, { kind: 'editMovement', target: 'MOV_2', amount: 'N3' }],
  ['el primero ponlo en [CATEGORIA_2]', { shown }, { kind: 'editMovement', target: 'MOV_1' }],
  ['borra el de [N1] de ayer, que está repetido', {}, { kind: 'deleteMovement', findAmount: 'N1', findDate: '2026-11-25' }],
  ['el ingreso de [N1] es el dinero del préstamo', {}, { kind: 'describeExisting', role: 'loanReceived' }],
  // Selections
  ['clasifícame los [N1] más recientes que siguen sin categoría', {}, { kind: 'categorize', uncategorized: true, limit: 'N1' }],
  ['no, solo [N2]', { lastQuery: 'poner categoría: Movimientos sin categoría de cualquier fecha (los 4 más recientes)' }, { kind: 'categorize', refine: true, limit: 'N2' }],
  ['y los ingresos?', { lastQuery: 'ver: Gastos este mes' }, { kind: 'listMovements', refine: true, scope: 'income' }],
  // The new capabilities
  ['pasa [N1] de la nómina a la de ahorro', {}, { kind: 'transfer', amount: 'N1', account: 'CUENTA_1', toAccount: 'CUENTA_2' }],
  ['ponme un tope de [N1] al mes en [CATEGORIA_1]', {}, { kind: 'setBudget', amount: 'N1', category: 'CATEGORIA_1' }],
  ['quiero juntar [N1] para irme a Japón el verano que viene', {}, { kind: 'createGoal', amount: 'N1' }],
  ['he apartado [N1] para lo del viaje', {}, { kind: 'addToGoal', amount: 'N1', goal: 'OBJETIVO_1' }],
  ['siempre que salga Mercadona mételo en súper', {}, { kind: 'createRule' }],
  ['mándale [N1] a mi hermano por el banco', {}, { kind: 'unsupported' }],
];

function check(got, want) {
  const misses = [];
  // Strict: steps or conditions that were not asked count as mistakes.
  if (!want.also && got?.also?.length) misses.push(`also no pedido (${got.also.map(s => s.kind).join(', ')})`);
  if (['listMovements', 'categorize', 'summary'].includes(want.kind)) {
    for (const k of ['account', 'category', 'period']) if (got?.[k] !== undefined && want[k] === undefined) misses.push(`${k} no pedido=${JSON.stringify(got[k])}`);
  }
  for (const [k, v] of Object.entries(want)) {
    if (k === 'also') {
      const steps = got?.also ?? [];
      v.forEach((w, i) => { if (steps[i]?.kind !== w.kind) misses.push(`also[${i}].kind=${steps[i]?.kind}`); });
    } else if (got?.[k] !== v) misses.push(`${k}=${JSON.stringify(got?.[k])}`);
  }
  return misses;
}

let ok = 0, total = 0;
const times = [];
for (const [sentence, extra, want] of cases) {
  total++;
  const out = await interpret({ sentence, ...base, ...extra });
  times.push(out.ms);
  const misses = out.intent ? check(out.intent, want) : ['sin respuesta válida: ' + (out.error ?? JSON.stringify(out.raw))];
  if (!misses.length) ok++;
  console.log(`${misses.length ? 'FALLA' : 'ok   '} ${out.ms}ms «${sentence}» → ${JSON.stringify(out.intent)}${misses.length ? '  · ' + misses.join(', ') : ''}`);
}
times.sort((a, b) => a - b);
console.log(`\n${model}: ${ok}/${total} correctas · mediana ${times[Math.floor(times.length / 2)]} ms · máx ${times.at(-1)} ms`);
process.exitCode = ok === total ? 0 : 1;
