import Foundation
import SwiftData

@main
struct PersonalBankingImporterCheck {
    @MainActor static func main() throws {
        let schema = Schema([FinancialInstitution.self, FinancialAccount.self, PaymentCard.self, ReservedFund.self,
            FinanceCategory.self, FinancialTransaction.self, CategoryRule.self, MonthlyBudget.self, RecurringBudget.self,
            SavingsGoal.self, RecurringMovement.self, BalanceSnapshot.self, ImportBatch.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration("CloudFinance", schema: schema, isStoredInMemoryOnly: true))
        let context = container.mainContext
        let server = URL(string: "https://mi-bombo-banking-personal.albertor7722.workers.dev")!
        let day = ISO8601DateFormatter().date(from: "2026-10-15T00:00:00Z")!
        let observed = day.addingTimeInterval(86400)
        let local = FinancialAccount(name: "Mi cuenta existente", type: .checking, openingBalanceMinor: 10000,
            openingDate: day.addingTimeInterval(-86400))
        let category = FinanceCategory(name: "Formación", kind: .expense)
        let fund = ReservedFund(name: "Estudios", amountMinor: 6000, account: local)
        let paid = FinancialTransaction(date: day, type: .expense, amountMinor: 1000, descriptionText: "Universidad",
            notes: "Conservar", externalID: "csv-original", recurringMovementID: UUID(), reservedFundID: fund.id,
            reservedAmountMinor: 1000, sourceAccount: local, category: category)
        context.insert(local); context.insert(category); context.insert(fund); context.insert(paid)
        try context.save()
        let remote = ConnectedBankAccount(id: "stable-account", name: "Cuenta •••• 1234", currency: "EUR", lastFour: "1234")
        try PersonalBankingImporter.link(remote, bank: "Bankinter", server: server, to: local, in: context)
        let feed = BankingAccountFeed(connection: .init(id: UUID().uuidString, bank: "Bankinter", validUntil: "2026-11-01", accounts: [remote]),
            account: remote, balances: [.init(amountMinor: 9000, currency: "EUR", type: "CLBD")], movements: [
                .init(id: "bank-payment", bookingDate: "2026-10-15", signedAmountMinor: -1000, currency: "EUR", description: "Universidad")])
        let result = try PersonalBankingImporter.apply([feed], server: server, in: context, observedAt: observed)
        precondition(result.inserted == 0 && result.matched == 1)
        precondition(paid.externalID == "csv-original" && paid.bankEntryKey != nil)
        precondition(paid.reservedFundID == fund.id && paid.reservedAmountMinor == 1000 && paid.recurringMovementID != nil)
        precondition(paid.notes == "Conservar" && paid.category?.id == category.id)
        let snapshots = try context.fetch(FetchDescriptor<BalanceSnapshot>())
        precondition(FinanceCalculator.balance(of: local, at: observed, transactions: [paid], snapshots: snapshots) == 9000)
        precondition(FinanceCalculator.spendableCash(accounts: [local], funds: [fund], transactions: [paid], snapshots: snapshots) == 4000)
        precondition(FinanceCalculator.budgetExpenseAmount(for: paid) == 0)
        let repeatResult = try PersonalBankingImporter.apply([feed], server: server, in: context, observedAt: observed.addingTimeInterval(60))
        precondition(repeatResult.inserted == 0 && repeatResult.skipped == 1)
        let rows = try context.fetch(FetchDescriptor<FinancialTransaction>())
        precondition(rows.count == 1)
        // A periodic template remains available, but a linked bank owns actual postings.
        let recurring = RecurringMovement(name: "Suscripción", type: .expense, amountMinor: 500, descriptionText: "Suscripción",
            frequency: .monthly, nextDueDate: day, isActive: true, postsAutomatically: true, sourceAccount: local, category: category)
        context.insert(recurring); try context.save()
        let posted = try RecurringMovementService.postDueMovements(in: context, through: observed)
        precondition(posted == 0 && recurring.nextDueDate == day)
        let investment = FinancialAccount(name: "Inversión propia", type: .investment, openingDate: local.openingDate)
        let contribution = FinancialTransaction(date: day, type: .transfer, amountMinor: 2000, descriptionText: "Aportación",
            sourceAccount: local, destinationAccount: investment)
        context.insert(investment); context.insert(contribution); try context.save()
        let transferFeed = BankingAccountFeed(connection: feed.connection, account: remote,
            balances: [.init(amountMinor: 7000, currency: "EUR", type: "CLBD")], movements: feed.movements + [
                .init(id: "investment-payment", bookingDate: "2026-10-15", signedAmountMinor: -2000, currency: "EUR", description: "Aportación")])
        let transferResult = try PersonalBankingImporter.apply([transferFeed], server: server, in: context, observedAt: observed)
        precondition(transferResult.inserted == 0 && transferResult.matched == 1)
        precondition(contribution.type == .transfer && contribution.destinationAccount?.id == investment.id && contribution.bankEntryKey != nil)
        let afterTransfer = try context.fetch(FetchDescriptor<FinancialTransaction>())
        let month = FinanceCalculator.monthlySummary(for: observed, transactions: afterTransfer)
        precondition(afterTransfer.count == 2 && month.expenseMinor == 1000 && month.budgetExpenseMinor == 0,
                     "A Bankinter debit already recorded as an investment transfer must not become a second expense")
        // Live financial imports can never write to the separate sandbox workspace.
        let isolated = try ModelContainer(for: schema, configurations: ModelConfiguration("BankingTests", schema: schema, isStoredInMemoryOnly: true))
        do { _ = try PersonalBankingImporter.apply([feed], server: server, in: isolated.mainContext, observedAt: observed); preconditionFailure("Sandbox accepted real-account import") }
        catch PersonalBankingError.wrongWorkspace { }
        print("Personal banking importer passed: linked existing account, CSV provenance, reserve allocation, budget exclusion, snapshot balance, repeat imports and periodic posting suppression.")
    }
}
