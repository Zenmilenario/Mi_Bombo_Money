# Mi Bombo Money

Mi Bombo Money es una aplicación de finanzas personales para iPhone desarrollada con SwiftUI. Permite consultar el patrimonio total, controlar el saldo de distintas cuentas y revisar ingresos, gastos, presupuestos y objetivos de ahorro desde una única aplicación.

La información se guarda de forma local en el dispositivo. La aplicación no solicita ni almacena contraseñas bancarias.

## Funcionalidades

- Consulta del patrimonio total y del saldo de cada cuenta.
- Gestión de cuentas bancarias, efectivo, tarjetas, ahorro e inversiones.
- Registro de ingresos, gastos, intereses, comisiones y transferencias internas.
- Transferencias entre cuentas propias sin contabilizarlas como ingresos o gastos.
- Categorías configurables para organizar los movimientos.
- Presupuestos mensuales por categoría.
- Resumen mensual de ingresos, gastos, ahorro neto y tasa de ahorro.
- Evolución histórica del patrimonio.
- Análisis de gastos por categoría.
- Comparación entre presupuesto y gasto real.
- Objetivos de ahorro con seguimiento de progreso.
- Movimientos recurrentes y suscripciones.
- Búsqueda y filtrado por fecha, cuenta, categoría y tipo.
- Detección de posibles movimientos duplicados.
- Importación de movimientos desde archivos CSV.
- Ocultación de importes para mejorar la privacidad.
- Modo claro, oscuro y automático.

## Pantallas principales

La aplicación se organiza en cinco apartados:

- **Inicio:** patrimonio, resumen mensual, cuentas, presupuestos, avisos y objetivos.
- **Movimientos:** listado, filtros, análisis y detalle de cada operación.
- **Cuentas:** gestión de cuentas, tarjetas, saldos, intereses y valoraciones.
- **Presupuestos:** seguimiento mensual por categoría y comparación con el gasto real.
- **Ajustes:** seguridad, apariencia, importación de datos y organización general.

## Tecnologías

- Swift
- SwiftUI
- SwiftData
- Swift Charts
- LocalAuthentication
- Keychain Services

El proyecto no utiliza dependencias externas.

## Requisitos

- Xcode 16 o posterior.
- iOS 17 o posterior.
- macOS para compilar y ejecutar el proyecto con Xcode.

## Ejecución en Xcode

1. Clona o descarga el repositorio.
2. Abre `MiPatrimonio.xcodeproj`.
3. Selecciona el target `MiPatrimonio`.
4. En **Signing & Capabilities**, selecciona tu equipo de desarrollo.
5. Elige un simulador o un iPhone conectado.
6. Pulsa **Run**.

Para instalar la aplicación en un iPhone físico es necesario activar el modo desarrollador en el dispositivo y configurar la firma en Xcode.

## Pruebas desde Windows

El repositorio incluye un flujo de GitHub Actions que compila la aplicación para iOS Simulator:

```text
.github/workflows/build-ios-simulator.yml
```

Después de cada subida a la rama `main`, GitHub genera un artefacto llamado:

```text
MiPatrimonio-iOS-Simulator
```

La compilación resultante puede ejecutarse en un simulador remoto compatible, como Appetize. Este paquete está preparado para simulador y no puede instalarse directamente en un iPhone físico.

## Importación de movimientos

La aplicación permite importar movimientos desde archivos CSV. Antes de guardar los datos se muestra una vista previa para revisar las filas detectadas y descartar posibles duplicados.

En la carpeta `Samples` se incluyen dos archivos de referencia:

- `plantilla_csv_minima.csv`
- `ejemplo_importacion.csv`

La importación directa de archivos Excel y la sincronización automática mediante PSD2 u Open Banking no están incluidas actualmente.

## Seguridad y privacidad

- Los datos financieros se almacenan localmente mediante SwiftData.
- La aplicación puede protegerse con Face ID, Touch ID o el código del dispositivo.
- El acceso a información sensible utiliza Keychain cuando corresponde.
- La aplicación se bloquea al pasar a segundo plano.
- No se guardan usuarios, contraseñas, PIN, CVV ni números completos de tarjeta.
- La sincronización con CloudKit está desactivada.

La eliminación de la aplicación también elimina los datos guardados localmente. Conviene utilizar datos de prueba mientras no exista un sistema de copia de seguridad y restauración estable.

## Estructura del proyecto

```text
MiPatrimonio/
├── App/                 Inicio de la aplicación y navegación
├── Core/
│   ├── Models/          Modelos de SwiftData
│   ├── Persistence/     Configuración del almacenamiento local
│   ├── Security/        Biometría y Keychain
│   ├── Seed/            Datos iniciales
│   └── Services/        Cálculos, importación y duplicados
├── Features/            Pantallas agrupadas por funcionalidad
├── Shared/              Componentes, estilos y formatos comunes
└── Resources/           Configuración de la aplicación
```

## Estado actual

El proyecto se encuentra en fase de MVP funcional. Las funciones principales de cuentas, movimientos, presupuestos, objetivos, gráficos e importación CSV están implementadas.

Antes de utilizar la aplicación como única fuente de información financiera se recomienda completar y probar:

- Copias de seguridad cifradas.
- Restauración de datos.
- Importación específica para archivos de cada banco.
- Pruebas en distintos modelos de iPhone.
- Pruebas de accesibilidad y tamaños de texto.
- Sincronización bancaria mediante proveedores oficiales.

## Licencia

Este repositorio no incluye actualmente una licencia de uso público. Todos los derechos quedan reservados a su autor.
