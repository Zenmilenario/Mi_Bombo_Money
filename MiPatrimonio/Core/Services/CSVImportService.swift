import Foundation

struct ImportedMovementDraft: Identifiable {
    let id = UUID()
    let rowNumber: Int
    let date: Date
    let type: TransactionType
    let signedAmountMinor: Int64
    let sourceAccountName: String?
    let destinationAccountName: String?
    let categoryName: String?
    let description: String
    let notes: String
    let isReconciled: Bool
    let externalID: String?

    var amountMinor: Int64 { Swift.abs(signedAmountMinor) }
}

struct CSVParseResult {
    let drafts: [ImportedMovementDraft]
    let warnings: [String]
}

enum CSVImportError: LocalizedError {
    case unreadableFile
    case emptyFile
    case missingHeader
    case missingRequiredColumns([String])
    case noValidRows

    var errorDescription: String? {
        switch self {
        case .unreadableFile:
            "No se ha podido leer el archivo. Comprueba su codificación."
        case .emptyFile:
            "El archivo está vacío."
        case .missingHeader:
            "No se ha encontrado una fila de cabeceras."
        case let .missingRequiredColumns(columns):
            "Faltan columnas obligatorias: \(columns.joined(separator: ", "))."
        case .noValidRows:
            "No se ha encontrado ninguna fila válida para importar."
        }
    }
}

enum CSVImportService {
    static func parse(url: URL) throws -> CSVParseResult {
        let data = try Data(contentsOf: url)
        guard let text = decode(data: data) else { throw CSVImportError.unreadableFile }
        return try parse(text: text)
    }

    static func parse(text: String) throws -> CSVParseResult {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CSVImportError.emptyFile
        }

        let delimiter = detectDelimiter(in: text)
        let rows = parseRows(text, delimiter: delimiter)
            .filter { row in row.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }

        guard let header = rows.first else { throw CSVImportError.missingHeader }
        let normalizedHeaders = header.map(normalizeHeader)
        let indexes = HeaderIndexes(headers: normalizedHeaders)

        var missing: [String] = []
        if indexes.date == nil { missing.append("fecha") }
        if indexes.amount == nil { missing.append("importe") }
        if indexes.description == nil { missing.append("descripción/concepto") }
        guard missing.isEmpty else { throw CSVImportError.missingRequiredColumns(missing) }

        var drafts: [ImportedMovementDraft] = []
        var warnings: [String] = []

        for (offset, row) in rows.dropFirst().enumerated() {
            let rowNumber = offset + 2
            guard let rawDate = value(at: indexes.date, in: row),
                  let date = parseDate(rawDate)
            else {
                warnings.append("Fila \(rowNumber): fecha no reconocida.")
                continue
            }

            guard let rawAmount = value(at: indexes.amount, in: row),
                  let signedAmount = MoneyParser.minorUnits(from: rawAmount),
                  signedAmount != 0
            else {
                warnings.append("Fila \(rowNumber): importe no válido o igual a cero.")
                continue
            }

            let rawType = value(at: indexes.type, in: row)
            let type = parseType(rawType, signedAmountMinor: signedAmount)
            let description = value(at: indexes.description, in: row)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Movimiento importado"

            drafts.append(ImportedMovementDraft(
                rowNumber: rowNumber,
                date: date,
                type: type,
                signedAmountMinor: signedAmount,
                sourceAccountName: cleanOptional(value(at: indexes.sourceAccount, in: row)),
                destinationAccountName: cleanOptional(value(at: indexes.destinationAccount, in: row)),
                categoryName: cleanOptional(value(at: indexes.category, in: row)),
                description: description.isEmpty ? "Movimiento importado" : description,
                notes: cleanOptional(value(at: indexes.notes, in: row)) ?? "",
                isReconciled: parseBoolean(value(at: indexes.reconciled, in: row)),
                externalID: cleanOptional(value(at: indexes.externalID, in: row))
            ))
        }

