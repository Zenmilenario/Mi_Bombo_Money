const allowedNames = new Set(['ACCESS_TOKEN_SHA256', 'DATA_ENCRYPTION_KEY']);

// Parse only our generated format; never include a line or secret value in an error.
export function parseLocalSecrets(contents) {
  const values = {};
  for (const [index, original] of contents.replace(/^\uFEFF/, '').split(/\r?\n/).entries()) {
    const line = original.trim();
    if (!line || line.startsWith('#')) continue;
    const match = /^([A-Z][A-Z0-9_]*)="([^"\r\n]*)"$/.exec(line);
    if (!match || !allowedNames.has(match[1])) {
      throw new Error(`Formato de claves inesperado en la línea ${index + 1}. Revisa el formato sin compartir sus valores.`);
    }
    if (Object.hasOwn(values, match[1])) throw new Error(`Variable repetida en la línea ${index + 1}.`);
    values[match[1]] = match[2];
  }
  if (!/^[a-f0-9]{64}$/.test(values.ACCESS_TOKEN_SHA256 ?? '')) throw new Error('ACCESS_TOKEN_SHA256 debe contener una huella SHA-256 hexadecimal de 64 caracteres.');
  const encryption = values.DATA_ENCRYPTION_KEY ?? '';
  const decoded = Buffer.from(encryption, 'base64');
  if (decoded.length !== 32 || decoded.toString('base64') !== encryption) throw new Error('DATA_ENCRYPTION_KEY debe contener una clave de 32 bytes en Base64 válido.');
  return values;
}
