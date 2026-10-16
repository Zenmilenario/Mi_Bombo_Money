import Foundation
import SwiftData

@main
struct BankingWorkspaceCheck {
    private static let server = URL(string: "https://bank-test.personal.workers.dev")!
    private static let observedAt = ISO8601DateFormatter().date(from: "2026-10-15T12:00:00Z")!

    @MainActor static func main() throws {
        try checkIntegrationAndIsolation()
        try checkValidationAndAtomicity()
        print("Banking workspace checks passed: accounts, monthly totals, categories, snapshot accounting, repeat sync, identity scoping, invalid batches and isolation.")
    }

    private static func feed(bank: String = "BBVA", id: String = "00000000-0000-0000-0000-000000000001",
                             rows: [BankingPreview.Movement]? = nil, balance: Int64 = 123_456) -> BankingAccountFeed {
        let account = ConnectedBankAccount(id: "demo-cash", name: "Efectivo de prueba", currency: "EUR", lastFour: "0000")
        return BankingAccountFeed(connection: ConnectedBankSession(id: id, bank: bank,
            validUntil: "2026-10-16T12:00:00Z", accounts: [account]), account: account,
            balances: [.init(amountMinor: balance, currency: "EUR", type: "CLBD")],
            movements: rows ?? [
                .init(id: "income", bookingDate: "2026-10-15", signedAmountMinor: 150_000, currency: "EUR", description: "Nómina ficticia"),
                .init(id: "expense", bookingDate: "2026-10-15", signedAmountMinor: -26_544, currency: "EUR", description: "Compra ficticia")
            ])
    }

    @MainActor private static func checkIntegrationAndIsolation() throws {
        let realStore = try makeContainer(name: "LocalFinance"); let testStore = try makeContainer()
        let real = ModelContext(realStore); let context = ModelContext(testStore)
        real.insert(FinancialAccount(name: "Mis ahorros reales", type: .savings, openingBalanceMinor: 999_999))
        try real.save()
        do {
            _ = try BankingWorkspaceImporter.apply([feed()], server: server, mode: "demo", in: real, observedAt: observedAt)
            preconditionFailure("Fictitious data must never enter the real finance configuration")
        } catch is BankingWorkspaceError { }
        try CategoryDefaultsService.restoreMissing(in: context)
        let categories = try context.fetch(FetchDescriptor<FinanceCategory>())
        let salary = categories.first { $0.name == "Nómina" }!
        context.insert(CategoryRule(phrase: "Nómina", transactionType: .income, category: salary))
        try context.save()
        let first = try BankingWorkspaceImporter.apply([feed()], server: server, mode: "demo", in: context, observedAt: observedAt)
        precondition(first.accounts == 1 && first.inserted == 2)
        let accounts = try context.fetch(FetchDescriptor<FinancialAccount>())
        let transactions = try context.fetch(FetchDescriptor<FinancialTransaction>())
        let snapshots = try context.fetch(FetchDescriptor<BalanceSnapshot>())
        precondition(accounts.count == 1 && accounts[0].institution?.name == "BBVA")
        precondition(transactions.count == 2 && snapshots.count == 1)
        precondition(transactions.first { $0.type == .income }?.category?.id == salary.id)
        let summary = FinanceCalculator.monthlySummary(for: observedAt, transactions: transactions)
        precondition(summary.incomeMinor == 150_000 && summary.expenseMinor == 26_544 && summary.netSavingsMinor == 123_456)
        precondition(FinanceCalculator.balance(of: accounts[0], at: observedAt, transactions: transactions, snapshots: snapshots) == 123_456,
                     "Bank balance must not have imported history added twice")
        let spendingCategory = categories.first { $0.name == "Otros gastos" }!
        let budget = MonthlyBudget(monthStart: observedAt.startOfMonth(), limitMinor: 20_000, category: spendingCategory)
        context.insert(budget)
        try context.save()
        let progress = FinanceCalculator.budgetProgress(for: observedAt, categories: categories,
            budgets: [budget], transactions: transactions).first { $0.category.id == spendingCategory.id }
        precondition(progress?.spentMinor == 26_544 && progress?.availableMinor == -6_544,
                     "Imported expenses must reach the existing budget calculations")
        // User categorization must survive repeated synchronization.
        let expense = transactions.first { $0.type == .expense }!
        expense.category = categories.first { $0.name == "Compras" }!
        try context.save()
        let second = try BankingWorkspaceImporter.apply([feed()], server: server, mode: "demo", in: context, observedAt: observedAt.addingTimeInterval(60))
        precondition(second.inserted == 0 && second.skipped == 2)
        precondition(expense.category?.name == "Compras")
        try expectCount(FinancialTransaction.self, 2, in: context)
        try expectCount(BalanceSnapshot.self, 1, in: context)
        let realAccounts = try real.fetch(FetchDescriptor<FinancialAccount>())
        precondition(realAccounts.count == 1 && realAccounts[0].openingBalanceMinor == 999_999)
        try expectCount(FinancialTransaction.self, 0, in: real)
        // Same provider record IDs in another account/bank must not collide.
        let another = feed(bank: "Bankinter", id: "00000000-0000-0000-0000-000000000002")
        let third = try BankingWorkspaceImporter.apply([feed(), another], server: server, mode: "demo", in: context, observedAt: observedAt.addingTimeInterval(120))
        precondition(third.inserted == 2 && third.skipped == 2)
        try expectCount(FinancialAccount.self, 2, in: context)
    }

