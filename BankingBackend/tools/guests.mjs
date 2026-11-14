// Manages the invited people of the personal Worker.
// Usage: npm run guests -- list | add <supabase-user-id> | remove <supabase-user-id> [--db]
// Without --db it edits SUPABASE_GUEST_IDS in .personal/wrangler.jsonc; deploying it is a separate, explicit step
// (npx wrangler deploy -c .personal/wrangler.jsonc). With --db it changes the `guests` table of the personal D1
// (migrations/0004_guests.sql) and takes effect on the next request, without deploying.
import { readFileSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
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

/// The D1 statement for an action on the `guests` table. The ID is validated first, so it can be written into the SQL.
export function guestStatement(action, id, ownerID, at = Math.floor(Date.now() / 1000)) {
  if (action === 'list') return 'SELECT id, added_at FROM guests ORDER BY added_at';
  if (action !== 'add' && action !== 'remove') throw new Error('Usa list, add <id> o remove <id>.');
  updateGuests('', 'add', id, ownerID); // The same checks as the list: a real Supabase ID that is not the owner's.
  const normalized = id.toLowerCase();
  if (action === 'add') return `INSERT INTO guests(id, added_at) VALUES ('${normalized}', ${Number(at)}) ON CONFLICT(id) DO NOTHING`;
  return `DELETE FROM guests WHERE id = '${normalized}'`;
}

function main() {
  const args = process.argv.slice(2);
  const database = args.includes('--db');
  const [action = 'list', id] = args.filter(arg => arg !== '--db');
  const path = resolve(fileURLToPath(new URL('../', import.meta.url)), '.personal/wrangler.jsonc');
  const config = JSON.parse(readFileSync(path, 'utf8'));
  const vars = config.vars ?? {};
  if (database) {
    const command = guestStatement(action, id, vars.SUPABASE_OWNER_ID);
    const windows = process.platform === 'win32';
    execFileSync(windows ? 'npx.cmd' : 'npx', ['wrangler', 'd1', 'execute', 'DB', '--remote', '--config', '.personal/wrangler.jsonc', '--command', command],
      { stdio: 'inherit', shell: windows });
    return;
  }
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
