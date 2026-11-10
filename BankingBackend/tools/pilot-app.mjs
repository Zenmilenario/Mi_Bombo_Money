// Uploads the pilot application's credentials (for invited people) to the personal Worker as secrets.
// Usage: npm run pilot-app -- --app-id <uuid> --pem <path to the downloaded .pem>
// The key travels only over stdin to Wrangler: never as an argument, in a file of this repository or on screen.
import { createPrivateKey } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';

const UUID = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;

/// Validates and returns the two secrets. Throws a message that never contains the key.
export function pilotSecrets({ appID, pem, personalAppID }) {
  if (!UUID.test(appID ?? '')) throw new Error('El identificador de la aplicación piloto no es válido (formato UUID).');
  if (personalAppID && appID.toLowerCase() === personalAppID.toLowerCase()) {
    throw new Error('Ese identificador es el de tu aplicación personal. Usa el de «Doblón Piloto».');
  }
  let key;
  try { key = createPrivateKey(pem); } catch { throw new Error('No se ha podido leer la clave privada (.pem) de la aplicación piloto.'); }
  if (key.asymmetricKeyType !== 'rsa' || key.asymmetricKeyDetails.modulusLength < 4096) {
    throw new Error('La clave de la aplicación piloto debe ser RSA de al menos 4096 bits.');
  }
  return { ENABLE_GUEST_APP_ID: appID.toLowerCase(), ENABLE_GUEST_PRIVATE_KEY: key.export({ type: 'pkcs8', format: 'pem' }) };
}

function main() {
  const flags = {};
  for (let i = 2; i < process.argv.length; i += 2) {
    const name = process.argv[i]; const value = process.argv[i + 1];
    if (!['--app-id', '--pem'].includes(name) || !value || flags[name]) throw new Error('Usa --app-id <identificador> y --pem <ruta del archivo .pem>.');
    flags[name] = value;
  }
  if (!flags['--app-id'] || !flags['--pem']) throw new Error('Faltan --app-id o --pem.');
  const root = fileURLToPath(new URL('../', import.meta.url));
  const config = resolve(root, '.personal/wrangler.jsonc');
  const secrets = pilotSecrets({ appID: flags['--app-id'], pem: readFileSync(resolve(flags['--pem']), 'utf8') });
  const result = spawnSync(process.execPath, [fileURLToPath(new URL('../node_modules/wrangler/bin/wrangler.js', import.meta.url)),
    'secret', 'bulk', '-c', config], {
    cwd: root, input: JSON.stringify(secrets), encoding: 'utf8', stdio: ['pipe', 'inherit', 'inherit'],
    env: { ...process.env, WRANGLER_SEND_METRICS: 'false' }, windowsHide: true
  });
  if (result.error || result.status !== 0) throw new Error('No se pudieron guardar las credenciales de la aplicación piloto en Cloudflare.');
  console.log('Aplicación piloto configurada. Ya puedes borrar el archivo .pem de Descargas si tienes otra copia segura.');
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { main(); } catch (error) { console.error(error.message); process.exitCode = 1; }
}
