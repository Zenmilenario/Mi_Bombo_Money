import test from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes, createHash } from 'node:crypto';
import { readFile, mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { parseLocalSecrets } from '../tools/parse-secrets.mjs';

const hash = createHash('sha256').update(randomBytes(32)).digest('hex');
const key = randomBytes(32).toString('base64');
const generated = `ACCESS_TOKEN_SHA256="${hash}"\nDATA_ENCRYPTION_KEY="${key}"\n`;

test('generated secret names containing digits are accepted with LF, CRLF, BOM, comments and blank lines', () => {
  for (const contents of [generated, generated.replaceAll('\n', '\r\n'), `\uFEFF# Claves locales\n\n${generated}`]) {
    assert.deepEqual(parseLocalSecrets(contents), { ACCESS_TOKEN_SHA256: hash, DATA_ENCRYPTION_KEY: key });
  }
});

test('unexpected variables and duplicate keys are rejected without revealing values', () => {
  const secret = randomBytes(32).toString('hex');
  for (const contents of [generated + `OTHER_SECRET="${secret}"`, generated + `ACCESS_TOKEN_SHA256="${secret}"`, `${secret}\n${generated}`]) {
    assert.throws(() => parseLocalSecrets(contents), error => !error.message.includes(secret) && !error.message.includes(key));
  }
});

test('missing, malformed and non-canonical cryptographic keys fail closed', () => {
  for (const contents of ['', `ACCESS_TOKEN_SHA256="${hash}"`, generated.replace(hash, 'not-a-hash'),
    generated.replace(key, key.replace(/=+$/, '')), generated.replace(key, randomBytes(31).toString('base64'))]) {
    assert.throws(() => parseLocalSecrets(contents));
  }
});

test('setup command output is accepted by upload parser and its token matches the stored fingerprint', async context => {
  // Use an isolated temporary directory, never the user's real .dev.vars or credentials.
  const fixture = await mkdtemp(path.join(tmpdir(), 'mibombo-setup-test-'));
  const setup = await readFile(new URL('../tools/setup.mjs', import.meta.url), 'utf8');
  const fs = await import('node:fs/promises');
  const tools = path.join(fixture, 'tools');
  context.after(async () => {
    // Remove only the exact files created by this test, without recursive filesystem operations.
    for (const relative of ['.dev.vars', '.client-setup.json', 'tools/setup.mjs']) {
      await fs.unlink(path.join(fixture, relative)).catch(error => { if (error.code !== 'ENOENT') throw error; });
    }
    await fs.rmdir(tools);
    await fs.rmdir(fixture);
  });
  await fs.mkdir(tools);
  const script = path.join(tools, 'setup.mjs');
  await fs.writeFile(script, setup);
  const result = spawnSync(process.execPath, [script], { encoding: 'utf8', windowsHide: true });
  assert.equal(result.status, 0);
  const values = parseLocalSecrets(await readFile(path.join(fixture, '.dev.vars'), 'utf8'));
  const client = JSON.parse(await readFile(path.join(fixture, '.client-setup.json'), 'utf8'));
  assert.equal(values.ACCESS_TOKEN_SHA256, createHash('sha256').update(client.token).digest('hex'));
  assert.ok(!result.stdout.includes(client.token) && !result.stdout.includes(values.DATA_ENCRYPTION_KEY));
  const repeated = spawnSync(process.execPath, [script], { encoding: 'utf8', windowsHide: true });
  assert.notEqual(repeated.status, 0, 'Setup must not silently rotate existing credentials');
  assert.deepEqual(parseLocalSecrets(await readFile(path.join(fixture, '.dev.vars'), 'utf8')), values);
});
