# Ajustes: navegación simplificada · 0.6.4

Actualizado: 3 de noviembre de 2026.

## Implementado en la carpeta

La pantalla agrupa las opciones por tarea y dispone de búsqueda. Los desplegables se abren en la misma página; no son pantallas intermedias. Cada enlace lleva directamente a la función correspondiente.

| Grupo | Accesos |
| --- | --- |
| Cuenta y bancos | Mi nube / Activar mi nube; Mis bancos |
| Organiza tus finanzas | Categorías; Categorización automática; Cargos y aportaciones periódicas |
| Más herramientas, desplegable en Organización | Bancos y entidades de la app; Objetivos de ahorro; Dinero reservado |
| A tu gusto | Tema Claro/Oscuro/Automático; Ocultar importes; Seguridad y desbloqueo desplegable |
| Copias e importación | Exportar o restaurar copia; Importar movimientos CSV |
| Opciones avanzadas, desplegable | Resumen de datos del espacio abierto; Laboratorio bancario; eliminación confirmada de datos |
| Ayuda y privacidad, desplegable | Cómo usar la app; Privacidad; versión en el pie |

La búsqueda compara palabras sin distinguir mayúsculas ni acentos y permite escribirlas en distinto orden. Abre automáticamente los desplegables que contienen resultados, conservando el estado elegido al limpiar la búsqueda. Sin coincidencias muestra un estado explícito. Incluye términos habituales como reglas, reservas, metas, copia cifrada, versión o pruebas.

## Menos pasos y opciones obsoletas

- Mis bancos abre directamente la conexión personal cuando se usa la nube. También se beneficia el acceso Conectar banco desde Cuentas. Ya no se entra antes en la configuración de demostración/sandbox.
- En modo local, Mis bancos explica que hace falta activar la cuenta cloud para incorporar las cuentas reales. La activación sigue el flujo existente; no copia ni migra datos sin pasar por él.
- El Laboratorio conserva la demostración y sandbox y se encuentra solo en Opciones avanzadas. No inicia tareas ni consulta sus credenciales al abrir Mis bancos personales.
- Se elimina la fila de Excel marcada Próximamente, porque todavía no importa archivos. Se retira la moneda fija como supuesto ajuste editable; la aplicación sigue usando EUR.
- El resumen local se muestra dentro del desplegable de Avanzado, sin otra pantalla. Los objetivos, reservas, instituciones y reglas continúan accesibles; no se han eliminado esas funciones.
- Se diferencia Usuario y contraseña local, que desbloquea la app en el dispositivo, de Mi nube. No se cambian mecanismos de autenticación ni credenciales existentes.
- Privacidad y Ayuda reflejan la conexión real de consulta ya implementada, el espacio de pruebas separado y el acceso actual a añadir movimientos. Se retira la afirmación antigua de que las cuentas reales seguían bloqueadas.
- En Copias se simplifican los textos técnicos. La protección con contraseña permanece activada de forma predeterminada y los formatos y algoritmos no cambian.

## Contextos y acciones sensibles

En el espacio de pruebas no se muestran los accesos a cuenta cloud, conexión personal, copias/importación personal ni otro laboratorio anidado. El acceso bancario rechaza el espacio de prueba incluso si hereda la marca cloud del contenedor. En local no se abre el cliente personal sin activar la nube.

Eliminar datos permanece en Avanzado, con una confirmación explícita y explicación del alcance. En nube indica que la eliminación se sincroniza con los otros dispositivos; en pruebas señala que afecta al espacio de prueba. No se han ejecutado eliminaciones, importaciones, cambios de contraseña, revocaciones ni migraciones para verificar esta entrega.

## Verificación realizada

- Check Swift de seguridad bancaria aprobado, con ocho combinaciones del nuevo destino de entrada (local/nube, espacio de prueba y entrada de laboratorio), además de las comprobaciones de autenticación y dominios existentes. Esta cobertura se ejecuta también en el workflow bancario existente.
- Comprobación local de la búsqueda ejecutando el enum y funciones reales extraídos de Ajustes, sin SwiftUI: catorce destinos, alias, acentos, orden de palabras, cero resultados y nueve destinos permitidos dentro del espacio de prueba.
- Análisis sintáctico de los archivos Swift modificados, revisión del proyecto y de espacios en Git. La 0.6.4 incluye las mejoras de UX 0.6.3 todavía pendientes de publicar.

## Pendiente de validar

Compilación nativa Debug/Release en los checks macOS tras publicar, e instalación en iPad/iPhone para revisar búsqueda, desplegables, vuelta desde los formularios, texto grande y las dos apariencias. Las pruebas locales no acreditan el renderizado de SwiftUI. No se añade una capa de menús para distribuir las opciones en otras páginas.

La revisión financiera de inversión/reinversión sigue pendiente para después del UX y no forma parte de este cambio de Ajustes.

## Resultado inicial de GitHub Actions

Las compilaciones iOS Debug/Release del commit `c83c917` están aprobadas. El job de cálculos falla solo en el nuevo ejecutable de prueba geométrica por una importación CoreGraphics ausente en macOS; el ajuste local mantiene todas las aserciones y necesita un nuevo push para validarse remotamente. Cálculos financieros, revisión de movimientos y checks de acceso bancario están aprobados en ese commit. Detalle y enlaces en [Diseño visual](DISENO_VISUAL_2026_10_29.md#corrección-del-check-macos--3-de-noviembre-de-2026).
