import Foundation

enum TransactionOperationKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case ordinary, investment, roundUp, saveback
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ordinary: "Otro movimiento"
        case .investment: "Aportación a inversión"
        case .roundUp: "Round up"
        case .saveback: "Saveback"
        }
    }
    var explanation: String {
        switch self {
        case .ordinary: "No es uno de estos beneficios ni una aportación a inversión."
        case .investment: "Dinero propio destinado a inversión. Comprueba la cuenta de destino antes de convertirlo en transferencia."
        case .roundUp: "Redondeo de pagos: aparta efectivo propio para invertir. No debe sumarse al consumo ni descontarse otra vez al ejecutarse."
        case .saveback: "Recompensa destinada a inversión. Distingue el bruto, la retención y el neto; no presupone una salida de efectivo propio."
        }
    }
}

/// Supervised operation recognition, independent of expense-category prediction and accounting.
/// Synthetic rows teach vocabulary only. Context is learned exclusively from confirmed examples.
struct TransactionOperationModel: Sendable {
    struct CardTerms: Codable, Equatable, Sendable {
        let savebackPercent: Double
        let roundUpMultiplier: Int
        let validFrom: Date
        var valid: Bool {
            savebackPercent.isFinite && savebackPercent > 0 && savebackPercent <= 100
                && [1, 2, 3, 5, 10].contains(roundUpMultiplier) && validFrom.timeIntervalSince1970.isFinite
        }
    }
    struct Input: Codable, Hashable, Sendable {
        let text: String
        let amountMinor: Int64
        let isCredit: Bool
        let day: Int
        let weekday: Int
        let month: String
        let accountKey: String
        var savebackPercent: Double? = nil
        var roundUpMultiplier: Int? = nil

        var valid: Bool {
            amountMinor > 0 && amountMinor <= 1_000_000_000_000 && (1...31).contains(day)
                && (1...7).contains(weekday) && !accountKey.isEmpty
                && (savebackPercent.map { $0.isFinite && $0 > 0 && $0 <= 100 } ?? true)
                && (roundUpMultiplier.map { [1, 2, 3, 5, 10].contains($0) } ?? true)
        }
        var words: [String] {
            text.prefix(400).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es_ES"))
                .lowercased().split(whereSeparator: { !$0.isLetter }).prefix(30).map(String.init)
        }
        var hasDescription: Bool {
            !words.filter { !["movimiento", "bancario", "bank", "transaction", "txt", "d", "h"].contains($0) }.isEmpty
        }
    }
    struct Example: Equatable, Sendable {
        let input: Input
        let kind: TransactionOperationKind
        let confirmed: Bool
    }
    struct Prediction: Sendable {
        let kind: TransactionOperationKind
        /// A model score, not a calibrated probability of correctness.
        let score: Double
        let usesContext: Bool
    }

    private let weights: [String: [Double]]
    private let confirmations: [Example]
    private static let kinds = TransactionOperationKind.allCases

    private static func features(_ input: Input, context: Bool) -> [String: Double] {
        var result: [String: Double] = [:]
        let words = Set(input.words.filter { $0.count >= 2 && !["movimiento", "bancario", "transaction"].contains($0) })
        let textScale = 1 / sqrt(Double(max(1, words.count)))
        for word in words {
            result["w:" + word] = textScale
            let letters = Array("^" + String(word.prefix(30)) + "$")
            for index in 0..<(letters.count - 2) {
                result["c:" + String(letters[index...index + 2])] = textScale * 0.25
            }
        }
        guard context else { return result }
        // No fixed amount or execution-day rule assigns a class.
        result["bias"] = 0.3
        result["credit"] = input.isCredit ? 0.6 : -0.6
        result["amount"] = log1p(Double(input.amountMinor) / 100) / 8
        result["day:" + String(input.day)] = 0.5
        result["weekday:" + String(input.weekday)] = 0.2
        result["account:" + input.accountKey] = 0.4
        result["amount-day"] = (result["amount"] ?? 0) * Double(input.day) / 31
        if let percent = input.savebackPercent { result["saveback-rate"] = percent / 100 }
        if let multiplier = input.roundUpMultiplier { result["roundup-multiplier"] = Double(multiplier) / 10 }
        return result
    }

