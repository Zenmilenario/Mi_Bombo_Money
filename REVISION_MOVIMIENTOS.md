# Bandeja «Por revisar»

Actualizado: 30 de octubre de 2026.

## Estado y acceso

Primera versión implementada en el código local, pendiente de compilación y prueba en la app. En **Movimientos**, la tarjeta **Por revisar** permite alternar entre todos los movimientos de la selección y los que tienen incidencias. Se mantiene la búsqueda y los filtros de cuenta, categoría, tipo y periodo. También hay un control **Solo por revisar** dentro de Filtros, y se puede quitar desde el chip correspondiente.

## Qué se detecta

- Movimientos marcados como posibles duplicados por la detección existente.
- Ingresos, gastos, intereses o comisiones sin categoría.
- Una categoría de ingresos usada para un gasto, o cualquier otra incompatibilidad entre tipo y categoría.

No se considera incidencia una categoría archivada que era válida para un movimiento histórico. Una transferencia puede estar correctamente registrada sin categoría adicional. Una categoría general como Otros gastos no se considera automáticamente incorrecta: esta primera versión no dispone de una señal fiable de que el usuario quiera revisarla.

Se cuenta una vez cada movimiento aunque tenga dos incidencias. El estado vacío dice que no hay incidencias detectadas con la selección actual; no afirma que cada registro haya sido revisado por una persona.

## Acciones rápidas

Al abrir un movimiento pendiente, **Por revisar** permite:

1. Elegir una categoría compatible en un menú con sus iconos, sin recorrer todo el formulario del movimiento.
2. Aplicar una sugerencia de las reglas existentes, explicando qué regla coincide. Usar una regla que ya existe no crea otra más específica.
3. Dejar activado **Recordar esta elección** para que una categoría elegida manualmente cree o actualice una regla con esa descripción. Puede desactivarse para un caso puntual. No se solicita una frase nueva al usuario.
4. Comparar hasta tres movimientos similares mostrando concepto, cuenta/banco, tipo, fecha e importe. Los importes respetan el control de privacidad.
5. Pulsar **Conservar: no es un duplicado** para retirar la marca de sospecha. Conserva los registros; no elimina automáticamente ninguno. Si sobra uno, se puede eliminar desde la lista de Movimientos.

Los cambios se guardan en el contexto actual. En modo cloud usan la sincronización existente. Si el guardado falla, se revierte el cambio de revisión y se explica el error.

## Conservación de decisiones

El formulario solo vuelve a calcular la sospecha de duplicado cuando cambian sus datos relevantes: fecha, cuentas, tipo, importe o descripción normalizada. Cambiar una nota, la categoría o la reserva no debe reabrir una sospecha que el usuario ya descartó.

Se conserva el significado independiente de Conciliado. La revisión de categoría no usa ese indicador como sustituto ni lo modifica. No se cambian importes, cuentas, asignaciones de reserva o tipos al elegir una categoría; el gasto pasa a la categoría que el usuario ha elegido.

## Persistencia y compatibilidad

Se usan las relaciones de categoría, las reglas y el estado de duplicado existentes. No se añade un formato de copia, una columna, una tabla ni una migración. Estas decisiones siguen formando parte de las copias y de la sincronización actuales. La lista de incidencias se calcula al mostrar los movimientos y desaparece al resolver sus causas.

## Comprobaciones

- `Tests/TransactionReviewCheck.swift`: categorías ausentes/incompatibles, historial con categorías archivadas, transferencias sin categoría, combinación de incidencias, conservación de financiación reservada y persistencia de la decisión sobre duplicados al editar datos no relevantes.
- La rama que comprueba las huellas reales usa CryptoKit y se ejecuta en el nuevo paso del workflow **Comprobar datos y cálculos** en macOS.
- Localmente se ejecutaron las pruebas de lógica con las declaraciones de modelos sin macros de SwiftData. Se comprobó sintaxis Swift, referencias del proyecto, plist, YAML y `git diff --check`. No sustituye a compilar la interfaz con el SDK de iOS.
- Los checks verdes del commit anterior corresponden a sincronización. Esta bandeja todavía no ha sido subida ni validada por GitHub Actions o instalada en el iPad.

## Prueba manual de la próxima compilación

1. En un espacio de pruebas, comprobar un posible duplicado junto a un movimiento sin categoría y otro ya clasificado.
2. Activar Por revisar, combinar filtros y restablecerlos. No perder resultados por un filtro invisible.
3. Asignar una categoría compatible y comprobar que desaparece la incidencia; repetir con una regla sugerida y con Recordar desactivado.
4. Conservar un posible duplicado y comprobar que no cambia el saldo ni desaparece el otro registro. Editar después solo su nota o categoría: no debe volver a marcarse por eso.
5. Probar claro/oscuro, texto de accesibilidad y ocultación de importes. Verificar copia/restauración y sincronización de las decisiones.

La detección de parejas de transferencias y la limpieza automática de conceptos se mantienen como trabajo posterior; esta versión no cambia tipos financieros por similitud.
