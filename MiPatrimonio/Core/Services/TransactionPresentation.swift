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
        TransactionPresentation.title(descriptionText,
            isBanking: bankEntryKey != nil || externalID?.hasPrefix("bank-test:") == true
                || externalID?.hasPrefix("bank-test-transfer:") == true)
    }
}
