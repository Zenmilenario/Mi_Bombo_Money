# Generación de IPA mediante GitHub Actions

El proyecto incluye dos workflows independientes dentro de `.github/workflows/`.

## Opción inmediata: IPA sin firmar

El workflow **Generar IPA sin firmar** compila la aplicación para un iPhone real y crea un archivo `.ipa` sin necesitar certificados ni secretos.

1. Abre el repositorio en GitHub.
2. Entra en **Actions**.
3. Selecciona **Generar IPA sin firmar**.
4. Pulsa **Run workflow**.
5. Mantén el Bundle ID propuesto o introduce otro identificador único.
6. Cuando finalice, descarga el artefacto `MiPatrimonio-IPA-...`.

Este IPA debe firmarse durante la instalación con una herramienta compatible, por ejemplo AltStore o Sideloadly. No se puede instalar directamente en iOS mientras siga sin firmar.

El workflow también se ejecuta cuando se publica una etiqueta de Git cuyo nombre empiece por `v`, por ejemplo `v0.2.2`.

## Opción instalable directamente: IPA firmado

El workflow **Generar IPA firmado** usa un certificado Apple y un perfil de aprovisionamiento guardados como GitHub Actions Secrets. El dispositivo debe estar admitido por el perfil.

Configura estos secretos en **Settings > Secrets and variables > Actions > New repository secret**:

| Secret | Contenido |
|---|---|
| `BUILD_CERTIFICATE_BASE64` | Certificado `.p12` convertido a Base64. Debe incluir la clave privada. |
| `P12_PASSWORD` | Contraseña del archivo `.p12`. |
| `BUILD_PROVISION_PROFILE_BASE64` | Perfil `.mobileprovision` convertido a Base64. |
| `KEYCHAIN_PASSWORD` | Contraseña temporal y aleatoria para el keychain del runner. |
| `BUNDLE_IDENTIFIER` | Bundle ID incluido en el perfil, por ejemplo `com.zenmilenario.mibombomoney`. |

### Convertir los archivos a Base64 en macOS

```bash
base64 -i Certificado.p12 | pbcopy
base64 -i MiPatrimonio.mobileprovision | pbcopy
```

Ejecuta cada comando por separado y pega el contenido del portapapeles en el secret correspondiente.

### Convertir los archivos a Base64 en Windows PowerShell

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("C:\ruta\Certificado.p12")) | Set-Clipboard
[Convert]::ToBase64String([IO.File]::ReadAllBytes("C:\ruta\MiPatrimonio.mobileprovision")) | Set-Clipboard
```

Después:

1. Entra en **Actions**.
2. Selecciona **Generar IPA firmado**.
3. Pulsa **Run workflow**.
4. Descarga `MiPatrimonio-IPA-Firmado-...` cuando el proceso termine.

El workflow valida que el Bundle ID coincide con el perfil, instala el certificado en un keychain temporal, firma la aplicación, comprueba la firma, crea el IPA y elimina el material de firma del runner al finalizar.

## Seguridad

- No subas nunca al repositorio archivos `.p12`, `.mobileprovision`, contraseñas ni textos Base64 de firma.
- Mantén el workflow firmado como ejecución manual para evitar usos involuntarios.
- Si un certificado o perfil se expone, revócalo y sustitúyelo.
- El repositorio puede ser público; los valores guardados como Actions Secrets no se incluyen en el código ni en los artefactos de diagnóstico.
