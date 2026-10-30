import Foundation

@main
struct TransactionReviewCheck {
    @MainActor static func main() {
        let bank = FinancialInstitution(name: "Banco ficticio")
        let account = FinancialAccount(name: "Cuenta ficticia", type: .checking, institution: bank)
        let expense = FinanceCategory(name: "Gastos", kind: .expense)
        let income = FinanceCategory(name: "Ingresos", kind: .income)
        let both = FinanceCategory(name: "Mixta", kind: .both)
        let transfers = FinanceCategory(name: "Transferencias", kind: .transfer)
        let transaction = FinancialTransaction(date: .now, type: .expense, amountMinor: 1200,
            descriptionText: "Comercio ficticio", sourceAccount: account)
        precondition(TransactionReviewService.issues(for: transaction) == [.missingCategory])
        transaction.duplicateState = .possible
        precondition(TransactionReviewService.issues(for: transaction) == [.possibleDuplicate, .missingCategory])
        transaction.category = expense
        precondition(TransactionReviewService.issues(for: transaction) == [.possibleDuplicate])
        transaction.duplicateState = .none
        precondition(TransactionReviewService.issues(for: transaction).isEmpty)
        expense.isArchived = true
        precondition(TransactionReviewService.issues(for: transaction).isEmpty,
                     "Archiving a category must not make valid historical records require review")
        transaction.category = income
        precondition(TransactionReviewService.issues(for: transaction) == [.incompatibleCategory])
        transaction.type = .income
        precondition(TransactionReviewService.issues(for: transaction).isEmpty)
        for type in [TransactionType.income, .interest, .expense, .fee] {
            transaction.type = type; transaction.category = both
            precondition(TransactionReviewService.issues(for: transaction).isEmpty)
        }
        transaction.type = .transfer; transaction.category = nil
        precondition(TransactionReviewService.issues(for: transaction).isEmpty,
                     "A transfer category is optional")
        transaction.category = transfers
        precondition(TransactionReviewService.issues(for: transaction).isEmpty)
        transaction.category = both
        precondition(TransactionReviewService.issues(for: transaction) == [.incompatibleCategory])
        transaction.type = .expense; transaction.category = both
        transaction.reservedFundID = UUID(); transaction.reservedAmountMinor = 700
        let fundID = transaction.reservedFundID
        transaction.category = expense
        precondition(transaction.amountMinor == 1200 && transaction.reservedAmountMinor == 700
                     && transaction.reservedFundID == fundID && transaction.sourceAccount?.id == account.id,
                     "Category review must preserve amounts, account and reserved financing")
        for state in [DuplicateState.none, .possible, .confirmed] {
            precondition(TransactionReviewService.duplicateStateAfterEdit(previous:state,
                previousFingerprint:"unchanged",newFingerprint:"unchanged",hasCandidates:true) == state,
                "Editing notes or category must preserve the user's previous duplicate decision")
        }
        precondition(TransactionReviewService.duplicateStateAfterEdit(previous:.none,
            previousFingerprint:"old",newFingerprint:"new",hasCandidates:true) == .possible,
            "Changing duplicate-relevant data must detect new candidates")
        precondition(TransactionReviewService.duplicateStateAfterEdit(previous:.possible,
            previousFingerprint:"old",newFingerprint:"new",hasCandidates:false) == .none)
        #if canImport(CryptoKit)
        func fingerprint() -> String {
            DuplicateDetectionService.fingerprint(date:transaction.date, sourceAccountID:transaction.sourceAccount?.id,
                destinationAccountID:transaction.destinationAccount?.id, type:transaction.type,
                amountMinor:transaction.amountMinor, description:transaction.descriptionText)
        }
        let initialFingerprint = fingerprint()
        transaction.category = both; transaction.notes = "Nota corregida"
        precondition(TransactionReviewService.duplicateStateAfterEdit(previous:.none,
            previousFingerprint:initialFingerprint,newFingerprint:fingerprint(),hasCandidates:true) == .none,
            "The real fingerprint must ignore category and notes after dismissing a duplicate")
        transaction.amountMinor += 100
        precondition(TransactionReviewService.duplicateStateAfterEdit(previous:.none,
            previousFingerprint:initialFingerprint,newFingerprint:fingerprint(),hasCandidates:true) == .possible)
        #endif
        print("Review checks passed: missing/incompatible categories, valid archived history, optional transfer category, duplicate review and preservation of reserved funding.")
    }
}
