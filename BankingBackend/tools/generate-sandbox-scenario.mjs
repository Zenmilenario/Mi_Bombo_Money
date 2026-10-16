import { writeFileSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { SCENARIO_ACCOUNTS, SCENARIO_ID } from '../src/sandbox-scenario.mjs';

export function generateScenario(asOf = new Date()) {
  const today = asOf.toISOString().slice(0, 10);
  const accounts = SCENARIO_ACCOUNTS.map((a, i) => ({
    info: { name: a.name, details: `${SCENARIO_ID}:${a.role}`, currency: 'EUR', usage: 'PRIV', cash_account_type: 'CACC',
      account_id: { iban: a.iban }, all_account_ids: [{ scheme_name: 'IBAN', identification: a.iban }],
      resource_id: `10000000-0000-4000-8000-00000000000${i + 1}` },
    transactions: [], balances: [], openingMinor: a.openingMinor
  }));
  const money = value => (value / 100).toFixed(2);
  function post(index, date, amount, label, reference, counterparty, pairReference) {
    if (date > today) return;
    const positive = amount > 0;
    const row = { entry_reference: reference, transaction_id: reference, status: 'BOOK',
      transaction_amount: { amount: money(Math.abs(amount)), currency: 'EUR' }, credit_debit_indicator: positive ? 'CRDT' : 'DBIT',
      booking_date: date, value_date: date, remittance_information: [label], reference_number: pairReference ?? reference };
    if (counterparty) row[positive ? 'debtor_account' : 'creditor_account'] = { iban: SCENARIO_ACCOUNTS[counterparty.index].iban };
    accounts[index].transactions.push(row);
  }
  for (let offset = -2; offset <= 0; offset++) {
    const month = new Date(Date.UTC(asOf.getUTCFullYear(), asOf.getUTCMonth() + offset, 1));
    const prefix = month.toISOString().slice(0, 7);
    const date = day => `${prefix}-${String(day).padStart(2, '0')}`;
    post(0, date(1), 250000, 'Nómina empresa de prueba', `${prefix}-salary`);
    const charges = [
      [2,85000,'Alquiler vivienda'], [3,4560,'Supermercado cesta semanal'], [4,8235,'Electricidad hogar'],
      [5,3990,'Internet y móvil'], [6,7280,'Supermercado compra familiar'], [7,3500,'Transporte abono'],
      [8,1840,'Farmacia'], [9,4250,'Restaurante'], [10,6125,'Supermercado'], [11,9995,'Compras hogar'],
      [12,1299,'Suscripción streaming'], [13,2430,'Supermercado'], [14,2750,'Ocio cine'], [15,2590,'Mascotas'],
      [15,650,'Café compra uno'], [15,650,'Café compra dos']
    ];
    charges.forEach(([day, amount, text], i) => post(0, date(day), -amount, text, `${prefix}-charge-${i}`));
    post(0, date(14), 2500, 'Reembolso compra de prueba', `${prefix}-refund`);
    for (const [day, target, amount, label] of [[3,1,30000,'Aportación máster'],[5,2,25000,'Aportación inversión']]) {
      const ref = `${prefix}-own-transfer-${target}`;
      post(0, date(day), -amount, label, `${ref}-out`, { index: target }, ref);
      post(target, date(day), amount, label, `${ref}-in`, { index: 0 }, ref);
    }
    post(1, date(15), 300, 'Intereses ahorro', `${prefix}-savings-interest`);
    post(2, date(7), -150, 'Comisión cuenta de valores', `${prefix}-fee`);
    post(2, date(14), 1200, 'Dividendos de prueba', `${prefix}-dividend`);
  }
  let incomeMinor = 0, expenseMinor = 0, statementRows = 0, transferPairs = 0;
  for (const account of accounts) {
    let balance = account.openingMinor;
    for (const row of account.transactions) {
      const amount = Math.round(Number(row.transaction_amount.amount) * 100);
      const signed = row.credit_debit_indicator === 'CRDT' ? amount : -amount;
      balance += signed; statementRows++;
      if (row.creditor_account || row.debtor_account) { if (signed < 0) transferPairs++; }
      else if (signed > 0) incomeMinor += signed; else expenseMinor += amount;
    }
    account.transactions.sort((a,b) => b.booking_date.localeCompare(a.booking_date) || a.entry_reference.localeCompare(b.entry_reference));
    account.balances = [{ balance_type: 'CLBD', name: 'Saldo contable de prueba', reference_date: today,
      last_change_date_time: null, last_committed_transaction: null,
      balance_amount: { amount: money(balance), currency: 'EUR' } }];
    delete account.openingMinor;
  }
  return { fixture: { accounts }, expected: { scenario: SCENARIO_ID, asOf: today, accounts: accounts.length,
    statementRows, transferPairs, appMovements: statementRows - transferPairs, incomeMinor, expenseMinor,
    netSavingsMinor: incomeMinor - expenseMinor, netWorthMinor: accounts.reduce((n,a) => n + Math.round(Number(a.balances[0].balance_amount.amount)*100),0),
    balances: accounts.map((a,i) => ({ role: SCENARIO_ACCOUNTS[i].role, balanceMinor: Math.round(Number(a.balances[0].balance_amount.amount)*100) })) } };
}
if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const destination = new URL('../../Samples/sandbox/', import.meta.url);
  mkdirSync(destination, { recursive: true });
  const data = generateScenario();
  writeFileSync(new URL('mi-patrimonio-mock.json', destination), JSON.stringify(data.fixture, null, 2) + '\n');
  writeFileSync(new URL('resultados-esperados.json', destination), JSON.stringify(data.expected, null, 2) + '\n');
  console.log(JSON.stringify(data.expected, null, 2));
}
