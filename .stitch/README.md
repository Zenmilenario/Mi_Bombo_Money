# Propuestas de Inicio con Stitch

Estado: propuestas visuales generadas y revisadas el 3 de noviembre de 2026. El usuario ha elegido la oscura como referencia y solicita conservar ambas apariencias. La primera adaptación SwiftUI está preparada en la 0.6.3; quedan checks macOS, revisión física y el resto del UX. Los cálculos y los datos personales no cambian por esta entrega.

## Archivos

- `claro/DESIGN.md`: sistema Clara cercana, aprobado para explorar.
- `oscuro/DESIGN.md`: sistema Grafito sereno, aprobado para explorar.
- `metadata.json`: proyectos privados, sistemas visuales y pantallas finales de Stitch.
- `designs/claro-iphone.png` y `designs/claro-ipad.png`: imágenes de la propuesta clara.
- `designs/oscuro-iphone.png` y `designs/oscuro-ipad.png`: imágenes de la propuesta oscura.
- Los archivos HTML de igual nombre son las referencias exportadas por Stitch, no código de la aplicación iOS. Pueden depender de fuentes y recursos web externos.

## Revisión realizada

Se han revisado las cuatro capturas. Se han corregido inversión duplicada, rentabilidades añadidas, etiquetas recortadas, cabecera móvil y contraste de iconos. Todas las cifras son ficticias: patrimonio 12.500 €, efectivo 7.500 €, inversión 5.000 €, disponible 3.400 € y reservado 4.100 €. El mes de ejemplo presenta ingresos 2.400 €, gastos totales 1.500 €, ahorro neto 900 € y aportación a inversión 300 €. El gasto para presupuesto es 1.050 € y el pago con reservas 450 €; el presupuesto de 1.600 € deja 550 € disponibles. El 66 % es un redondeo del consumo presupuestario.

La revisión es visual, no una auditoría de accesibilidad. Las pantallas de iPhone e iPad son maquetas separadas: no prueban el comportamiento dinámico de SwiftUI. Al implementar habrá que unificar las reglas para anchos intermedios, Split View, texto grande, VoiceOver, contraste y áreas seguras. También se simplificará la microcopia para evitar textos explicativos excesivos. El radio y los colores extraídos por Stitch se consideran referencias; se comprobarán contra los documentos aprobados al trasladarlos.

## Siguiente decisión

Decisión del usuario: usar la oscura como referencia, manteniendo también la clara y el modo automático del sistema. Después diseñar Movimientos, Cuentas, Presupuestos, conciliación y formularios con ese sistema. El alcance de esta entrega es Inicio.

## Herramientas y privacidad

Se utilizaron `stitch::generate-design`, `stitch::manage-design-system` y `stitch::upload-to-stitch`. El propietario autorizó subir los dos documentos de estilo y generar ambas propuestas. Los proyectos se crearon privados. Solo se enviaron reglas de diseño y datos ficticios; las credenciales permanecen en la configuración privada local de Codex, fuera del repositorio y de esta documentación.
