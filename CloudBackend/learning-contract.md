# Contrato de lo aprendido compartido (versión 1)

## Transporte cifrado preparado — 11/11/2026

Este contrato describe el **documento descifrado** que combinan los clientes. Para invitados, el lote pendiente de despliegue lo transporta mediante `finance_encrypted_snapshot` / `finance_encrypted_save` con tipo `learning`, sin cambiar su esquema ni el entrenamiento local. La identidad de desarrollo explícitamente exenta conserva las RPC relacionales. Ver [cifrado, migración y recuperación](privacy-encryption.md). No hay aprendizaje colectivo automático con datos de invitados.

Lo que la persona enseña a los modelos de Doblón se comparte entre sus dispositivos (iPhone y Android). Son tres cosas: las categorías que confirma, las operaciones que identifica (aportación a inversión, Round up, Saveback) y las correcciones que hace en movimientos del banco. Se guarda en la tabla `finance_learning` de Supabase (migración `20261111000100_finance_learning.sql`) y no dentro del documento de finanzas. El motivo es que el protocolo de finanzas sustituye tablas enteras y descartaría los campos que no conoce.

- **Funciones de la nube:**
  - `finance_learning_snapshot()` devuelve `{workspace_id, revision, document}`. Si aún no hay nada guardado, la revisión es 0 y el documento `{"version": 1}`.
  - `finance_learning_save(p_workspace, p_expected_revision, p_document)` guarda solo si nadie guardó desde esa revisión. Si alguien guardó antes, responde 40001: el dispositivo vuelve a leer, combina y reintenta.
- **Privacidad:** cada persona solo ve lo suyo (RLS forzada) y el tamaño máximo es de 5 MB. No contiene importes en claro salvo los que forman parte de un ejemplo de corrección (importe, día y concepto del movimiento corregido), igual que en el aprendizaje local del iPhone.

## Identificadores y firmas canónicas

Las dos apps escriben los mismos valores:

- **Identificadores:** de movimientos, cuentas y categorías en minúsculas (`uuidString.lowercased()` en Swift).
- **Fechas:** milisegundos desde 1970, redondeados (`round((segundosDesde2001 + 978307200) × 1000)`).
- **`categorySignature`:** `sha256(tipo|idCategoría|concepto)`.
- **`identity`** de un movimiento del banco: `sha256(id|tipo|importe|fechaMs|concepto|idOrigen|idDestino|divisaOrigen|divisaDestino|bankEntryKey)`. Los campos vacíos van como texto vacío.
- **`accountKey`** de un ejemplo: `sha256(idCuenta|divisa)`.

Una entrada solo se aplica si su firma coincide con el estado actual del movimiento. Si el movimiento cambió, la entrada se conserva pero no enseña nada.

## Documento

```json
{
  "version": 1,
  "since": 1767225600000,
  "automation": {"enabled": true, "at": 0},
  "enabledAt": 1767225600000,
  "categories": {"<idMovimiento>": {"signature": "<categorySignature>|null", "at": 0}},
  "operations": {"<idMovimiento>": {"signature": "<identity>|null", "kind": "ordinary|investment|roundUp|saveback|null", "at": 0}},
  "terms": {"<idCuenta>|<validFromMs>": {"account": "<idCuenta>", "savebackPercent": 1, "roundUpMultiplier": 1, "validFrom": 0, "at": 0}},
  "corrections": {"<idMovimiento>": {"example": {"input": {}, "action": {}}, "signature": "<identity>", "prior": {"example": {}, "signature": ""}, "at": 0}},
  "reviewed": {"<idMovimiento>": 0},
  "automatic": {"<idMovimiento>": {"before": {}, "after": {}, "signature": "<identity>", "fingerprint": "", "validated": 3, "at": 0}}
}
```

- **`input`:** `{text, amountMinor, isCredit, day, weekday (1 domingo … 7 sábado), month ("año-mes" sin ceros), accountKey, savebackPercent?, roundUpMultiplier?}`.
- **`action`:** `{type, destinationID, categoryID}`.
- **Borrados:** una entrada con `signature` nula (o, en `automatic`, solo con `at`) es un borrado y se conserva para que el borrado llegue a los demás dispositivos.

## Combinación

Las reglas son las mismas en las dos apps y se comprueban con `Tests/Fixtures/shared_learning_cases.json`:

- **Entradas** (`categories`, `operations`, `terms`, `corrections`, `automatic`): por clave gana la de `at` mayor. Si coinciden, gana la de la nube.
- **`reviewed`:** unión; si una clave aparece en las dos, se queda la fecha menor.
- **`since` y `enabledAt`:** el menor de los presentes.
- **`automation`:** la de `at` mayor. Si coinciden, gana la de la nube. El valor por defecto (activado, sin cambiar nunca) lleva `at` 0.

## Cómo pone las fechas cada app

- **Android (Flutter):** guarda cada entrada con su `at` en el propio documento (`learning-<usuario>.json`), que es directamente este formato.
- **iPhone (Swift):** conserva su aprendizaje local y su formato. Al sincronizar, exporta lo que tiene con firmas canónicas y lo compara con la última copia combinada (`learning-shared-base-v1.json`):
  - Lo que no cambió conserva su `at`.
  - Lo nuevo o distinto recibe la fecha actual.
  - Lo que el iPhone podía representar (la firma coincide con el movimiento) y ya no exporta se convierte en un borrado.
  - Lo que no podía representar se conserva tal cual.
  - Después combina con la nube, adopta el resultado en su aprendizaje local y lo sube si cambió.
