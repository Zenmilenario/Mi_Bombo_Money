import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { parseLocalSecrets } from './parse-secrets.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const contents = readFileSync(new URL('../.dev.vars', import.meta.url), 'utf8');
const values = parseLocalSecrets(contents);
// Secrets travel only over stdin, never shell interpolation, arguments or console output.
const result = spawnSync(process.execPath, [fileURLToPath(new URL('../node_modules/wrangler/bin/wrangler.js', import.meta.url)), 'secret', 'bulk'], {
  cwd: root, input: JSON.stringify(values), encoding: 'utf8', stdio: ['pipe', 'inherit', 'inherit'],
  env: { ...process.env, WRANGLER_SEND_METRICS: 'false' }, windowsHide: true
});
if (result.error || result.status !== 0) throw new Error('No se pudieron configurar los secretos en Cloudflare.');
