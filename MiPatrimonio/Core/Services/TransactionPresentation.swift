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
