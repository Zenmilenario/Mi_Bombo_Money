// Creates the key that seals what the app sends to Don Bigotes' interpreter (26 November 2026). The private key is
// written to .personal/assistant-key.json (outside Git) and never printed; the public key is printed so it can be
// placed in the app (doblon_android/lib/assistant_crypto.dart). To install it in the Worker, with confirmation:
//   npx wrangler secret put ASSISTANT_KEY --config .personal/wrangler.jsonc < .personal/assistant-key.json
import { existsSync, writeFileSync } from 'node:fs';

const file = new URL('../.personal/assistant-key.json', import.meta.url);
if (existsSync(file)) {
  console.error('Ya existe .personal/assistant-key.json: no se sobrescribe.');
  process.exit(1);
}
const pair = await crypto.subtle.generateKey({ name: 'X25519' }, true, ['deriveBits']);
const jwk = await crypto.subtle.exportKey('jwk', pair.privateKey);
writeFileSync(file, JSON.stringify(jwk), { mode: 0o600 });
const raw = new Uint8Array(await crypto.subtle.exportKey('raw', pair.publicKey));
console.log(`Clave pública (para la app): ${Buffer.from(raw).toString('base64')}`);
