# Rediseño de Mi Patrimonio

## Entrega 0.2.10

- Inicio sustituye el título por un saludo y concentra el resumen patrimonial. La lista de cuentas pasa a Cuentas y el interés anual sigue disponible en el detalle de cada cuenta.
- La disposición de las tarjetas calcula las columnas a partir del ancho propuesto por su contenedor. Su ancho mínimo escala con Dynamic Type y las filas usan una disposición vertical cuando su contenido no cabe. Los tamaños de accesibilidad usan una columna. Se aplica a Inicio, métricas y resumen con gráfico de Presupuestos; las listas de Cuentas conservan un ancho legible y adaptan sus filas.
- Cuentas pasa a ser una pantalla de gestión, con búsqueda, separación entre cuentas y tarjetas, grupos por uso, actualización directa de saldo o valoración y accesos a reservas y periódicos.
- Presupuestos agrupa las categorías sin límite en una tarjeta de iconos y añade una comparativa de gasto y límite para los seis presupuestos con mayor uso. Conserva la comparativa completa y los editores actuales.
- El botón rápido usa el área segura de cada pestaña para respetar automáticamente barras inferiores o superiores. Las alturas de los gráficos escalan con la letra.
- La revisión local de esta entrega comprueba la sintaxis con tree-sitter y el formato del diff. La compilación iOS y la revisión visual quedan pendientes de Xcode o del workflow de compilación.

## Historial: entrega 0.2.0

Este paquete aplica un rediseño conservador: mantiene el modelo de datos, los cálculos financieros, SwiftData y los formularios existentes, pero reorganiza la interfaz para que sea más clara, consistente y fácil de usar.

## Alcance de la entrega

El rediseño modifica únicamente presentación, navegación y componentes de interfaz. Mantiene intactos el esquema SwiftData, los cálculos, las transferencias internas, la importación CSV y los datos iniciales del Excel.

## Cambios principales

### Inicio

- Tarjeta principal de patrimonio con variación del mes y fecha real de actualización.
- Resumen mensual fijo en una cuadrícula 2 × 2; ya no hay métricas ocultas en un carrusel horizontal.
- Avisos redactados de forma natural, ordenados por prioridad y con acceso a la sección correspondiente.
- Resumen de cuentas limitado a las más importantes, con aviso de saldos sin actualizar.
- Tarjeta global de presupuesto con gasto, disponible, porcentaje y ritmo mensual.
- Un único gráfico principal de patrimonio con selector de 3 meses, 6 meses, 1 año o todo el historial.
- Un objetivo de ahorro destacado en lugar de mostrar todos a la vez.
- Los gráficos detallados de gastos y presupuestos se han trasladado a sus pestañas correspondientes.

### Navegación y botón rápido

- El botón azul para añadir movimientos se sitúa abajo a la derecha.
- Solo aparece en Inicio y Movimientos.
- Se elimina el botón `+` redundante de la barra superior de Movimientos.
- Se conserva el botón específico de Cuentas para añadir cuentas o tarjetas.

### Movimientos

- Resumen del periodo filtrado: ingresos, gastos y balance.
- Chips visibles para todos los filtros activos.
- Botón para limpiar filtros.
- Acceso directo a posibles movimientos duplicados.
- Acción de deslizar para editar o eliminar.
- Transferencias identificadas claramente y sin tratarlas como ingreso o gasto.
- Nueva pantalla de análisis de gastos por categoría.

### Cuentas

- Resumen superior con activos, deudas y patrimonio neto.
- Indicador de cuentas que llevan más de 30 días sin actualizarse.
- Fecha de última actualización visible en cada cuenta.
- Las cuentas y tarjetas archivadas se mueven a una pantalla separada.
- Se mantiene el detalle de cuenta, los movimientos recientes y las valoraciones.

### Presupuestos

- Resumen global con total presupuestado, gastado, disponible y ritmo previsto.
- Aviso de gasto realizado en categorías sin presupuesto.
- Categorías ordenadas por prioridad: necesitan atención, dentro del presupuesto y sin presupuesto.
- Nueva pantalla de análisis con gráfico de presupuesto frente a gasto real.

### Ajustes

- Secciones simplificadas: Seguridad, Apariencia, Datos, Organización e Información.
- Se elimina terminología técnica de la pantalla principal.
- Nueva explicación comprensible de privacidad y almacenamiento local.
- Nueva pantalla de ayuda con los conceptos principales de la aplicación.
- `Periódicos` pasa a llamarse `Movimientos recurrentes`.

### Sistema visual y accesibilidad

- Color principal unificado azul verdoso.
- Radios, fondos y espaciados consistentes.
- Componentes compartidos para tarjetas, métricas, estados y filtros.
- Colores verde, rojo y naranja reservados para significados financieros.
- Gráficos con descripciones de accesibilidad.
- Compatible con modo claro, modo oscuro y tamaños dinámicos de texto.

## Archivos Swift modificados

- `MiPatrimonio/App/LockGateView.swift`
- `MiPatrimonio/App/RootTabView.swift`
- `MiPatrimonio/Shared/ReusableViews.swift`
- `MiPatrimonio/Features/Dashboard/DashboardView.swift`
- `MiPatrimonio/Features/Transactions/TransactionsView.swift`
- `MiPatrimonio/Features/Accounts/AccountsView.swift`
- `MiPatrimonio/Features/Budgets/BudgetsView.swift`
- `MiPatrimonio/Features/Settings/SettingsView.swift`
- `MiPatrimonio/Features/Management/RecurringMovementsView.swift`

## Validación realizada

- Los 26 archivos Swift pasan el análisis sintáctico conjunto con Swift 6.2.
- `swift-format lint` no ha detectado errores.
- No se han añadido nuevos archivos Swift, por lo que no es necesario modificar el proyecto de Xcode.
- El modelo de datos, la persistencia y las reglas de cálculo no se han alterado.

La compilación definitiva para iOS debe confirmarse mediante el workflow de GitHub Actions después de subir el cambio.
