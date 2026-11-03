# Mi Bombo Money — Clara cercana

## Colores y atmósfera
Apariencia LIGHT. Base cálida #F7F5F0; tarjetas #FFFFFF; superficie secundaria #EEECE5; texto principal #172D2C y secundario #536661. Primario verde azulado #0F766E con texto de botón #FFFFFF; borde #D7DFDA. Ingresos #166534 sobre #DCFCE7; gastos #B42318 sobre #FEE4E2; ahorro #175CD3 sobre #E8F0FF; inversión #6941C6 sobre #F1EBFF. Advertencia #92400E sobre #FEF3C7. Estética editorial contemporánea, luminosa y sobria. Usar superficies para agrupar, evitando tarjetas enormes vacías. El contraste de cada combinación generada se verificará antes de implementarla.

## Propósito y plataforma
Aplicación de finanzas personales Mi Bombo Money para iOS y iPadOS. Transmitir calma, confianza y claridad, con información útil y acciones reconocibles. Propuestas visuales para trasladar a SwiftUI; los prototipos no acreditan el comportamiento de la app.

## Tipografía
Inter en las maquetas de Stitch como aproximación legible a la tipografía de sistema de iOS. Al implementar en SwiftUI, usar la tipografía del sistema con Dynamic Type, sin añadir esta fuente como dependencia. Títulos 28/34 y peso 650; patrimonio 36/42 y peso 700; sección 18/24 y peso 600; cuerpo 16/24 y peso 400; etiquetas 14/20 y peso 500. Importes con cifras tabulares.

## Forma y espacio
Tarjetas con radio 12; botones con radio 12; controles compactos con radio 8. Escala de espacio: 4, 8, 12, 16, 24 y 32. Área táctil mínima de 44 puntos. Contornos discretos y elevación leve. Los avisos conservan texto e icono además de color.

## Adaptación y jerarquía
Una columna en ventanas estrechas y columnas independientes cuando hay espacio suficiente. Navegación inferior reconocible en iPhone; navegación nativa accesible en iPad. Reorganizar según ancho y texto, incluyendo Split View, sin anchos fijos ni huecos impuestos por tarjetas vecinas. Mantener visibles Inicio, Movimientos, Cuentas, Presupuestos y Ajustes. La sincronización es un control compacto; nunca una banda encima de la navegación.

## Componentes
Resumen patrimonial con saldo, disponible, reservado e inversión claramente diferenciados. Métricas mensuales con icono, etiqueta, importe y superficie semántica. Presupuesto con progreso, gastado y disponible. Evolución con ejes y alternativa textual. Alertas revisadas compactas y desplegables. Botón claro para añadir un movimiento. Estado bancario separado del estado de sincronización cloud.

## Contenido y accesibilidad
Español de España y euros. Datos exclusivamente ficticios y coherentes; no incluir credenciales, nombres personales, IBAN ni movimientos reales. Etiquetas completas, texto grande, alto contraste y áreas seguras. El dinero reservado forma parte del patrimonio pero se excluye del disponible. Las transferencias propias y aportaciones a inversión no son gastos de consumo. La parte pagada con reservas se distingue del gasto para presupuesto, sin ocultar el gasto real.
