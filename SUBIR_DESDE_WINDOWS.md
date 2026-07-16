# Subir este proyecto desde Windows

El repositorio de destino es:

`https://github.com/Zenmilenario/Mi_Bombo_Money`

## Metodo automatico

1. Instala **Git for Windows** si todavia no lo tienes.
2. Extrae por completo el ZIP del proyecto.
3. Haz doble clic en `SUBIR_A_GITHUB.bat`.
4. Introduce tu nombre y el correo que quieres asociar al commit si Git no los conoce.
5. Cuando GitHub lo solicite, inicia sesion en el navegador y autoriza Git Credential Manager.

El script crea una copia del repositorio en:

`Documentos\\Mi_Bombo_Money_repo`

Despues copia el proyecto, crea el primer commit y lo sube a la rama `main`.

## Metodo manual con PowerShell o Git Bash

Abre una terminal dentro de la carpeta extraida y ejecuta:

```bash
git init
git add .
git commit -m "Añadir MVP inicial de Mi Patrimonio"
git branch -M main
git remote add origin https://github.com/Zenmilenario/Mi_Bombo_Money.git
git push -u origin main
```

Si `git commit` solicita identidad:

```bash
git config user.name "Tu nombre"
git config user.email "tu-correo@ejemplo.com"
```

No uses la contraseña de GitHub en la terminal. Inicia sesion mediante la ventana del navegador que abre Git Credential Manager.

## Compilar desde GitHub

Tras la subida:

1. Entra en el repositorio.
2. Abre **Actions**.
3. Selecciona **Compilar para iOS Simulator**.
4. Pulsa **Run workflow**.
5. Cuando termine correctamente, abre la ejecucion y descarga el artefacto `MiPatrimonio-iOS-Simulator`.
6. Dentro encontraras `MiPatrimonio-Simulator.zip`, preparado para una plataforma de simulacion web compatible con aplicaciones `.app` de iOS Simulator.
