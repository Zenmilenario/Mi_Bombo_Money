# Mejora visual y navegación — 29 de octubre de 2026

## Problema observado

La captura del usuario muestra una franja de sincronización por encima del `TabView` que cubre la navegación de iPadOS. La pantalla de inicio combina negro puro con tarjetas de alturas distintas dentro de filas compartidas: la tarjeta más alta obliga a dejar un hueco debajo de su vecina. Cuatro métricas pueden terminar en una distribución 3+1 y truncar el título de inversión.

## Cambios implementados

- Se elimina el `safeAreaInset` superior del contenedor cloud. Cada una de las cinco pantallas principales tiene un botón de nube dentro de su barra de herramientas nativa. Muestra actividad o advertencia, y abre el estado completo en una hoja con botón Cerrar. Sus símbolos solo indican sincronización completa cuando el estado es «Al día». El modo local y las pruebas bancarias no crean este control ni requieren un coordinador cloud.
- Base azul grafito (`#111D2B`) en oscuro; tarjetas (`#203145`) y superficies secundarias (`#2B4056`). En claro, fondo gris azulado y tarjetas blancas. Los colores se resuelven según la apariencia de iOS y distinguen superficies elevadas, como las hojas.
- Tarjetas compartidas con contorno discreto que no captura pulsaciones; el contorno usa el separador del sistema si se activa Aumentar contraste. Enlaces más claros en oscuro. Los botones rellenos conservan su fondo más oscuro para mantener legible el texto blanco.
- Inicio usa columnas independientes, calculadas a partir del ancho propuesto y del tamaño de texto. Presupuesto puede situarse inmediatamente bajo patrimonio sin esperar a la altura de la tarjeta mensual. En poco espacio o con tamaños de accesibilidad se vuelve a una columna, conservando el orden de lectura: patrimonio, resumen mensual, presupuesto, evolución y objetivo si existe.
- Cuatro métricas: dos columnas como máximo; una si no cabe. Se mantienen los colores por función, ahora con tonos adaptados al claro/oscuro. Los avisos revisados ocupan una fila compacta y siguen siendo desplegables.
- Se retiran los límites de ancho máximo de Inicio y Presupuestos. Los formularios y detalles conservan sus medidas de lectura; las pantallas principales aprovechan el ancho disponible.
- Los fondos de las listas principales dejan ver el nuevo fondo de la app. No se cambian importes, fórmulas, reservas, sincronización ni almacenamiento.

## Referencias y criterio de diseño

