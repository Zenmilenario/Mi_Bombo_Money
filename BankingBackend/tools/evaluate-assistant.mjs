// Evaluates Don Bigotes' interpreter with fictitious conversations (26 November 2026): the repository's prompt,
// schema and validation, run on Workers AI. It checks the capability chosen and its arguments, not how it sounds.
// Uses the free daily allocation (about 80 neurons a request, 24 requests). Nothing is stored.
//
//   $env:CLOUDFLARE_ACCOUNT_ID = '...'; $env:CLOUDFLARE_API_TOKEN = '...'   # a token with Workers AI read/run
//   node tools/evaluate-assistant.mjs [model]
import { messages, INTENT_SCHEMA, validateIntent, MODEL } from '../src/assistant.mjs';

const model = process.argv[2] ?? MODEL;
const accountId = process.env.CLOUDFLARE_ACCOUNT_ID, token = process.env.CLOUDFLARE_API_TOKEN;
if (!accountId || !token) {
  console.error('Faltan CLOUDFLARE_ACCOUNT_ID y CLOUDFLARE_API_TOKEN.');
  process.exit(2);
}
async function interpret(context) {
  const started = Date.now();
  const res = await fetch(`https://api.cloudflare.com/client/v4/accounts/${accountId}/ai/run/${model}`, {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    signal: AbortSignal.timeout(60000),
    body: JSON.stringify({ messages: messages(context), response_format: { type: 'json_schema', json_schema: INTENT_SCHEMA }, max_tokens: 256, temperature: 0 })
  });
  const body = await res.json();
  const raw = body.result?.response ?? body.result;
  return { ms: Date.now() - started, intent: body.success ? validateIntent(raw) : null, raw, error: body.success ? null : JSON.stringify(body.errors) };
}

const base = {
  today: '2026-11-26',
  accounts: ['Nómina ficticia', 'Inversión ficticia'],
  categories: ['Supermercado', 'Restaurantes', 'Ocio', 'Sueldo'],
  plans: ['Préstamo coche'],
};
const cases = [
  ['Tengo movimientos sin categorías puedes ponérselas?', {}, { kind: 'categorize', uncategorized: true }],
  ['No pero los que no tienen categoría', { lastQuery: 'poner categoría: Movimientos sin categoría de cualquier fecha' }, { kind: 'categorize', uncategorized: true }],
  ['me ayudas a clasificar lo q esta sin categoria del mes pasado', {}, { kind: 'categorize', uncategorized: true, period: 'lastMonth' }],
  ['enseñame los gastos sin categorizar', {}, { kind: 'listMovements', scope: 'expenses', uncategorized: true }],
  ['no, solo los que no tienen categoría', { lastQuery: 'ver: Movimientos este mes' }, { kind: 'listMovements', uncategorized: true, refine: true }],
  ['y los ingresos?', { lastQuery: 'ver: Gastos sin categoría de cualquier fecha' }, { kind: 'listMovements', scope: 'income', refine: true }],
  ['borra los movimientos de ayer', {}, { kind: 'unsupported' }],
  ['enséñame los sin categoría y pónselas', {}, { kind: 'listMovements', uncategorized: true, also: [{ kind: 'categorize' }] }],
  ['apunta 20 € de comida y dime cómo voy este mes', {}, { kind: 'expense', amountMinor: 2000, also: [{ kind: 'summary' }] }],
  ['he pagado 44,53 en la gasolinera', {}, { kind: 'expense', amountMinor: 4453 }],
  ['reserva 200 pa las vacaciones', {}, { kind: 'reserve', amountMinor: 20000 }],
  ['4.378 € en 12 meses del coche, primera cuota el 5 de diciembre', {}, { kind: 'createPlan', amountMinor: 437800, count: 12, dueDate: '2026-12-05' }],
  ['cuánto me queda del préstamo coche', {}, { kind: 'planStatus' }],
  ['el ingreso de 4.378 € es el dinero del préstamo', {}, { kind: 'describeExisting', amountMinor: 437800, role: 'loanReceived' }],
  ['q he gastado en restaurantes esta semana', {}, { kind: 'listMovements', period: 'thisWeek', categoryText: 'Restaurantes' }],
  ['con la de nómina', { draft: 'gasto de 20,00 € (Comida) ; pregunta pendiente: ¿Con qué cuenta?' }, { kind: 'correction', accountText: 'Nómina ficticia' }],
  ['manda 50 euros a mi hermano', {}, { kind: 'unsupported' }],
  ['categoriza los de inversión ficticia', {}, { kind: 'categorize', accountText: 'Inversión ficticia' }],
  ['ponles categoría a los gastos de octubre', {}, { kind: 'categorize', scope: 'expenses', from: '2026-10-01', to: '2026-10-31' }],
  ['organiza un poco lo que me falta por clasificar', {}, { kind: 'categorize', uncategorized: true }],
  ['clasifícame los 5 más nuevos que siguen sin categoría', {}, { kind: 'categorize', uncategorized: true, limit: 5 }],
  ['no, solo dos', { lastQuery: 'poner categoría: Movimientos sin categoría de cualquier fecha (los 5 más recientes)' }, { kind: 'categorize', refine: true, limit: 2 }],
  ['enséñame el último gasto sin categoría', {}, { kind: 'listMovements', scope: 'expenses', uncategorized: true, limit: 1 }],
  ['categoriza los de nómina ficticia anteriores a octubre', {}, { kind: 'categorize', accountText: 'Nómina ficticia', to: '2026-09-30' }],
];

function check(got, want) {
  const misses = [];
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
console.log(`\n${ok}/${total} correctas · mediana ${times[Math.floor(times.length / 2)]} ms · máx ${times.at(-1)} ms`);
process.exitCode = ok === total ? 0 : 1;
