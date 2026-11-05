import Foundation
import SwiftData
import CryptoKit

@main
struct TransactionOperationLearningCheck {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("operation-learning-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = Schema([FinancialInstitution.self, FinancialAccount.self, PaymentCard.self, ReservedFund.self,
            FinanceCategory.self, FinancialTransaction.self, CategoryRule.self, MonthlyBudget.self, RecurringBudget.self,
            SavingsGoal.self, RecurringMovement.self, BalanceSnapshot.self, ImportBatch.self])
        func container(_ name: String, _ file: String) throws -> ModelContainer {
            try ModelContainer(for: schema, configurations: ModelConfiguration(name, schema: schema,
                url: directory.appendingPathComponent(file), allowsSave: true, cloudKitDatabase: .none))
        }
        let cloud = try container("CloudFinance", "cloud.store")
        let context = cloud.mainContext
        let account = FinancialAccount(name: "Cuenta ficticia", type: .checking, openingBalanceMinor: 100000)
        let category = FinanceCategory(name: "Compra", kind: .expense)
        let row = FinancialTransaction(date: Date(timeIntervalSince1970: 1_778_198_400), type: .expense,
            amountMinor: 239, descriptionText: "Movimiento bancario", notes: "Nota conservada",
            bankEntryKey: "bank:synthetic", recurringMovementID: UUID(), reservedFundID: UUID(), reservedAmountMinor: 100,
            sourceAccount: account, category: category)
        context.insert(account); context.insert(category); context.insert(row)
        try context.save()
        let revision = row.updatedAt
        let before = try await TransactionOperationLearning.review(row, in: context)
        precondition(before.confirmed == nil && before.prediction == nil)
        struct LegacyRecord: Codable { let signature: String; let kind: TransactionOperationKind }
        struct LegacyHistory: Codable { let records: [UUID: LegacyRecord]; let terms: [UUID: [TransactionOperationModel.CardTerms]] }
        let legacyFields = [row.id.uuidString, row.typeRaw, String(row.amountMinor), String(row.date.timeIntervalSince1970),
            row.descriptionText, account.id.uuidString, "", account.currencyCode, "", row.bankEntryKey!]
        let legacySignature = SHA256.hash(data: Data(legacyFields.joined(separator: "|").utf8))
            .map { String(format: "%02x", $0) }.joined()
        let legacy = LegacyHistory(records: [row.id: .init(signature: legacySignature, kind: .roundUp)], terms: [:])
        try JSONEncoder().encode(legacy).write(to: cloud.configurations.first!.url.appendingPathExtension("operation-learning-v1.json"))
        let upgraded = try await TransactionOperationLearning.review(row, in: context)
        precondition(upgraded.confirmed == .roundUp, "An app update must preserve the old history and signatures")
        try TransactionOperationLearning.confirm(.roundUp, transaction: row, in: context)
        let after = try await TransactionOperationLearning.review(row, in: context)
        precondition(after.confirmed == .roundUp)
        let specialized = try TransactionOperationLearning.specializedIDs(in: [row], context: context)
        precondition(specialized == Set([row.id]), "A confirmed benefit must not train ordinary expense categories")
        let terms = TransactionOperationModel.CardTerms(savebackPercent: 1, roundUpMultiplier: 1, validFrom: row.date)
        try TransactionOperationLearning.saveTerms(terms, transaction: row, in: context)
        let savedTerms = try TransactionOperationLearning.terms(for: row, in: context)
        precondition(savedTerms == terms)
        let afterTerms = try await TransactionOperationLearning.review(row, in: context)
        precondition(afterTerms.confirmed == .roundUp, "Adding card conditions must not erase a confirmed identity")
        let futureTerms = TransactionOperationModel.CardTerms(savebackPercent: 2, roundUpMultiplier: 3,
            validFrom: row.date.addingTimeInterval(86400))
        try TransactionOperationLearning.saveTerms(futureTerms, transaction: row, in: context)
        let historicalTerms = try TransactionOperationLearning.terms(for: row, in: context)
        precondition(historicalTerms == terms,
                     "New conditions must not be applied to earlier transactions")
        precondition(!context.hasChanges && row.updatedAt == revision && row.type == .expense
                     && row.amountMinor == 239 && row.notes == "Nota conservada" && row.reservedAmountMinor == 100
                     && row.category?.id == category.id && row.bankEntryKey == "bank:synthetic"
                     && account.openingBalanceMinor == 100000 && row.recurringMovementID != nil,
                     "Identifying an operation must never change financial state")
        let reopened = ModelContext(cloud)
        let restored = try reopened.fetch(FetchDescriptor<FinancialTransaction>()).first!
        let restoredReview = try await TransactionOperationLearning.review(restored, in: reopened)
        precondition(restoredReview.confirmed == .roundUp, "Confirmations survive a fresh context")
        try TransactionOperationLearning.confirm(.saveback, transaction: restored, in: reopened)
        let corrected = try await TransactionOperationLearning.review(restored, in: reopened)
        precondition(corrected.confirmed == .saveback)
        try TransactionOperationLearning.confirm(nil, transaction: restored, in: reopened)
        let removed = try await TransactionOperationLearning.review(restored, in: reopened)
        precondition(removed.confirmed == nil)
        try TransactionOperationLearning.confirm(.roundUp, transaction: restored, in: reopened)
        restored.amountMinor += 1
        try reopened.save()
        let edited = try await TransactionOperationLearning.review(restored, in: reopened)
        precondition(edited.confirmed == nil, "A financial edit invalidates the old label")
        let staleSpecialized = try TransactionOperationLearning.specializedIDs(in: [restored], context: reopened)
        precondition(staleSpecialized.isEmpty)
        let local = try container("LocalFinance", "local.store")
        let isolated = try await TransactionOperationLearning.review(restored, in: local.mainContext)
        precondition(isolated.confirmed == nil && isolated.prediction == nil)
        do {
            try TransactionOperationLearning.confirm(.saveback, transaction: restored, in: local.mainContext)
            fatalError("A foreign context must not accept a label")
        } catch TransactionOperationLearning.LearningError.unavailable { }
        restored.notes = "Cambio sin guardar"
        do {
            try TransactionOperationLearning.confirm(.saveback, transaction: restored, in: reopened)
            fatalError("Uncommitted edits must block confirmation")
        } catch TransactionOperationLearning.LearningError.unavailable { }
        reopened.rollback()
        let sandbox = try container("BankingTests", "sandbox.store")
        let sandboxAccount = FinancialAccount(name: "Sandbox", type: .checking)
        let sandboxRow = FinancialTransaction(date: .now, type: .expense, amountMinor: 123,
            descriptionText: "Saveback", bankEntryKey: "bank:synthetic", sourceAccount: sandboxAccount)
        sandbox.mainContext.insert(sandboxAccount); sandbox.mainContext.insert(sandboxRow)
        try sandbox.mainContext.save()
        let sandboxReview = try await TransactionOperationLearning.review(sandboxRow, in: sandbox.mainContext)
        precondition(sandboxReview.confirmed == nil && sandboxReview.prediction == nil)
        print("Operation learning passed: persistence, corrections, invalidation, profile isolation, sandbox and unchanged finances.")
    }
}
