// Synthetic account identifiers reserved for our reproducible Mock ASPSP case.
// They identify fixtures, never a person's account. Used only after SANDBOX verification.
export const SCENARIO_ID = 'mi-patrimonio-v1';
export function fixtureIBAN(ending) {
  const bban = `9999000000000000${ending}`;
  const check = 98n - (BigInt(`${bban}142800`) % 97n);
  return `ES${check.toString().padStart(2, '0')}${bban}`;
}
export const SCENARIO_ACCOUNTS = [
  { role: 'daily', ending: '1111', name: 'Día a día · Prueba', openingMinor: 200000 },
  { role: 'reserved', ending: '2222', name: 'Máster · Prueba', openingMinor: 100000 },
  { role: 'investment', ending: '3333', name: 'Inversión · Prueba', openingMinor: 50000 }
].map(account => ({ ...account, iban: fixtureIBAN(account.ending) }));

export function scenarioRole(bank, iban) {
  if (bank !== 'Mock ASPSP') return undefined;
  return SCENARIO_ACCOUNTS.find(account => account.iban === iban)?.role;
}
