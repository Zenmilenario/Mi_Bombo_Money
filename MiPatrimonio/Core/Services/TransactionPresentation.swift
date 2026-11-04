import Foundation

enum TransactionPresentation {
    // Presentation only: identifiers, saved text and deduplication inputs stay intact.
    static func title(_ original: String, isBanking: Bool) -> String {
        guard isBanking else { return original }
        let text = original.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only the observed TXT D/H envelope is understood. Unknown bank codes
        // and separators inside the body are deliberately retained.
        guard let range = text.range(of: "^/TXT/[DH]\\|", options: [.regularExpression, .caseInsensitive]) else {
            return original
        }
        let body = String(text[range.upperBound...])
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? original : body
    }
}

extension FinancialTransaction {
    var displayDescription: String {
        TransactionPresentation.title(descriptionText,
            isBanking: bankEntryKey != nil || externalID?.hasPrefix("bank-test:") == true
                || externalID?.hasPrefix("bank-test-transfer:") == true)
    }
}
