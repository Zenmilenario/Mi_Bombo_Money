// Manages the invited people of the personal Worker (SUPABASE_GUEST_IDS in .personal/wrangler.jsonc).
// Usage: npm run guests -- list | add <supabase-user-id> | remove <supabase-user-id>
// It only edits the local configuration; deploying it is a separate, explicit step (npx wrangler deploy -c .personal/wrangler.jsonc).
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';

const UUID = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;

/// Returns the new comma-separated list. Rejects malformed IDs and the owner (always admitted).
export function updateGuests(current, action, id, ownerID) {
  const guests = String(current ?? '').split(',').map(value => value.trim().toLowerCase()).filter(Boolean);
  if (action === 'list') return guests.join(',');
  if (!UUID.test(id ?? '')) throw new Error('El identificador no es válido: copia el «User UID» de Supabase › Authentication › Users.');
  const normalized = id.toLowerCase();
  if (normalized === String(ownerID ?? '').toLowerCase()) throw new Error('Ese es tu propio usuario: ya tiene acceso como propietario.');
  if (action === 'add') return [...new Set([...guests, normalized])].join(',');
  if (action === 'remove') {
    if (!guests.includes(normalized)) throw new Error('Esa persona no está en la lista de invitados.');
    return guests.filter(value => value !== normalized).join(',');
  }
  throw new Error('Usa list, add <id> o remove <id>.');
}

function main() {
  const [action = 'list', id] = process.argv.slice(2);
  const path = resolve(fileURLToPath(new URL('../', import.meta.url)), '.personal/wrangler.jsonc');
  const config = JSON.parse(readFileSync(path, 'utf8'));
  const vars = config.vars ?? {};
  const next = updateGuests(vars.SUPABASE_GUEST_IDS, action, id, vars.SUPABASE_OWNER_ID);
  if (action === 'list') {
    console.log(next ? `Personas invitadas (${next.split(',').length}):\n${next.split(',').join('\n')}` : 'No hay personas invitadas.');
    return;
  }
  config.vars = { ...vars, SUPABASE_GUEST_IDS: next };
  writeFileSync(path, JSON.stringify(config, null, 2) + '\n');
  console.log(`Lista actualizada (${next ? next.split(',').length : 0} invitadas). Para aplicarla: npx wrangler deploy -c .personal/wrangler.jsonc`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { main(); } catch (error) { console.error(error.message); process.exitCode = 1; }
}