        guard !drafts.isEmpty else { throw CSVImportError.noValidRows }
        return CSVParseResult(drafts: drafts, warnings: warnings)
    }

    private static func decode(data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        if let latin1 = String(data: data, encoding: .isoLatin1) { return latin1 }
        if let windows = String(data: data, encoding: .windowsCP1252) { return windows }
        return nil
    }

    private static func detectDelimiter(in text: String) -> Character {
        let firstLine = text
            .split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: { $0.isNewline })
            .first
            .map(String.init) ?? text

        let candidates: [Character] = [";", ",", "\t"]
        let counts = candidates.map { delimiter in
            (delimiter, countDelimiter(delimiter, in: firstLine))
        }
        return counts.max(by: { $0.1 < $1.1 })?.0 ?? ";"
    }

    private static func countDelimiter(_ delimiter: Character, in line: String) -> Int {
        var inQuotes = false
        var count = 0
        var previous: Character?
        for character in line {
            if character == "\"", previous != "\\" { inQuotes.toggle() }
            if character == delimiter, !inQuotes { count += 1 }
            previous = character
        }
        return count
    }

    private static func parseRows(_ text: String, delimiter: Character) -> [[String]] {
        let characters = Array(text)
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if character == "\"" {
                if inQuotes, index + 1 < characters.count, characters[index + 1] == "\"" {
                    field.append("\"")
                    index += 1
                } else {
                    inQuotes.toggle()
                }
            } else if character == delimiter, !inQuotes {
                row.append(field)
                field = ""
            } else if (character == "\n" || character == "\r"), !inQuotes {
                if character == "\r", index + 1 < characters.count, characters[index + 1] == "\n" {
                    index += 1
                }
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            } else {
                field.append(character)
            }

            index += 1
        }

        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }

        return rows
    }

    private static func normalizeHeader(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "", options: .regularExpression)
    }

    private static func value(at index: Int?, in row: [String]) -> String? {
        guard let index, row.indices.contains(index) else { return nil }
        return row[index]
    }

    private static func cleanOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func parseType(_ rawValue: String?, signedAmountMinor: Int64) -> TransactionType {
        guard let rawValue else { return signedAmountMinor < 0 ? .expense : .income }
        let value = normalizeHeader(rawValue)

        if value.contains("transfer") || value.contains("traspas") { return .transfer }
        if value.contains("interes") || value.contains("interest") { return .interest }
        if value.contains("comision") || value.contains("fee") { return .fee }
        if value.contains("gasto") || value.contains("expense") || value.contains("cargo") { return .expense }
        if value.contains("ingreso") || value.contains("income") || value.contains("abono") { return .income }
        return signedAmountMinor < 0 ? .expense : .income
    }

    private static func parseBoolean(_ rawValue: String?) -> Bool {
        guard let rawValue else { return false }
        let value = normalizeHeader(rawValue)
        return ["si", "yes", "true", "1", "conciliado"].contains(value)
    }

    private static func parseDate(_ rawValue: String) -> Date? {
        let cleaned = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let formats = [
            "dd/MM/yyyy",
            "d/M/yyyy",
            "yyyy-MM-dd",
            "dd-MM-yyyy",
            "d-M-yyyy",
            "dd.MM.yyyy",
            "yyyy/MM/dd",
            "MM/dd/yyyy",
        ]

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_ES_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.isLenient = false

        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: cleaned) { return date }
        }

        let iso = ISO8601DateFormatter()
        return iso.date(from: cleaned)
    }
}

private struct HeaderIndexes {
    let date: Int?
    let type: Int?
    let sourceAccount: Int?
    let destinationAccount: Int?
    let category: Int?
    let description: Int?
    let amount: Int?
    let reconciled: Int?
    let notes: Int?
    let externalID: Int?

    init(headers: [String]) {
        date = Self.find(in: headers, aliases: ["fecha", "fechaoperacion", "fechavalor", "date", "bookingdate"])
        type = Self.find(in: headers, aliases: ["tipo", "tipomovimiento", "type", "movementtype"])
        sourceAccount = Self.find(in: headers, aliases: ["cuenta", "cuentaorigen", "cuentaafectada", "account", "sourceaccount"])
        destinationAccount = Self.find(in: headers, aliases: ["cuentadestino", "destinationaccount", "targetaccount"])
        category = Self.find(in: headers, aliases: ["categoria", "category"])
        description = Self.find(in: headers, aliases: ["descripcion", "concepto", "detalle", "movimiento", "description", "merchant", "payee"])
        amount = Self.find(in: headers, aliases: ["importe", "cantidad", "amount", "monto", "valor"])
        reconciled = Self.find(in: headers, aliases: ["conciliado", "reconciled", "validado"])
        notes = Self.find(in: headers, aliases: ["notas", "observaciones", "notes", "memo"])
        externalID = Self.find(in: headers, aliases: ["id", "idmovimiento", "transactionid", "referencia", "reference"])
    }

    private static func find(in headers: [String], aliases: [String]) -> Int? {
        headers.firstIndex { header in aliases.contains(header) }
    }
}
