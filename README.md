<p align="center">
  <img src="docs/assets/repository-cover.svg" alt="Doblón (antes Mi Bombo Money). Tu dinero, con perspectiva. Aplicación para iPhone y iPad." width="100%">
</p>

<h1 align="center">Doblón</h1>

<p align="center">
  Tus cuentas, tus objetivos y tus decisiones, en un mismo lugar. Antes <em>Mi Bombo Money</em>.<br>
  Finanzas personales para iPhone y iPad con SwiftUI, y para Android con Flutter.
</p>

<p align="center">
  <img alt="iOS 17 o posterior" src="https://img.shields.io/badge/iOS-17%2B-223344?style=flat&amp;logo=apple&amp;logoColor=white">
  <img alt="Interfaz SwiftUI" src="https://img.shields.io/badge/Interfaz-SwiftUI-223344?style=flat&amp;logo=swift&amp;logoColor=white">
  <img alt="Base cloud PostgreSQL" src="https://img.shields.io/badge/Cloud-PostgreSQL-223344?style=flat&amp;logo=postgresql&amp;logoColor=white">
  <img alt="Proyecto en desarrollo" src="https://img.shields.io/badge/Estado-En_desarrollo-92cfc4?style=flat&amp;labelColor=223344">
</p>

<p align="center">
  <a href="#qué-puedes-hacer">Funciones</a> ·
  <a href="#ponerla-en-marcha">Empezar</a> ·
  <a href="#documentación">Documentación</a> ·
  <a href="https://github.com/Zenmilenario/Mi_Bombo_Money/actions">Comprobaciones</a>
</p>

---

## Qué puedes hacer

| Tu día a día | Lo que ofrece la app |
| --- | --- |
| **Ver dónde estás** | Patrimonio, dinero disponible, reservas y resumen mensual. |
| **Controlar tus cuentas** | Efectivo, ahorro, tarjetas vinculadas e inversiones, con saldos y valoraciones. |
| **Entender los movimientos** | Ingresos, gastos y transferencias, búsqueda, filtros y revisión de duplicados. |
| **Planificar el mes** | Presupuestos por categoría, repetición y opción de trasladar el sobrante. |
| **Apartar dinero con un propósito** | Reservas asociadas a tus cuentas que pueden acompañar a una transferencia propia. |
| **Reducir tareas repetidas** | Cargos periódicos, reglas de categorías y propuestas de clasificación mediante aprendizaje automático. |
| **Continuar en otro dispositivo** | Sincronización con Supabase y copia local para trabajar sin conexión. |
| **Que algo te avise sin molestar** | Don Bigotes, un gato con traje, señala cargos retenidos, movimientos por revisar o recibos próximos; se esconde cuando no hay nada. |

La interfaz se adapta al espacio disponible y al tamaño de letra. Incluye apariencia clara, oscura o del sistema, bloqueo con la autenticación del dispositivo y ocultación de importes.

## Conexión bancaria y aprendizaje

**Bancos.** La integración con Enable Banking consulta saldos y movimientos con autorización del titular. La conexión no permite realizar pagos. Las primeras descargas se revisan y concilian con lo ya registrado; la cobertura, los datos disponibles y las esperas dependen del banco y del proveedor. El laboratorio utiliza datos ficticios en un espacio separado.

**IA de categorías.** Un clasificador local aprende de ejemplos y de las confirmaciones del usuario para proponer categorías. Las propuestas requieren revisión; no equivalen a una contabilidad autónoma.

**Versiones en esta rama:** iOS nativo 0.7.15 y [Flutter 0.12.0](doblon_android/README.md), actualmente destinado a Android. Flutter es la base prevista para unificar las plataformas; el relevo de la app iOS todavía requiere compilación y pruebas en dispositivos. Ambas usan Supabase y el mismo servidor bancario. La interfaz «Pulso» incluye cuentas, reservas, inversiones, retenciones y el compañero Don Bigotes. [Diseño visual](DISENO_VISUAL_2026_10_29.md).

Consulta el [alcance y la evaluación de los modelos](CloudBackend/APRENDIZAJE_CATEGORIAS.md) y la [integración bancaria personal](BankingBackend/INTEGRACION_PERSONAL.md).

## Ponerla en marcha

