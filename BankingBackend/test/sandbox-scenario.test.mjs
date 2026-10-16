import test from 'node:test';
import assert from 'node:assert/strict';
import { generateScenario } from '../tools/generate-sandbox-scenario.mjs';
import { SCENARIO_ACCOUNTS, scenarioRole } from '../src/sandbox-scenario.mjs';
import { normalizeTransaction } from '../src/provider.mjs';
import { sha256 } from '../src/security.mjs';

test('complete synthetic scenario reconciles three months, accounts, own transfers and stable purchase IDs', async () => {
  const { fixture, expected } = generateScenario(new Date('2026-10-16T12:00:00Z'));
  assert.equal(expected.statementRows, 75);
  assert.equal(expected.transferPairs, 6);
  assert.equal(expected.appMovements, 69);
  assert.equal(expected.netWorthMinor, 676118);
  assert.equal(expected.incomeMinor, 762000);
  assert.equal(expected.expenseMinor, 435882);
  const transfers = new Map();
  for (const [i, account] of fixture.accounts.entries()) {
    const config = SCENARIO_ACCOUNTS[i];
    assert.equal(scenarioRole('Mock ASPSP', config.iban), config.role);
    assert.equal(scenarioRole('BBVA', config.iban), undefined);
    const id = await sha256(`mi-patrimonio-v1:${config.role}`);
    const normalized = await Promise.all(account.transactions.map(t => normalizeTransaction(t, { id, currency: 'EUR' })));
    assert.equal(new Set(normalized.map(t => t.id)).size, normalized.length);
    assert.equal(config.openingMinor + normalized.reduce((n,t) => n+t.signedAmountMinor,0), expected.balances[i].balanceMinor);
    for (const t of normalized.filter(t => t.counterpartyKey)) {
      const legs = transfers.get(t.transferKey) ?? [];
      legs.push({ ...t, ownership: await sha256(config.iban) }); transfers.set(t.transferKey, legs);
    }
  }
  assert.equal(transfers.size, 6);
  for (const legs of transfers.values()) {
    assert.equal(legs.length, 2);
    assert.equal(legs[0].signedAmountMinor + legs[1].signedAmountMinor, 0);
    assert.equal(legs[0].ownership, legs[1].counterpartyKey);
    assert.equal(legs[1].ownership, legs[0].counterpartyKey);
  }
});

test('scenario generation does not create future movements at the beginning of a month', () => {
  const { fixture } = generateScenario(new Date('2026-11-02T12:00:00Z'));
  for (const a of fixture.accounts) for (const t of a.transactions) assert.ok(t.booking_date <= '2026-11-02');
});
