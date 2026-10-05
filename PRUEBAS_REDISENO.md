# Lista de pruebas del rediseño

## Inicio

- [ ] El botón azul aparece abajo a la derecha y no tapa la barra inferior.
- [ ] Se muestra un saludo según la hora en lugar del título `Inicio`.
- [ ] Las métricas mensuales y la tasa de ahorro se ven sin desplazamiento horizontal; la aportación a inversión aparece cuando corresponde.
- [ ] La tarjeta principal muestra patrimonio, variación mensual y fecha de actualización.
- [ ] Ocultar importes también oculta cifras y gráficos.
- [ ] Los avisos abren la pestaña adecuada.
- [ ] No hay lista de cuentas repetida en Inicio; el aviso de cuentas sin actualizar abre Cuentas.
- [ ] `Ver movimientos` abre Movimientos.
- [ ] `Ver detalle` y `Crear presupuestos` abren Presupuestos conservando el mes seleccionado en Inicio; cambiar el mes en Presupuestos mantiene el mismo mes al regresar a Inicio.
- [ ] El selector 3 M / 6 M / 1 A / Todo cambia el gráfico.
- [ ] La evolución termina en el mes actual aunque se consulte otro mes en el resumen mensual.
- [ ] Si hay movimientos o valoraciones con fecha futura dentro del mes, el último punto del gráfico patrimonial coincide con el patrimonio actual y no los incluye.
- [ ] Las tarjetas se distribuyen en columnas cuando caben y pasan a una columna al estrechar la ventana; el resumen mensual queda antes del gráfico en la lectura vertical.

## Movimientos

- [ ] El botón flotante abre el formulario de nuevo movimiento.
- [ ] No aparece un segundo botón `+` en la barra superior.
- [ ] Los filtros activos aparecen como chips y se pueden quitar individualmente.
- [ ] `Limpiar` elimina todos los filtros.
- [ ] La búsqueda sigue funcionando con los filtros.
- [ ] Deslizar a la izquierda permite eliminar; el detalle del movimiento permite editar.
- [ ] Los posibles duplicados se pueden revisar desde el aviso.
- [ ] `Análisis de gastos` muestra el gráfico y el detalle por categoría.

## Cuentas

- [ ] Cuentas muestra herramientas de gestión, sin otro resumen patrimonial.
- [ ] El selector Cuentas / Tarjetas funciona y la búsqueda encuentra nombres, bancos y cuentas vinculadas; en tarjetas también encuentra los últimos cuatro dígitos.
- [ ] Las cuentas se agrupan por día a día, ahorro, inversión, deudas y otras cuentas.
- [ ] `Actualizar un saldo o valoración` y la acción de deslizar abren el formulario para la cuenta elegida.
- [ ] El formulario de valoración muestra el saldo actual; cancelar no guarda cambios.
- [ ] En una cuenta con reservas se muestran el saldo y el disponible correctamente; las tarjetas no repiten ese saldo.
- [ ] Los accesos a reservas y cargos periódicos abren la pantalla correcta.
- [ ] Las cuentas antiguas muestran `Sin actualizar`.
- [ ] Revisar saldos sin actualizar filtra las cuentas; `Mostrar todas las cuentas` retira el filtro.
- [ ] Archivar una cuenta la mueve a `Elementos archivados`.
- [ ] Restaurar una cuenta o tarjeta vuelve a mostrarla en la lista principal.
- [ ] Añadir y editar cuentas y tarjetas sigue funcionando.

## Presupuestos

- [ ] El resumen global coincide con la suma de los presupuestos del mes.
- [ ] Las categorías superadas aparecen primero.
- [ ] Las categorías sin límite aparecen juntas en una tarjeta de iconos, con su nombre accesible mediante VoiceOver.
- [ ] Tocar un icono abre el editor de esa categoría. Tras guardar desaparece de la tarjeta y aparece en los presupuestos activos del mes.
- [ ] El punto naranja solo aparece si hay gasto sin presupuesto en la categoría.
- [ ] El gráfico compara gasto y límite únicamente de presupuestos activos; con más de seis se indica el recuento y se puede abrir la comparativa completa.
- [ ] Ocultar importes oculta también el gráfico de presupuestos.
- [ ] Cambiar de mes actualiza el gráfico y la tarjeta de categorías; los presupuestos repetidos y el sobrante mantienen sus cálculos.
- [ ] Tocar una categoría permite editar su límite.
- [ ] La pantalla de análisis compara presupuesto y gasto real.

## Ajustes

- [ ] Face ID o código sigue activándose y desactivándose.
- [ ] El tema automático, claro y oscuro funciona.
- [ ] La información de datos locales muestra los recuentos correctos.
- [ ] Privacidad y Ayuda se abren correctamente.
- [ ] Movimientos recurrentes conserva sus funciones anteriores.

## Revisión visual

- [ ] Probar en modo claro y oscuro.
- [ ] Probar con importes visibles y ocultos.
- [ ] Probar al menos en iPhone 14 Pro y en un iPhone más pequeño si Appetize lo permite.
- [ ] Probar en iPad vertical, horizontal y Split View, incluyendo una anchura estrecha.
- [ ] Comprobar que ningún importe se corta con cantidades grandes.
- [ ] Comprobar que las pantallas siguen siendo legibles con un tamaño de texto mayor.

## Diseño dinámico 0.2.10

- [ ] Cambiar continuamente el ancho de la ventana: las columnas se recalculan sin reiniciar la app y sin perder el mes, la búsqueda ni la categoría seleccionados.
- [ ] Repetir la prueba en horizontal, vertical y pantalla dividida; el mismo ancho disponible produce la misma disposición en cualquier dispositivo.
- [ ] Probar letra normal, grande y tamaños de accesibilidad: las tarjetas tienen menos columnas cuando la letra crece y las filas apilan descripción e importe cuando hace falta.
- [ ] Comprobar nombres de cuentas y categorías largos e importes grandes: los textos se pueden leer sin desplazamiento horizontal.
- [ ] El resumen y el gráfico de Presupuestos se colocan juntos cuando hay espacio y uno debajo del otro al reducirlo.
- [ ] El botón rápido respeta las barras de navegación y pestañas y el último movimiento queda accesible al desplazarse.

## Comprobaciones antes del merge

- [ ] Subir el commit a la rama de trabajo desde GitHub Desktop con `Push origin`.
- [ ] En Actions, `Validar app iOS` supera ambas compilaciones: Debug para simulador y Release para dispositivo.
- [ ] `Comprobar datos y cálculos` supera exportación/restauración y cálculos/aportaciones automáticas.
- [ ] Las comprobaciones corresponden al último commit que se va a integrar.
- [ ] Probar los cambios visuales en iPhone pequeño, iPad vertical/horizontal y ventana estrecha; la compilación automática no comprueba el aspecto en pantalla.
