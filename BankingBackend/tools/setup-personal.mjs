// Prepares an independent deployment. Never uploads secrets or deploys automatically.
import { createPrivateKey, randomBytes } from 'node:crypto';
import { mkdir, readFile, writeFile, access } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
export function personalConfiguration({ appID, ownerID, databaseID, pem, publishableKey }) {
  for (const id of [appID, ownerID, databaseID]) {
    if (!/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(id ?? '') || /^0{8}-/.test(id)) {
      throw new Error('Revisa los identificadores de aplicación, propietario y base personal. No se admiten valores de ejemplo.');
    }
  }
  if (!/^sb_publishable_[A-Za-z0-9_-]+$/.test(publishableKey ?? '')) throw new Error('Falta la configuración pública de Supabase.');
  let key;
  try { key = createPrivateKey(pem); }
  catch { throw new Error('No se ha podido leer la clave privada de la aplicación PRODUCTION.'); }
  if (key.asymmetricKeyType !== 'rsa' || key.asymmetricKeyDetails.modulusLength < 4096) throw new Error('Se requiere una clave RSA de al menos 4096 bits.');
  return {
    config: {
      name: 'mi-bombo-banking-personal', main: '../src/worker.mjs', compatibility_date: '2026-10-12',
      compatibility_flags: ['nodejs_compat'], workers_dev: true, send_metrics: false, observability: { enabled: false },
      vars: { PROVIDER_MODE: 'production', BANKING_AUTH: 'supabase-owner',
        PUBLIC_ORIGIN: 'https://mi-bombo-banking-personal.albertor7722.workers.dev',
        SUPABASE_URL: 'https://coeicjffmpclqowsqeys.supabase.co', SUPABASE_PUBLISHABLE_KEY: publishableKey, SUPABASE_OWNER_ID: ownerID },
      d1_databases: [{ binding: 'DB', database_name: 'mi-bombo-banking-personal', database_id: databaseID, migrations_dir: '../migrations' }]
    },
    secrets: { ENABLE_APP_ID: appID, ENABLE_PRIVATE_KEY: key.export({ type: 'pkcs8', format: 'pem' }),
      DATA_ENCRYPTION_KEY: randomBytes(32).toString('base64'), ACCOUNT_IDENTITY_KEY: randomBytes(32).toString('base64') }
  };
}

async function main() {
  const flags = {};
  for (let i = 2; i < process.argv.length; i += 2) {
    const name = process.argv[i]; const value = process.argv[i + 1];
    if (!['--app-id', '--owner-id', '--database-id', '--pem'].includes(name) || !value || flags[name]) throw new Error('Usa --app-id, --owner-id, --database-id y --pem. No introduzcas la clave como argumento.');
    flags[name] = value;
  }
  if (Object.keys(flags).length !== 4) throw new Error('Faltan --app-id, --owner-id, --database-id o --pem.');
  const directory = resolve(root, '.personal');
  try { await access(directory); throw new Error('La carpeta .personal ya existe. No se sobrescriben ni rotan claves existentes.'); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  const publicConfig = JSON.parse(await readFile(resolve(root, '../MiPatrimonio/Resources/CloudConfiguration.json'), 'utf8'));
  const prepared = personalConfiguration({ appID: flags['--app-id'], ownerID: flags['--owner-id'], databaseID: flags['--database-id'],
    pem: await readFile(resolve(flags['--pem']), 'utf8'), publishableKey: publicConfig.publishableKey });
  await mkdir(directory, { mode: 0o700 });
  if (process.platform === 'win32') {
    // Protect the directory before writing any secret. Do not print the SID or key contents.
    const user = execFileSync('whoami.exe', ['/user', '/fo', 'csv', '/nh'], { encoding: 'utf8', windowsHide: true });
    const sid = user.match(/S-1-5-21-[0-9-]+/)?.[0];
    if (!sid) throw new Error('No se ha podido determinar el propietario para proteger los archivos.');
    execFileSync('icacls.exe', [directory, '/inheritance:r', '/grant:r', `*${sid}:(OI)(CI)F`, '/grant:r', '*S-1-5-18:(OI)(CI)F', '/q'], { stdio: 'ignore', windowsHide: true });
  }
  await writeFile(resolve(directory, 'wrangler.jsonc'), JSON.stringify(prepared.config, null, 2) + '\n', { flag: 'wx', mode: 0o600 });
  await writeFile(resolve(directory, 'secrets.json'), JSON.stringify(prepared.secrets), { flag: 'wx', mode: 0o600 });
  console.log('Configuración personal creada en BankingBackend/.personal con permisos privados. No se ha desplegado ni subido ninguna clave.');
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(() => { console.error('No se ha podido preparar la conexión personal. Comprueba los parámetros, la clave PRODUCTION y que .personal no exista. No compartas secretos para diagnosticarlo.'); process.exitCode = 1; });
}
