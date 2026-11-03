# Mi Bombo Money — Grafito sereno

## Colores y atmósfera
Apariencia DARK. Base azul grafito #111D2B; tarjetas #203145; superficie secundaria #2B4056; texto principal #F3F7FC y secundario #C0CEDD. Primario turquesa #68CFD0 con texto de botón #102C30; borde #435A73. Ingresos #86EFAC sobre #193D32; gastos #FDA4AF sobre #452936; ahorro #93C5FD sobre #1B365B; inversión #D8B4FE sobre #3A2D54. Advertencia #FDE68A sobre #423B27. Usar superficies elevadas para separar niveles y evitar el negro puro y grandes zonas vacías. El contraste de cada combinación generada se verificará antes de implementarla.

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
