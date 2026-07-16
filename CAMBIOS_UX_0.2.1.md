# Ajustes UX 0.2.1

## Movimientos

- Pulsar un movimiento abre ahora una pantalla de detalle; ya no entra directamente en edición.
- La edición queda disponible mediante el icono de lápiz de la esquina superior derecha.
- El detalle muestra importe, tipo, fecha, cuenta, categoría, notas y posible duplicidad.
- En transferencias muestra claramente cuenta de origen y cuenta de destino.
- Se elimina la acción lateral de editar; se mantiene el gesto de eliminar.
- Se elimina la repetición visual de «Transferencia» en la fila. La lista conserva la descripción, la ruta entre cuentas, el importe y la hora.

## Objetivos

- Pulsar el objetivo destacado abre una ficha propia en vez de redirigir a Ajustes.
- La ficha muestra progreso, ahorrado, objetivo, importe restante, modo de seguimiento, cuenta vinculada, fecha y notas.
- Desde la esquina superior derecha se puede crear otro objetivo o editar el actual.
- La lista general de objetivos utiliza el mismo patrón: primero detalle y después edición voluntaria.

## Gráfico de patrimonio

- Se sustituye la interpolación Catmull-Rom por una curva monótona para evitar sobrepasos visuales.
- Se añade margen horizontal en los extremos.
- Se calcula un margen vertical dinámico para que la línea no toque ni parezca salir del marco.

## Versión

- Versión: 0.2.1
- Build: 3