Las [guías de pestañas de Apple](https://developer.apple.com/design/human-interface-guidelines/tab-bars) recomiendan mantener accesible la navegación principal y reservar la barra de herramientas para acciones. Las [guías de modo oscuro](https://developer.apple.com/design/human-interface-guidelines/dark-mode) describen la separación entre superficies base y elevadas y la necesidad de comprobar legibilidad y accesibilidad en ambas apariencias.

También se revisaron el [inicio de YNAB](https://support.ynab.com/spotlight-BkdHBZUokg), que reúne prioridades, objetivos y resumen mensual, y los [resúmenes de Monzo](https://monzo.com/help/budgeting-overdrafts-savings/trends-spending-and-balance-web), que distinguen gasto, saldo y objetivos. La decisión para esta app es mantener pocas tarjetas reconocibles, jerarquía por tamaño y color por significado. Estas referencias no constituyen una prueba de preferencias de nuestros usuarios; la aceptación se comprobará con el uso de la app.

## Comprobaciones realizadas y límites

- Revisión de la maqueta HTML en el navegador, en oscuro y claro, y con ventana estrecha. Sin desbordamiento horizontal en la revisión estrecha. La maqueta usa exclusivamente datos ficticios y está identificada como tal; no es una captura de la app iOS ni verifica su navegación nativa.
- Cálculo del contraste de las cuatro etiquetas semánticas sobre la mezcla más intensa de sus tarjetas, en ambas apariencias: mínimo 5,42:1. El texto blanco del botón principal también supera 4,5:1. Este cálculo no certifica el contraste de todos los estados o controles de la app.
- Comprobación del algoritmo real `AdaptiveCardLayout`, extraído sin modificarlo y ejecutado en Swift con medidas de vistas simuladas: 264 combinaciones de ancho, cantidad de columnas, contenido vacío y alturas distintas, sin solapamiento ni desbordamiento; se comprueba que cada columna continúa tras su propia tarjeta. No sustituye a medir las vistas reales de SwiftUI.
- Análisis de sintaxis de los archivos Swift modificados, revisión de referencias Xcode y `git diff --check`.
- La compilación y la interacción real siguen pendientes de los checks macOS de GitHub y de una instalación en dispositivos. Windows no dispone del SDK de iOS. No se han ejecutado ni anunciado como correctas pruebas nuevas de Xcode.

## Revisión en dispositivos antes del merge

1. Ejecutar los workflows en la rama y esperar a los resultados del último commit.
2. En una ventana ancha, comprobar que las cinco pestañas reciben pulsaciones mientras la nube está al día, sincronizando, sin conexión y con conflictos.
3. Abrir la nube, cerrar su hoja, cambiar de pestaña, entrar en un detalle y volver atrás. Comprobar también modo local y banco de pruebas, sin control cloud.
4. Redimensionar la ventana y usar Split View; revisar iPhone en vertical/horizontal. Probar tres métricas, cuatro métricas y ausencia de objetivos o cuentas.
5. Probar texto grande y tamaños de accesibilidad, claro/oscuro, Aumentar contraste, Reducir transparencia y VoiceOver. No perder las etiquetas, los avisos revisados ni los botones de ocultación de importes.

## Artefactos locales de diseño

La maqueta y sus imágenes están en `build/visual-refresh/`, excluido de Git. `index.html` permite alternar claro/oscuro; `oscuro.png`, `claro.png` y `estrecho.png` documentan la dirección visual. Son referencias ilustrativas, no resultados del simulador. El HTML usa iconos de texto de muestra; la app mantiene SF Symbols y controles nativos.

## Evolución del 3 de noviembre de 2026 · 0.6.3

### Decisión del usuario

El usuario elige Grafito sereno como referencia principal tras comparar las cuatro propuestas de Stitch. Se mantienen Claro, Oscuro y Automático en Ajustes → Apariencia → Tema; no se reemplaza la elección guardada por una preferencia impuesta. Las capturas y documentos de estilo se conservan en `.stitch/`, con copia documental y visual en Obsidian.

### Implementado en la carpeta

- Inicio: bloques separados y reconocibles para Disponible y Reservado. El primero abre las cuentas y el segundo la gestión de reservas. Importes con cifras tabulares y título patrimonial que respeta el tamaño de texto del sistema. Acción Añadir movimiento en la barra superior, sin el hueco del botón flotante inferior de Inicio. Las cifras y las fórmulas son las existentes, sin datos de la maqueta ni nuevos cálculos de inversión.
- Navegación: estilo nativo `sidebarAdaptable` desde iOS/iPadOS 18, con posibilidad de alternar barra y lateral en iPad y barra inferior en iPhone. Se conserva el estilo disponible en iOS 17. No se fuerzan anchos por modelo de dispositivo. [Referencia de Apple](https://developer.apple.com/documentation/swiftui/tabviewstyle/sidebaradaptable).
- Paleta: base grafito y tarjetas azul grisáceo en oscuro, acento turquesa; en claro, base cálida y acento verde azulado. Los botones rellenos con texto blanco conservan un fondo más oscuro para legibilidad. Los iconos de entidades usan el color elegido cuando contrasta con la tarjeta; si no alcanza 3:1, se dibujan con el color semántico del sistema. El color guardado en la entidad no cambia.
- Cuentas y Movimientos: filas principales sobre la superficie de tarjeta común. Los nombres de cuentas pueden ocupar varias líneas y «Sin actualizar» pasa a una línea propia, evitando recortes por la insignia.
- Medición de filas: el componente compartido de etiqueta/valor sustituye `ViewThatFits` por un `Layout` que mide siempre los hijos sin altura propuesta. La altura de una fila depende del contenido, no de la altura que proponga List. Cuando no caben ambos bloques o se usa texto de accesibilidad, el importe/acción pasa debajo. Una acción vacía no reserva separación vertical. Se evita fijar alturas por dispositivo.
- Revisión: con cero incidencias, la tarjeta muestra Todo revisado y su contexto, sin botón ni flecha que activen un filtro vacío. Con pendientes, abre el filtro correspondiente; si se resuelve la última incidencia estando dentro del filtro, se conserva Ver todos para salir. El contador sigue respetando búsqueda y filtros. Esta revisión se refiere a movimientos registrados; la conciliación bancaria pendiente de incorporación continúa en Mis bancos.

### Verificación realizada y límites

- 576 combinaciones de geometría del `AdaptiveValueLayout` real extraído del código: anchuras de 160 a 1194, alturas propuestas de 0 a 100.000, texto que envuelve, tamaños de accesibilidad, acción vacía, contención y ausencia de solapamientos. Una fila corta de cuenta conserva 66 puntos de altura aunque el contenedor proponga 10.000. Los subviews son simulados; no acreditan el renderizado del SDK de SwiftUI.
- El check de revisión pasa localmente con modelos sin macros de SwiftData, incluidos cero pendientes, apertura de pendientes, salida con la última incidencia resuelta y conservación de reservas al corregir categorías. El workflow macOS mantiene la prueba sobre los modelos reales.
- Análisis sintáctico Swift de los archivos modificados. Validación del proyecto Xcode, del workflow y de espacios en Git.
- La prueba de geometría queda incluida en el workflow Comprobar datos y cálculos. No se han publicado cambios ni ejecutado las compilaciones iOS de 0.6.3 en este ordenador Windows.

### Pendiente de UX

Comprobar el IPA 0.6.3 en el dispositivo: altura de filas en Cuentas y Movimientos; cero pendientes sin navegación vacía; resolución de la última incidencia y salida; temas Claro/Oscuro/Automático; navegación lateral; ventanas estrechas, Split View y texto grande. Continuar el diseño de las demás pantallas con la referencia elegida. Esta es una primera adaptación de Inicio y componentes, no un traslado completo de todas las maquetas.

### Pendiente después del UX: inversión y reinversión

El usuario solicita revisar la representación de la cuenta de reinversión después de completar el UX. Se estudiará cómo distinguir efectivo de un bróker, posiciones o cuenta de valores, aportaciones, rendimientos y valoraciones, así como su inclusión en el patrimonio, para evitar duplicidades o conceptos confusos. No se han cambiado tipos de cuenta, saldos, valoraciones, reservas ni movimientos personales como parte de esta revisión visual. Antes de implementar ese modelo se concretará el comportamiento con el usuario.

## Ajustes · 0.6.4

La revisión de Ajustes mantiene la dirección elegida y reduce pantallas intermedias, separa la conexión personal del laboratorio y añade búsqueda con secciones desplegables. Incluye lo preparado en 0.6.3. [Mapa actualizado y validación pendiente](AJUSTES.md).

## Corrección del check macOS · 3 de noviembre de 2026

En el commit `c83c917` de la PR 23 fallan los jobs de cálculos de push y pull_request, ambos en Comprobar filas adaptables sin espacios vacíos. Los pasos de cálculos financieros y bandeja de revisión terminan correctamente; los otros diez checks, incluidas las compilaciones Debug y Release, figuran aprobados.

Los dos registros muestran que el ejecutable de prueba no encuentra `CGRect.zero`, `CGSize.zero`, los límites de CGRect ni la igualdad de CGSize. La plantilla Swift de `Tests/check_adaptive_layout.py` importaba únicamente Foundation. Se añade `import CoreGraphics` condicionado a `canImport(CoreGraphics)` para cargar las extensiones del SDK Apple y conservar la ejecución de Foundation en Linux. No se modifica el layout de la app, los cálculos financieros ni las aserciones de la prueba.

Verificación: las 576 combinaciones vuelven a pasar localmente en Linux y `git diff --check` no informa problemas. La corrección de importación debe publicarse y volver a ejecutarse en macOS para confirmar el resultado; todavía no existe un check remoto de esta corrección. Se mantiene la versión 0.6.4, porque el cambio solo corrige la prueba.

Registros revisados: [pull_request](https://github.com/Zenmilenario/Mi_Bombo_Money/actions/runs/41636047831/job/125917406014?pr=23) y [push](https://github.com/Zenmilenario/Mi_Bombo_Money/actions/runs/41635998853/job/125917233069?pr=23).

## Movimientos con el sistema Stitch · 0.6.23

Preparado el 9 de noviembre de 2026 a petición del usuario («lavado de cara»), extendiendo a Movimientos el sistema elegido el 3 de noviembre (Grafito sereno en oscuro, Clara cercana en claro; `.stitch/oscuro/DESIGN.md`). El usuario observó en el iPad tarjetas y filas demasiado grandes, conceptos bancarios en mayúsculas y un formulario de edición con un hueco enorme.

**Implementado.**
- **Medidas del sistema.** Radio de tarjeta 14 (antes 18), compacto 10 y destacado 20; separación entre secciones 18. Nuevas superficies semánticas de Stitch: ingresos, gastos, ahorro y aviso, en claro y oscuro.
- **Ancho de lectura en iPad.** Movimientos, Cuentas y Ajustes centran su lista en 760 puntos cuando la ventana es más ancha; en iPhone conservan el margen de 16. Presupuestos e Inicio mantienen el ancho completo decidido el 29 de octubre.
- **Resumen de Movimientos.** Tres métricas compactas sobre superficie semántica (ingresos, gastos y balance) en una fila; pasan a columna si no caben.
- **Filas.** Icono de categoría sobre un cuadrado redondeado de su color, título legible, cuenta en una línea e importe con cifras tabulares. Ingresos en verde y transferencias en azul del sistema; los gastos siguen en el color de texto para no llenar la lista de rojo.
- **Títulos legibles** (solo presentación): los conceptos bancarios en mayúsculas pasan a mayúsculas iniciales («Comercio del Norte, S.L.»), los recibos SEPA muestran «Recibo · acreedor» sin la referencia del mandato y las retiradas en cajero se titulan «Retirada de efectivo». Reglas, aprendizaje, conciliación y búsqueda siguen usando el texto original.
- **Cabeceras de día** sin el año en curso y con el resultado neto del día.
- **Formularios en iPad**: el alta, la edición y el detalle de un movimiento se abren como hoja de formulario centrada (iPadOS 18 o posterior). La fila Categoría se dibuja como una fila simple: era la que crecía hasta dejar el hueco de la captura.

**Verificación.** Pruebas con datos ficticios de los títulos legibles en `FinancialLogicCheck`. La apariencia no se puede comprobar sin compilar en macOS: pendientes los checks, el IPA y la revisión en el iPad (claro, oscuro, texto grande, Split View).

## Doblón 0.7.0 (41) · lote 1 del rediseño «Pulso»

Preparado el 9 de noviembre de 2026, después de que el usuario rechazara la 0.6.23 y aprobara la propuesta «Pulso» y el nombre «Doblón». La versión pasa a 0.7 a petición del usuario, por el cambio de nombre y de diseño. Este primer lote pone la base visual y corrige los fallos observados en la 0.6.23; la navegación nueva, Inicio, Movimientos en dos paneles, Cuentas, Ajustes, el acceso y el compañero Don Bigotes llegarán en lotes posteriores.

**Implementado.**
- **Nombre visible «Doblón»:** bajo el icono (`CFBundleDisplayName`), en el acceso, en Mi nube, en el pie de Ajustes y en los avisos. El identificador del paquete, los esquemas de URL, el proyecto y el repositorio no cambian, para no romper la instalación, la sincronización ni el retorno de los bancos. El icono del perro se mantiene.
- **Paleta «Pulso»:** un único juego de colores para claro y otro para oscuro (fondo, tarjetas, superficie secundaria, acento, ingresos, gastos, ahorro, inversión y aviso).
- **Fondos de fila iguales:** en Ajustes y Movimientos, todas las filas (selectores, interruptores, grupos desplegables y accesos) usan el color de tarjeta. Antes algunas se quedaban con el gris del sistema y el modo oscuro se veía desigual.
- **Sin ancho fijo:** se retira el ancho de lectura de 760 puntos de la 0.6.23, que dejaba huecos; Cuentas recupera su margen de 16 puntos.
- **Tarjeta «Por revisar» compacta:** fila simple que nunca crece más que su contenido.
- **Resumen del mes:** sin periodo elegido, el resumen de Movimientos muestra el mes actual, con su nombre como título, en lugar de todo el historial.
- **Retenidos legibles:** a los conceptos en bruto («/TXT/COMERCIO 09/11/26|referencia») se les quitan la marca, la fecha pegada y la referencia.

**Verificación.** Prueba de títulos con datos ficticios en `FinancialLogicCheck`. Sin compilador Swift en el equipo: pendientes los checks, el IPA y la revisión en el iPad (claro y oscuro).
