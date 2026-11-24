#!/usr/bin/env python3
"""Stops personal financial data and secrets from reaching this public repository.

It checks every tracked file and prints only where a problem is and its kind, never the value:
- files that only hold personal data (spreadsheets, bank statements, app exports and backups, keys);
- private keys, live API keys and Supabase tokens other than the public `anon` one;
- addresses of personal mail providers;
- IBANs outside the folders of fictitious test data.

Fictitious data for tests lives in test folders and samples; real data stays outside the repository (see
`.gitignore`). Run locally with `python3 Tools/privacy_check.py`; CI runs it on every pull request and push.
"""
import base64
import json
import re
import subprocess
import sys

FORBIDDEN_FILES = re.compile(
    r'(?i)(\.(xlsx|xls|numbers|ods|ofx|qif|qfx|pem|key|p12|mobileprovision|keychain-db|sqlite|db)$'
    r'|(^|/)doblon-copia-[^/]*\.json$|(^|/)\.env($|\.)|(^|/)\.dev\.vars|(^|/)Privado/|(^|/)exportaciones/|(^|/)\.personal/)'
)
TEST_DATA = re.compile(r'(?i)(^|/)(test|tests|Tests|Samples|fixtures?)(/|$)|_test\.|\.test\.|Check\.swift$')
BINARY = re.compile(r'(?i)\.(png|jpe?g|webp|gif|ico|icns|ttf|otf|woff2?|pdf|ipa|apk|aab|zip|mlmodel|mlmodelc|bin|jar)$')

PRIVATE_KEY = re.compile(r'-----BEGIN [A-Z ]*PRIVATE KEY-----\s*[A-Za-z0-9+/=\s]{64,}')
LIVE_KEYS = re.compile(r'\b(sk_live_[A-Za-z0-9]{10,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sbp_[A-Za-z0-9]{20,}|sb_secret_[A-Za-z0-9_-]{10,}|AKIA[0-9A-Z]{16})')
JWT = re.compile(r'\beyJ[A-Za-z0-9_-]{10,}\.([A-Za-z0-9_-]{10,})\.[A-Za-z0-9_-]{10,}')
PERSONAL_MAIL = re.compile(r'(?i)\b[A-Za-z0-9._%+-]+@(gmail|googlemail|hotmail|outlook|live|icloud|me|yahoo|protonmail|proton)\.[a-z.]{2,6}\b')
IBAN = re.compile(r'\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){3,7}\b')


def valid_iban(text):
    compact = text.replace(' ', '')
    if not 15 <= len(compact) <= 34:
        return False
    moved = compact[4:] + compact[:4]
    digits = ''.join(str(int(c, 36)) for c in moved)
    return int(digits) % 97 == 1


def jwt_role(payload):
    try:
        return json.loads(base64.urlsafe_b64decode(payload + '=' * (-len(payload) % 4))).get('role')
    except Exception:
        return None


def main():
    files = subprocess.run(['git', 'ls-files', '-z'], capture_output=True, check=True).stdout.decode().split('\0')
    problems = []
    for path in filter(None, files):
        if FORBIDDEN_FILES.search(path):
            problems.append((path, 0, 'archivo de datos personales o claves (debe estar fuera del repositorio)'))
            continue
        if BINARY.search(path):
            continue
        try:
            text = open(path, encoding='utf-8', errors='ignore').read()
        except OSError:
            continue

        def line(match):
            return text.count('\n', 0, match.start()) + 1

        for m in PRIVATE_KEY.finditer(text):
            problems.append((path, line(m), 'clave privada'))
        for m in LIVE_KEYS.finditer(text):
            problems.append((path, line(m), 'clave o token de un servicio'))
        for m in JWT.finditer(text):
            if jwt_role(m.group(1)) != 'anon':
                problems.append((path, line(m), 'token de Supabase que no es el público (anon)'))
        for m in PERSONAL_MAIL.finditer(text):
            problems.append((path, line(m), 'correo de un proveedor personal'))
        if not TEST_DATA.search(path) and not path.endswith('.pbxproj'):
            for m in IBAN.finditer(text):
                if valid_iban(m.group(0)):
                    problems.append((path, line(m), 'IBAN fuera de los datos ficticios de pruebas'))

    for path, number, kind in problems:
        print(f'{path}:{number}: {kind}')
    if problems:
        print(f'\n{len(problems)} posibles datos privados. Muévelos fuera del repositorio o sustitúyelos por datos ficticios.')
        return 1
    print('Sin datos personales ni secretos en los archivos versionados.')
    return 0


def self_test():
    """Plants fictitious data in a temporary repository and requires every kind to be found."""
    import os, secrets, tempfile
    here = os.path.abspath(__file__)
    with tempfile.TemporaryDirectory() as folder:
        def write(name, text):
            os.makedirs(os.path.join(folder, os.path.dirname(name)), exist_ok=True)
            open(os.path.join(folder, name), 'w', encoding='utf-8').write(text)
        # Built from parts so that this file itself does not contain them.
        mail, iban = 'persona.ficticia' + '@' + 'gmail.com', 'ES91' + '2100' + '0418' + '4502' + '0005' + '1332'
        write('docs/nota.md', f'contacto: {mail}\nIBAN {iban}\n')
        write('Tests/datos.swift', f'IBAN {iban}\n')  # fictitious test data: allowed
        key = base64.b64encode(secrets.token_bytes(120)).decode()
        write('docs/clave.txt', '-----BEGIN PRIVATE KEY-----\n' + key + '\n-----END PRIVATE KEY-----\n')
        write('cuentas.xlsx', '')
        subprocess.run(['git', 'init', '-q'], cwd=folder, check=True)
        subprocess.run(['git', 'add', '-A'], cwd=folder, check=True)
        out = subprocess.run([sys.executable, here], cwd=folder, capture_output=True, text=True)
        expected = ['cuentas.xlsx:0', 'docs/clave.txt:1: clave privada', 'docs/nota.md:1: correo', 'docs/nota.md:2: IBAN']
        missing = [e for e in expected if e not in out.stdout]
        if out.returncode != 1 or missing or 'Tests/datos.swift' in out.stdout:
            print('La comprobación no detecta lo que debe:', missing or out.stdout)
            return 1
    print('Autoprueba correcta: detecta archivos, claves, correos e IBAN, y respeta los datos ficticios de pruebas.')
    return 0


if __name__ == '__main__':
    sys.exit(self_test() if '--self-test' in sys.argv else main())