    static func train(_ examples: [Example]) -> Self? {
        // Repeated observations do not inflate support; contradictory observations are ambiguous.
        let groups = Dictionary(grouping: examples.filter { $0.confirmed && $0.input.valid }, by: \.input)
        let confirmed = groups.values.compactMap { rows -> Example? in
            Set(rows.map(\.kind)).count == 1 ? rows.first : nil
        }.sorted {
            let left = $0.input, right = $1.input
            return "\(left.accountKey)|\(left.month)|\(left.day)|\(left.weekday)|\(left.amountMinor)|\(left.isCredit)|\(left.text)"
                < "\(right.accountKey)|\(right.month)|\(right.day)|\(right.weekday)|\(right.amountMinor)|\(right.isCredit)|\(right.text)"
        }
        let rows = (syntheticExamples + confirmed).map {
            (features($0.input, context: $0.confirmed), kinds.firstIndex(of: $0.kind)!, $0.confirmed ? 2.0 : 1.0)
        }
        let zero = [Double](repeating: 0, count: kinds.count)
        var weights: [String: [Double]] = [:]
        for epoch in 0..<70 {
            if Task.isCancelled { return nil }
            let step = 0.16 / (1 + Double(epoch) * 0.03)
            for offset in rows.indices {
                let (features, label, importance) = rows[(offset + epoch * 7) % rows.count]
                var scores = zero
                for (feature, value) in features {
                    guard let vector = weights[feature] else { continue }
                    for index in kinds.indices { scores[index] += vector[index] * value }
                }
                let probabilities = softmax(scores)
                for (feature, value) in features {
                    var vector = weights[feature] ?? zero
                    for index in kinds.indices {
                        vector[index] = vector[index] * 0.9997 + step * importance * value
                            * ((index == label ? 1 : 0) - probabilities[index])
                    }
                    weights[feature] = vector
                }
            }
        }
        return Self(weights: weights, confirmations: confirmed)
    }

    func predict(_ input: Input) -> Prediction? {
        guard input.valid else { return nil }
        let related = confirmations.filter { $0.input.accountKey == input.accountKey && $0.input != input }
        let context = !input.hasDescription
        if context {
            // Amount and date alone are ambiguous. Require independent, same-account evidence.
            guard related.count >= 8, Set(related.map { $0.input.month }).count >= 2,
                  Set(related.map(\.kind)).count >= 2 else { return nil }
        }
        let features = Self.features(input, context: context)
        guard !features.isEmpty else { return nil }
        var scores = [Double](repeating: 0, count: Self.kinds.count)
        for (feature, value) in features {
            guard let vector = weights[feature] else { continue }
            for index in Self.kinds.indices { scores[index] += vector[index] * value }
        }
        let probabilities = Self.softmax(scores)
        let ranked = probabilities.indices.sorted { probabilities[$0] > probabilities[$1] }
        let first = ranked[0], second = ranked[1], kind = Self.kinds[first]
        guard kind != .ordinary, probabilities[first] >= (context ? 0.8 : 0.7),
              probabilities[first] - probabilities[second] >= 0.3 else { return nil }
        if context {
            guard related.filter({ $0.kind == kind }).count >= 3,
                  related.filter({ $0.kind != kind }).count >= 3 else { return nil }
        }
        return Prediction(kind: kind, score: probabilities[first], usesContext: context)
    }

    private static func softmax(_ scores: [Double]) -> [Double] {
        let highest = scores.max() ?? 0
        let values = scores.map { exp($0 - highest) }, total = values.reduce(0, +)
        return values.map { $0 / total }
    }

    /// Invented vocabulary, never personal screenshots or financial records.
    private static var syntheticExamples: [Example] {
        let vocabulary: [(TransactionOperationKind, [String])] = [
            (.roundUp, ["Round up inversión", "Roundup tarjeta", "Redondeo de compras", "Inversión por redondeos", "Card round up investment", "Redondeo acumulado tarjeta"]),
            (.saveback, ["Saveback recompensa", "Save back inversión", "Recompensa Saveback neta", "Saveback reward investment", "Bonificación Saveback tarjeta", "Saveback impuestos deducidos"]),
            (.investment, ["Plan de inversión ejecutado", "Aportación a cartera de valores", "Compra participaciones fondo inversión", "Savings plan execution", "Aportación periódica inversión", "Compra ETF plan ahorro"]),
            (.ordinary, ["Supermercado compra tarjeta", "Cafetería desayuno", "Comisión mantenimiento", "Nómina mensual", "Bizum recibido", "Transferencia familiar", "Pago tarjeta tienda online", "Intereses cuenta ahorro", "Pago restaurante", "Retirada efectivo", "Abono devolución compra", "Suscripción plataforma"])
        ]
        return vocabulary.flatMap { kind, texts in
            texts.map { text in
                Example(input: Input(text: text, amountMinor: 100, isCredit: false, day: 1, weekday: 1,
                                     month: "synthetic", accountKey: "synthetic"), kind: kind, confirmed: false)
            }
        }
    }
}
