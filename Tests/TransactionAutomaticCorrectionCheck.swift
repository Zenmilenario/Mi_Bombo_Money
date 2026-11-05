import Foundation
import SwiftData

@main
struct TransactionAutomaticCorrectionCheck {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("correction-learning-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = Schema([FinancialInstitution.self, FinancialAccount.self, PaymentCard.self, ReservedFund.self,
            FinanceCategory.self, FinancialTransaction.self, CategoryRule.self, MonthlyBudget.self, RecurringBudget.self,
            SavingsGoal.self, RecurringMovement.self, BalanceSnapshot.self, ImportBatch.self])
        func container(_ name: String, _ file: String) throws -> ModelContainer {
            try ModelContainer(for: schema, configurations: ModelConfiguration(name, schema: schema,
                url: directory.appendingPathComponent(file), allowsSave: true, cloudKitDatabase: .none))
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func date(_ month: Int, _ day: Int) -> Date {
            calendar.date(from: DateComponents(year: 2019, month: month, day: day))!
        }
        let cloud = try container("CloudFinance", "cloud.store"), context = cloud.mainContext
        context.autosaveEnabled = false
        let account = FinancialAccount(name: "Efectivo ficticio", type: .checking,
            openingBalanceMinor: 100000, openingDate: date(1, 1))
        let investment = FinancialAccount(name: "Inversión ficticia", type: .investment, openingDate: date(1, 1))
        let contribution = FinanceCategory(name: "Aportación", kind: .transfer)
        let purchase = FinanceCategory(name: "Compras", kind: .expense)
        context.insert(account); context.insert(investment); context.insert(contribution); context.insert(purchase)
        try context.save()
        func row(_ month: Int, _ day: Int, _ amount: Int64) -> FinancialTransaction {
            FinancialTransaction(date: date(month, day), type: .expense, amountMinor: amount,
                descriptionText: "Movimiento bancario", notes: "Conservar nota", fingerprint: "original",
                bankEntryKey: "bank:synthetic:" + UUID().uuidString, importBatchID: UUID(),
                sourceAccount: account)
        }
        // Human labels only: paired, distinct bank observations over successive periods.
        for month in 1...6 {
            for index in 0..<3 {
                let positive = row(month, 2 + index, Int64(230 + index * 3))
                context.insert(positive); try context.save()
                let before = try TransactionOperationLearning.captureEdit(positive, in: context)
                positive.type = .transfer; positive.destinationAccount = investment; positive.category = contribution
                // Learning must retain the original input even when a person cleans up the name.
                positive.descriptionText = "Redondeo confirmado"
                try TransactionOperationLearning.rememberEdit(before, after: positive, in: context)
                try context.save()
                let negative = row(month, 15 + index, Int64(9000 + index * 100))
                context.insert(negative); try context.save()
                let negativeBefore = try TransactionOperationLearning.captureEdit(negative, in: context)
                negative.category = purchase
                try TransactionOperationLearning.rememberEdit(negativeBefore, after: negative, in: context)
                try context.save()
            }
        }
        let candidate = row(7, 3, 234)
        context.insert(candidate); try context.save()
        let identity = candidate.id, bankKey = candidate.bankEntryKey, batch = candidate.importBatchID
        let initialCount = try context.fetch(FetchDescriptor<FinancialTransaction>()).count
        let applied = try await TransactionOperationLearning.applyLearnedCorrections(in: context)
        precondition(applied == 1, "A validated correction must apply to a new bank observation")
        precondition(candidate.id == identity && candidate.type == .transfer && candidate.destinationAccount?.id == investment.id
            && candidate.category?.id == contribution.id && candidate.amountMinor == 234 && candidate.date == date(7, 3)
            && candidate.bankEntryKey == bankKey && candidate.importBatchID == batch && candidate.notes == "Conservar nota"
            && candidate.descriptionText == "Movimiento bancario" && account.openingBalanceMinor == 100000,
            "Automation must preserve bank facts, notes and balances")
        let finalCount = try context.fetch(FetchDescriptor<FinancialTransaction>()).count
        precondition(finalCount == initialCount, "Never create a second bank entry")
        let status = try TransactionOperationLearning.automationStatus(for: candidate, in: context)
        precondition(status.automaticallyApplied && status.savedExamples == 36 && status.validatedPredictions >= 3,
            "Automatic decisions must not become human training examples")
        let repeated = try await TransactionOperationLearning.applyLearnedCorrections(in: context)
        precondition(repeated == 0)

        // A staged but rolled-back manual edit must not erase the automatic undo record.
        let staged = try TransactionOperationLearning.captureEdit(candidate, in: context)
        candidate.category = nil
        try TransactionOperationLearning.rememberEdit(staged, after: candidate, in: context)
        context.rollback()
        let restored = try context.fetch(FetchDescriptor<FinancialTransaction>()).first { $0.id == identity }!
        let afterRollback = try TransactionOperationLearning.automationStatus(for: restored, in: context)
        precondition(afterRollback.automaticallyApplied)
        try TransactionOperationLearning.undoAutomaticCorrection(restored, in: context)
        precondition(restored.type == .expense && restored.category == nil && restored.destinationAccount == nil
            && restored.fingerprint == "original" && restored.amountMinor == 234 && restored.bankEntryKey == bankKey)
        let undone = try await TransactionOperationLearning.applyLearnedCorrections(in: context)
        precondition(undone == 0, "An explicit rejection must never immediately repeat")

        let next = row(7, 4, 236)
        context.insert(next); try context.save()
        try TransactionOperationLearning.setAutomationEnabled(false, in: context)
        let disabled = try await TransactionOperationLearning.applyLearnedCorrections(in: context)
        precondition(disabled == 0 && next.type == .expense)
        try TransactionOperationLearning.setAutomationEnabled(true, in: context)
        let editing = try await TransactionOperationLearning.applyLearnedCorrections(in: context, canRun: { false })
        precondition(editing == 0, "Do not change a transaction while a form is open")

        let desired = TransactionCorrectionModel.Action(type: "transfer", destinationID: investment.id, categoryID: contribution.id)
        func allowed(_ other: [FinancialTransaction] = []) -> Bool {
            TransactionOperationLearning.canApply(desired, to: next, accounts: [account, investment],
                categories: [contribution, purchase], transactions: other)
        }
        precondition(allowed())
        next.reservedFundID = UUID(); precondition(!allowed()); next.reservedFundID = nil
        next.reservedAmountMinor = 100; precondition(!allowed()); next.reservedAmountMinor = nil
        next.recurringMovementID = UUID(); precondition(!allowed()); next.recurringMovementID = nil
        next.externalID = "csv"; precondition(!allowed()); next.externalID = nil
        next.duplicateState = .possible; precondition(!allowed()); next.duplicateState = .none
        next.category = purchase; precondition(!allowed()); next.category = nil
        investment.isArchived = true; precondition(!allowed()); investment.isArchived = false
        investment.currencyCode = "USD"; precondition(!allowed()); investment.currencyCode = "EUR"
        investment.bankIdentityKey = "bank:linked"; precondition(!allowed()); investment.bankIdentityKey = nil
        contribution.isArchived = true; precondition(!allowed()); contribution.isArchived = false
        let counterpart = row(7, 4, 236)
        counterpart.type = .income; counterpart.sourceAccount = investment
        precondition(!allowed([counterpart]), "A possible already-imported investment leg requires review")
        counterpart.type = .transfer; counterpart.sourceAccount = account; counterpart.destinationAccount = investment
        counterpart.bankEntryKey = nil
        precondition(!allowed([counterpart]), "Never duplicate a manually registered contribution")
        counterpart.bankEntryKey = "bank:different"
        precondition(allowed([counterpart]), "Two distinct genuine bank debits may have the same amount")
        try context.save()

        // A rejected nearby operation remains counter-evidence after reopening the store.
        let reopened = ModelContext(cloud)
        reopened.autosaveEnabled = false
        let persisted = try reopened.fetch(FetchDescriptor<FinancialTransaction>()).first { $0.id == next.id }!
        let resumed = try await TransactionOperationLearning.applyLearnedCorrections(in: reopened)
        precondition(resumed == 0 && persisted.type == .expense, "A human rejection must reduce automation, including after reopening")
        let audit = try TransactionOperationLearning.automationStatus(for: persisted, in: reopened)
        precondition(!audit.automaticallyApplied && audit.savedExamples == 37)
        let local = try container("LocalFinance", "local.store")
        let isolated = try await TransactionOperationLearning.applyLearnedCorrections(in: local.mainContext)
        precondition(isolated == 0)
        let sandbox = try container("BankingTests", "sandbox.store")
        let excluded = try await TransactionOperationLearning.applyLearnedCorrections(in: sandbox.mainContext)
        precondition(excluded == 0)
        print("Automatic corrections passed: human learning, temporal validation, preservation, undo, rollback, pause, guards and isolation.")
    }
}
