import { randomBytes, createHash } from 'node:crypto';
import { writeFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const files = ['.dev.vars', '.client-setup.json'];
if (files.some(file => existsSync(path.join(root, file)))) {
  throw new Error('Ya hay claves locales. Conserva las actuales o sigue la guía de rotación; no se sobrescriben.');
}
const token = randomBytes(32).toString('hex');
const hash = createHash('sha256').update(token).digest('hex');
const encryption = randomBytes(32).toString('base64');
writeFileSync(path.join(root, '.dev.vars'), `ACCESS_TOKEN_SHA256="${hash}"\nDATA_ENCRYPTION_KEY="${encryption}"\n`, { mode: 0o600, flag: 'wx' });
writeFileSync(path.join(root, '.client-setup.json'), JSON.stringify({ serverURL: '', token }, null, 2), { mode: 0o600, flag: 'wx' });
console.log('Claves generadas en archivos locales excluidos de Git. No se muestran en la consola. Sigue README.md para protegerlas y configurarlas.');
