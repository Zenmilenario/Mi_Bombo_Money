import Foundation

enum TransactionReviewIssue: String, Identifiable {
    case possibleDuplicate, missingCategory, incompatibleCategory
    var id: String { rawValue }
    var title: String {
        switch self {
        case .possibleDuplicate: "Posible duplicado"
        case .missingCategory: "Sin categoría"
        case .incompatibleCategory: "Categoría incompatible"
        }
    }
    var systemImage: String {
        switch self {
        case .possibleDuplicate: "doc.on.doc"
        case .missingCategory: "tag"
        case .incompatibleCategory: "tag.slash"
        }
    }
}

enum TransactionReviewService {
    static func issues(for transaction: FinancialTransaction) -> [TransactionReviewIssue] {
        var issues: [TransactionReviewIssue] = []
        if transaction.duplicateState == .possible { issues.append(.possibleDuplicate) }
        guard let category = transaction.category else {
            // A transfer already identifies its purpose; a separate category is optional.
            if transaction.type != .transfer { issues.append(.missingCategory) }
            return issues
        }
        let compatible: Bool
        switch transaction.type {
        case .income, .interest: compatible = category.kind == .income || category.kind == .both
        case .expense, .fee: compatible = category.kind == .expense || category.kind == .both
        case .transfer: compatible = category.kind == .transfer
        }
        // Archiving a valid historical category does not make its past movements incorrect.
        if !compatible { issues.append(.incompatibleCategory) }
        return issues
    }

    static func duplicateStateAfterEdit(previous: DuplicateState, previousFingerprint: String,
                                        newFingerprint: String, hasCandidates: Bool) -> DuplicateState {
        guard previousFingerprint != newFingerprint else { return previous }
        return hasCandidates ? .possible : .none
    }
}
