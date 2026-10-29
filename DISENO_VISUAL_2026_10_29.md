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
