import { readFileSync, writeFileSync } from 'node:fs';
import { normalizeTransaction, amountMinor } from '../src/provider.mjs';
import { sha256 } from '../src/security.mjs';
import { SCENARIO_ACCOUNTS, SCENARIO_ID } from '../src/sandbox-scenario.mjs';

// Exercise the same normalization used for provider responses, without any key.
const fixture = JSON.parse(readFileSync(new URL('../../Samples/sandbox/mi-patrimonio-mock.json', import.meta.url)));
const expected = JSON.parse(readFileSync(new URL('../../Samples/sandbox/resultados-esperados.json', import.meta.url)));
const accounts = await Promise.all(SCENARIO_ACCOUNTS.map(async a => ({
  id: await sha256(`${SCENARIO_ID}:${a.role}`), name: a.name, currency: 'EUR', lastFour: a.ending,
  ownershipKey: await sha256(a.iban), testRole: a.role
})));
const connection = { id: '00000000-0000-4000-8000-000000000001', bank: 'Mock ASPSP',
  validUntil: `${expected.asOf}T23:59:59Z`, testScenario: SCENARIO_ID, accounts };
const feeds = await Promise.all(fixture.accounts.map(async (data, i) => ({
  connection, account: accounts[i], balances: data.balances.map(b => ({
    type: b.balance_type, currency: b.balance_amount.currency, amountMinor: amountMinor(b.balance_amount.amount)
  })), movements: await Promise.all(data.transactions.map(t => normalizeTransaction(t, accounts[i])))
})));
writeFileSync(process.argv[2] ?? '../build/sandbox-import-check.json', JSON.stringify({ feeds, expected }));