    @MainActor private static func checkValidationAndAtomicity() throws {
        let store = try makeContainer(); let context = ModelContext(store)
        let invalid = BankingPreview.Movement(id: nil, bookingDate: "2026-10-15", signedAmountMinor: 100, currency: "EUR", description: "Sin ID")
        for bad in [invalid,
                    .init(id: "bad-date", bookingDate: "2026-02-30", signedAmountMinor: 100, currency: "EUR", description: "Fecha inválida"),
                    .init(id: "overflow", bookingDate: "2026-10-15", signedAmountMinor: Int64.min, currency: "EUR", description: "Importe inválido")] {
            do {
                _ = try BankingWorkspaceImporter.apply([feed(), feed(id: "00000000-0000-0000-0000-000000000002", rows: [bad])],
                    server: server, mode: "demo", in: context, observedAt: observedAt)
                preconditionFailure("Malformed batch accepted")
            } catch is BankingWorkspaceError { }
            try expectCount(FinancialAccount.self, 0, in: context)
            precondition(!context.hasChanges)
        }
        do {
            _ = try BankingWorkspaceImporter.apply([feed()], server: server, mode: "production", in: context, observedAt: observedAt)
            preconditionFailure("Real banking entered the testing workspace")
        } catch is BankingWorkspaceError { }
        let pending = FinancialAccount(name: "Formulario sin guardar", type: .cash)
        context.insert(pending)
        do {
            _ = try BankingWorkspaceImporter.apply([feed()], server: server, mode: "demo", in: context, observedAt: observedAt)
            preconditionFailure("Unsaved user changes must not be mixed with synchronization")
        } catch is BankingWorkspaceError { }
        precondition(context.hasChanges, "The importer must not roll back another form's edits")
    }

    @MainActor private static func makeContainer(name: String? = nil) throws -> ModelContainer {
        let schema = Schema([
            FinancialInstitution.self, FinancialAccount.self, PaymentCard.self, ReservedFund.self,
            FinanceCategory.self, CategoryRule.self, FinancialTransaction.self, MonthlyBudget.self,
            RecurringBudget.self, SavingsGoal.self, RecurringMovement.self, BalanceSnapshot.self, ImportBatch.self
        ])
        return try ModelContainer(for: schema, configurations: ModelConfiguration(name, schema: schema, isStoredInMemoryOnly: true))
    }

    @MainActor private static func expectCount<T: PersistentModel>(_ type: T.Type, _ expected: Int, in context: ModelContext) throws {
        let count = try context.fetchCount(FetchDescriptor<T>())
        precondition(count == expected, "Unexpected persisted record count")
    }
}
