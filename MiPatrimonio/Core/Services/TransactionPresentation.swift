import Foundation

enum TransactionPresentation {
    // Presentation only: identifiers, saved text and deduplication inputs stay intact.
    static func title(_ original: String, isBanking: Bool) -> String {
        guard isBanking else { return original }
        let text = bankBody(original)
        if let marker = transferMarker(in: text) {
            let detail = String(text[marker.upperBound...]).trimmingCharacters(in: .whitespaces)
            let label = text[marker].range(of: #"\b(?:INM|INMEDIAT[AO])\b"#, options: [.regularExpression, .caseInsensitive]) == nil
                ? "Transferencia" : "Transferencia inmediata"
            return detail.isEmpty ? label : "\(label) · \(detail)"
        }
        let segments = text.components(separatedBy: "//").map { $0.trimmingCharacters(in: .whitespaces) }
        if segments.count > 1, let merchant = segments.last, !merchant.isEmpty,
           segments.dropLast().allSatisfy({ $0.range(of: #"^PAGO CON TARJETA(?: DE SERVICIOS VARIOS)?$"#,
                                                      options: [.regularExpression, .caseInsensitive]) != nil }) {
            return merchant
        }
        return text
    }

    /// Title for lists and headers only. Beyond `title`, it names common bank operations and turns
    /// all-capital bank concepts into readable text. Never used for rules, learning or matching.
    static func listTitle(_ original: String, isBanking: Bool) -> String {
        let base = title(isBanking ? stripBankNoise(original) : original, isBanking: isBanking)
        guard isBanking else { return base }
        let segments = base.components(separatedBy: "//").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var text = base
        if let head = segments.first?.uppercased(), segments.count > 1 {
            if head.hasPrefix("RET. EFECTIVO") || head.hasPrefix("RETIRADA") || head.contains("CAJERO") {
                text = "Retirada de efectivo"
            } else if head.hasPrefix("ADEUDO") || head.hasPrefix("RECIBO"), let creditor = segments.last {
                // SEPA direct debits end with the creditor, sometimes after a mandate reference ("N 123…").
                let name = creditor.replacingOccurrences(of: #"^N\s*\d+\s+"#, with: "", options: .regularExpression)
                text = "Recibo · " + readableCase(name)
                return text
            }
        }
        return readableCase(text)
    }

    /// Pending card postings arrive as "/TXT/MERCHANT DD/MM/YY|REFERENCE": drop the marker, the glued date
    /// and the trailing reference. The "/TXT/D|" and "/TXT/H|" envelopes are left to `title`.
    private static func stripBankNoise(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.replacingOccurrences(of: #"^/TXT/(?![A-Z]\|)"#, with: "", options: [.regularExpression, .caseInsensitive])
        value = value.replacingOccurrences(of: #"\|\d{6,}$"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\s*\d{2}/\d{2}/\d{2,4}$"#, with: "", options: .regularExpression)
        value = value.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? text : value
    }

    /// Converts shouting bank text ("COMERCIO DEL NORTE, S.L.") to "Comercio del Norte, S.L.".
    /// Mixed-case text, codes with digits and dotted abbreviations are left as they are.
    static func readableCase(_ text: String) -> String {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count >= 4, text == text.uppercased(), text != text.lowercased() else { return text }
        let spanish = Locale(identifier: "es_ES")
        let connectors: Set<String> = ["de", "del", "la", "las", "el", "los", "y", "e", "en", "a", "al", "con", "por", "para"]
        var isFirst = true
        return text.components(separatedBy: " ").map { word -> String in
            defer { if !word.isEmpty { isFirst = false } }
            guard !word.isEmpty else { return word }
            if word.contains(where: \.isNumber) { return word }
            if word.range(of: #"^(?:[A-ZÑ]\.){1,3}[A-ZÑ]?\.?,?$"#, options: .regularExpression) != nil { return word }
            let lower = word.lowercased(with: spanish)
            if !isFirst && connectors.contains(lower) { return lower }
            guard let index = lower.firstIndex(where: \.isLetter) else { return lower }
            return lower.replacingCharacters(in: index...index, with: String(lower[index]).uppercased(with: spanish))
        }.joined(separator: " ")
    }

    static func indicatesTransfer(_ original: String) -> Bool {
        transferMarker(in: bankBody(original)) != nil
    }

    private static func bankBody(_ original: String) -> String {
        let text = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let envelope = text.range(of: #"^/TXT/[DH]\|"#, options: [.regularExpression, .caseInsensitive]) else {
            return original
        }
        let body = String(text[envelope.upperBound...]).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return body.isEmpty ? original : body
    }

    private static func transferMarker(in text: String) -> Range<String.Index>? {
        text.range(of: #"^(?:TRANS\s+INM\.?|TRANSFERENCIA(?:\s+(?:INMEDIATA|EMITIDA|RECIBIDA))?)(?:\s*[/|:\-]\s*|\s+|$)"#,
                   options: [.regularExpression, .caseInsensitive])
    }
}

extension FinancialTransaction {
    var hasBankTransferConcept: Bool {
        bankEntryKey != nil && (type == .expense || type == .income)
            && TransactionPresentation.indicatesTransfer(descriptionText)
    }

    var displayDescription: String {
        TransactionPresentation.title(descriptionText, isBanking: isBankPosting)
    }

    /// Readable title for lists and headers; logic keeps using `displayDescription`.
    var listTitle: String {
        TransactionPresentation.listTitle(descriptionText, isBanking: isBankPosting)
    }

    private var isBankPosting: Bool {
        bankEntryKey != nil || externalID?.hasPrefix("bank-test:") == true
            || externalID?.hasPrefix("bank-test-transfer:") == true
    }
}

/// A saying, quote or curiosity about money for the sign-in and unlock screens. One per day; never advice.
struct DailyQuote: Equatable {
    enum Kind { case quote, saying, curiosity }
    let kind: Kind
    let text: String
    var author: String? = nil

    var label: String {
        switch kind {
        case .quote: "FRASE DEL DÍA"
        case .saying: "REFRÁN DEL DÍA"
        case .curiosity: "¿SABÍAS QUE…?"
        }
    }
    var displayText: String { kind == .curiosity ? text : "«\(text)»" }

    static let all: [DailyQuote] = [
        .init(kind: .quote, text: "No es pobre el que tiene poco, sino el que mucho desea.", author: "Séneca"),
        .init(kind: .curiosity, text: "La peseta nació en 1868 y convivió con el euro hasta el 28 de febrero de 2002."),
        .init(kind: .saying, text: "Poco a poco se va lejos."),
        .init(kind: .quote, text: "Dos linajes solos hay en el mundo, que son el tener y el no tener.", author: "Miguel de Cervantes"),
        .init(kind: .curiosity, text: "La palabra «banco» viene de las mesas de madera donde los cambistas medievales hacían sus tratos."),
        .init(kind: .quote, text: "El dinero es un buen sirviente, pero un mal amo.", author: "Atribuida a Francis Bacon"),
        .init(kind: .saying, text: "Grano a grano, llena la gallina el buche."),
        .init(kind: .quote, text: "La felicidad está en el gusto, y no en las cosas.", author: "François de La Rochefoucauld"),
        .init(kind: .curiosity, text: "Los billetes y monedas de euro empezaron a circular el 1 de enero de 2002."),
        .init(kind: .curiosity, text: "El doblón fue una moneda de oro española que circuló durante siglos por medio mundo."),
        .init(kind: .saying, text: "Quien guarda, halla."),
        .init(kind: .saying, text: "El tiempo es oro.")
    ]

    /// The quote for a day, shifted by `offset` when the person taps for another one.
    static func of(_ date: Date, offset: Int = 0, calendar: Calendar = .current) -> DailyQuote {
        let day = calendar.ordinality(of: .day, in: .era, for: date) ?? 0
        let count = all.count
        return all[((day + offset) % count + count) % count]
    }
}

/// What the person dismissed, kept on this device. Three dismissals of one kind mute that kind.
struct CompanionMemory: Codable, Equatable {
    var dismissed: Set<String> = []
    var dismissalsByKind: [String: Int] = [:]

    init() {}
    init(serialized: String) {
        self = (try? JSONDecoder().decode(Self.self, from: Data(serialized.utf8))) ?? Self()
    }
    var serialized: String { (try? String(decoding: JSONEncoder().encode(self), as: UTF8.self)) ?? "" }

    func isMuted(_ kind: String) -> Bool { dismissalsByKind[kind, default: 0] >= 3 }
    func shows(id: String, kind: String) -> Bool { !dismissed.contains(id) && !isMuted(kind) }
    mutating func dismiss(id: String, kind: String) {
        if dismissed.insert(id).inserted { dismissalsByKind[kind, default: 0] += 1 }
        // Keep the store small: old dismissals of notes that no longer exist are dropped by `forget`.
    }
    mutating func forget(except activeIDs: Set<String>) { dismissed.formIntersection(activeIDs) }
}

/// Where Don Bigotes points when the person taps «Ver». Written by the companion and consumed once by the
/// destination screen, which then filters, scrolls to and highlights the element.
enum CompanionFocus: String {
    case holds, review, stale, recurring, bankReview

    /// Stored as "kind|timestamp" so tapping the same note twice still triggers a change.
    static func request(_ focus: CompanionFocus, at date: Date = .now) -> String {
        "\(focus.rawValue)|\(date.timeIntervalSince1970)"
    }
    static func parse(_ stored: String) -> CompanionFocus? {
        stored.split(separator: "|").first.flatMap { CompanionFocus(rawValue: String($0)) }
    }
}

/// The hours at which the app is usually opened, kept on this device. Don Bigotes saves what is not
/// urgent for those hours; until it has seen enough openings it treats every hour as usual.
struct UsageHours: Codable, Equatable {
    var counts: [Int: Int] = [:]
    var lastRecorded: Date?

    static let minimumOpenings = 10

    init() {}
    init(serialized: String) {
        self = (try? JSONDecoder().decode(Self.self, from: Data(serialized.utf8))) ?? Self()
    }
    var serialized: String { (try? String(decoding: JSONEncoder().encode(self), as: UTF8.self)) ?? "" }
    var total: Int { counts.values.reduce(0, +) }

    /// One opening per half hour, so quick app switches do not skew the pattern.
    mutating func record(_ date: Date, calendar: Calendar = .current) {
        if let lastRecorded, date.timeIntervalSince(lastRecorded) < 1800 { return }
        counts[calendar.component(.hour, from: date), default: 0] += 1
        lastRecorded = date
    }

    /// An hour is usual when it, or an hour next to it, holds at least a tenth of the openings.
    func isUsual(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard total >= Self.minimumOpenings else { return true }
        let hour = calendar.component(.hour, from: date)
        let threshold = max(2, total / 10)
        return [hour - 1, hour, hour + 1].contains { counts[($0 + 24) % 24, default: 0] >= threshold }
    }
}
