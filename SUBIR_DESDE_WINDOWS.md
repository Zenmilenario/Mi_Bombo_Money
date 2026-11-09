# Subir este proyecto desde Windows

El repositorio de destino es:

`https://github.com/Zenmilenario/Mi_Bombo_Money`

## Revisar cambios con GitHub Desktop antes del merge

Si ya tienes este repositorio clonado, utiliza esta sección para las actualizaciones:

1. Abre el repositorio en **GitHub Desktop** y conserva tu rama de trabajo `codex/…`.
2. Revisa los archivos en **Changes**, escribe un resumen y haz commit en esa rama.
3. Pulsa **Push origin**.
4. Abre una **pull request en borrador** si la rama aún no tiene una. Localiza las ejecuciones del último commit en **Checks** o **Actions**.
5. Espera a que pasen los cuatro workflows: **Validar app iOS** (Debug para simulador y Release para dispositivo), **Comprobar datos y cálculos**, **Comprobar conexión bancaria de prueba** y **Comprobar almacenamiento cloud**.
6. Haz el merge cuando todos los checks del último commit estén en verde y hayas revisado el aspecto en los dispositivos que usas. La lista visual está en `docs/historico/PRUEBAS_REDISENO.md`.

Con una PR abierta, cada push de la rama ejecuta todas las comprobaciones una vez por workflow: no hace falta hacer merge para probarla. Una rama sin PR requiere abrirla o ejecutar los cuatro workflows manualmente. Si una prueba falla, abre su trabajo y consulta el mensaje concreto, no solo el código de salida 65.

## Primera subida: metodo automatico

1. Instala **Git for Windows** si todavia no lo tienes.
2. Extrae por completo el ZIP del proyecto.
3. Haz doble clic en `SUBIR_A_GITHUB.bat`.
4. Introduce tu nombre y el correo que quieres asociar al commit si Git no los conoce.
5. Cuando GitHub lo solicite, inicia sesion en el navegador y autoriza Git Credential Manager.

El script crea una copia del repositorio en:

`Documentos\\Mi_Bombo_Money_repo`

Despues copia el proyecto, crea el primer commit y lo sube a la rama `main`.

## Primera subida: metodo manual con PowerShell o Git Bash

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
3. Selecciona **Validar app iOS**.
4. Pulsa **Run workflow** y selecciona la rama que quieres comprobar. Si la rama tiene una PR abierta y acabas de subir cambios, consulta primero esa ejecución automática para no repetirla.
5. Cuando termine correctamente, abre la ejecucion y descarga el artefacto `MiPatrimonio-iOS-Simulator`.
6. Dentro encontraras `MiPatrimonio-Simulator.zip`, preparado para una plataforma de simulacion web compatible con aplicaciones `.app` de iOS Simulator.
## Comprobaciones después de subir una rama

Actualizado el 5 de noviembre de 2026: abre una **pull request en borrador** para activar las comprobaciones automáticas de la rama. Cada push posterior actualiza la PR y ejecuta los cuatro workflows completos, sin duplicarlos mediante otro evento de push de rama. Después del merge se vuelve a validar `main`.

Si todavía no quieres abrir una PR, usa **Actions → Run workflow**, selecciona tu rama y ejecuta **Validar app iOS**, **Comprobar datos y cálculos**, **Comprobar conexión bancaria de prueba** y **Comprobar almacenamiento cloud**. Subir una rama sin PR ya no inicia las pruebas automáticamente. Los detalles y la validación del cambio están en [CI.md](CI.md).