### Con un Mac

1. Abre [MiPatrimonio.xcodeproj](MiPatrimonio.xcodeproj).
2. Selecciona el esquema **MiPatrimonio** y un simulador de iPhone o iPad.
3. Compila y ejecuta desde Xcode. Para un dispositivo físico, configura tu equipo de firma.

La app requiere **iOS 17 o posterior**. Una instalación nueva empieza sin movimientos ni saldos de ejemplo e incluye categorías habituales.

### Desde Windows

Sube tu rama con GitHub Desktop y revisa las ejecuciones de [GitHub Actions](https://github.com/Zenmilenario/Mi_Bombo_Money/actions). El repositorio dispone de validación iOS y generación de IPA; instalar en un dispositivo requiere el proceso de firma correspondiente.

Abre una **pull request en borrador** para que cada push de la rama ejecute todos los checks una sola vez por workflow. También se valida `main` después del merge. Una rama sin PR se puede comprobar con **Run workflow**. [Política de comprobaciones y cobertura](CI.md).

[Subir desde Windows](SUBIR_DESDE_WINDOWS.md) · [Distribución e instalación de IPA](DISTRIBUCION_IPA.md)

### Android

Consulta [la app Flutter y su compilación](doblon_android/README.md). El workflow «Comprobar app Android» analiza el código, ejecuta todas las pruebas Flutter y genera el APK. Los cambios locales deben pasar también los checks de su nuevo commit.

## Cómo está construida

| Componente | Tecnología y responsabilidad |
| --- | --- |
| **App iOS** | SwiftUI para la interfaz y SwiftData para la copia local. |
| **App Flutter** | Android; formularios, cálculos, aprendizaje y copia local con cola de cambios. Destino futuro también iOS. |
| **Sincronización** | Supabase Auth, PostgreSQL y aislamiento de datos por usuario. |
| **Conexión bancaria** | Backend en Cloudflare Workers con D1 e integración con Enable Banking. |
| **Aprendizaje** | Modelos locales de regresión logística multiclase; las correcciones alimentan el entrenamiento. |
| **Comprobaciones** | GitHub Actions para compilación iOS, análisis y APK Android, cálculos, copias, nube y conexión bancaria. |

## Documentación

| Quiero consultar… | Guía |
| --- | --- |
| La arquitectura y las funciones | [Especificación funcional y técnica](ESPECIFICACION_FUNCIONAL_Y_TECNICA.md) |
| La base de datos y la sincronización | [Backend cloud](CloudBackend/README.md) |
| La conexión con cuentas reales | [Conexión personal](BankingBackend/CONEXION_REAL_PERSONAL.md) |
| Las pruebas con datos ficticios | [Laboratorio bancario](BankingBackend/README.md) |
| Las categorías y los modelos de IA | [Aprendizaje y evaluación](CloudBackend/APRENDIZAJE_CATEGORIAS.md) |
| Las reservas y las inversiones | [Dinero reservado](RESERVAS.md) · [Efectivo e inversiones](INVERSIONES.md) |
| La revisión de movimientos y los ajustes | [Conciliación y categorías](REVISION_MOVIMIENTOS.md) · [Navegación de Ajustes](AJUSTES.md) |
| El diseño de la interfaz | [Diseño visual](DISENO_VISUAL_2026_10_29.md) |
| Las versiones y decisiones anteriores | [Historial de desarrollo](docs/HISTORIAL_DESARROLLO.md) |
| Los checks, sus eventos y la cobertura conservada | [Comprobaciones de GitHub](CI.md) |

## Datos y seguridad

Las credenciales bancarias se introducen en el proceso de autorización del banco. Las claves privadas del proveedor permanecen en el servidor y la app utiliza el llavero del dispositivo para sus credenciales de acceso.

El entrenamiento y la inferencia se ejecutan en el dispositivo, sin enviar movimientos a una IA externa. Lo aprendido se comparte entre los dispositivos de la misma persona mediante `finance_learning`, separado del documento financiero y de su exportación. [Contrato de aprendizaje compartido](CloudBackend/learning-contract.md).

El proyecto está en desarrollo. Los cambios preparados localmente deben superar los checks del commit correspondiente y probarse en un dispositivo antes de considerarse validados.
