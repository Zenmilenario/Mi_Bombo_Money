import Foundation
import SwiftData

@main
struct BankingWorkspaceCheck {
    private static let server = URL(string: "https://bank-test.personal.workers.dev")!
    private static let observedAt = ISO8601DateFormatter().date(from: "2026-10-15T12:00:00Z")!

    @MainActor static func main() throws {
        try checkIntegrationAndIsolation()
        try checkValidationAndAtomicity()
        try checkEnvironmentStores()
        try checkUnsupportedBalances()
        try checkCompleteScenario()
        print("Banking workspace checks passed: accounts, monthly totals, categories, snapshot accounting, repeat sync, identity scoping, invalid batches and isolation.")
    }

    private static func checkEnvironmentStores() throws {
        let demo = try BankingWorkspaceImporter.storeFilename(server: server, mode: "demo")
        let sandbox = try BankingWorkspaceImporter.storeFilename(server: server, mode: "sandbox")
        let other = try BankingWorkspaceImporter.storeFilename(server: URL(string: "https://other.personal.workers.dev")!, mode: "sandbox")
        precondition(demo != sandbox && sandbox != other, "Servers and environments must have separate stores")
        let canonical = try BankingWorkspaceImporter.storeFilename(server: URL(string: server.absoluteString + "/")!, mode: "sandbox")
        precondition(canonical == sandbox)
        precondition(sandbox != "MiPatrimonio.store" && !sandbox.contains("/"))
        do {
            _ = try BankingWorkspaceImporter.storeFilename(server: server, mode: "production")
            preconditionFailure("Production store accepted")
        } catch is BankingWorkspaceError { }
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

    private struct Fixture: Decodable {
        struct Feed: Decodable {
            let connection: ConnectedBankSession
            let account: ConnectedBankAccount
            let balances: [BankingPreview.Balance]
            let movements: [BankingPreview.Movement]
            var feed: BankingAccountFeed { .init(connection: connection, account: account, balances: balances, movements: movements) }
        }
        struct Expected: Decodable { let asOf: String; let appMovements: Int; let netWorthMinor: Int64 }
        let feeds: [Feed]; let expected: Expected
    }

    @MainActor private static func checkCompleteScenario() throws {
        let file = URL(fileURLWithPath: "build/banking-workspace-check/scenario.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: file))
        let date = ISO8601DateFormatter().date(from: fixture.expected.asOf + "T12:00:00Z")!
        let scenario = BankingWorkspaceImporter.scenarioID
        let store = try makeContainer(); let context = ModelContext(store)
        try CategoryDefaultsService.restoreMissing(in: context)
        let first = try BankingWorkspaceImporter.apply(fixture.feeds.map(\.feed), server: server, mode: "sandbox",
            in: context, observedAt: date, scenario: scenario)
        precondition(first.accounts == 3 && first.inserted == fixture.expected.appMovements && first.warnings.isEmpty)
        let accounts = try context.fetch(FetchDescriptor<FinancialAccount>())
        let rows = try context.fetch(FetchDescriptor<FinancialTransaction>())
        let snapshots = try context.fetch(FetchDescriptor<BalanceSnapshot>())
        precondition(rows.count == 69 && rows.filter { $0.type == .transfer }.count == 6)
        precondition(rows.filter { $0.descriptionText.hasPrefix("Café") }.count == 6, "Different purchases must survive matching")
        precondition(rows.allSatisfy { $0.category != nil }, "Every synthetic transaction must be categorized")
        precondition(accounts.filter { $0.type == .investment }.count == 1)
        precondition(FinanceCalculator.netWorth(accounts: accounts, transactions: rows, snapshots: snapshots, at: date) == fixture.expected.netWorthMinor)
        let summary = FinanceCalculator.monthlySummary(for: date, transactions: rows)
        precondition(summary.incomeMinor == 254_000 && summary.expenseMinor == 145_294 && summary.netSavingsMinor == 108_706)
        let funds = try context.fetch(FetchDescriptor<ReservedFund>())
        precondition(funds.count == 1 && funds[0].amountMinor == 150_000)
        precondition(FinanceCalculator.spendableCash(accounts: accounts, funds: funds, transactions: rows, snapshots: snapshots) == 397_968)
        let categories = try context.fetch(FetchDescriptor<FinanceCategory>())
        let budgets = try context.fetch(FetchDescriptor<RecurringBudget>())
        precondition(budgets.count == 4 && budgets.contains { $0.remainderChoice == .carryForward })
        let progress = FinanceCalculator.budgetProgress(for: date, categories: categories, budgets: [], recurringBudgets: budgets, transactions: rows)
        precondition(progress.first { $0.category.name == "Supermercado" }?.availableMinor == -2_395)
        let recurring = try context.fetch(FetchDescriptor<RecurringMovement>())
        precondition(recurring.count == 2 && recurring.allSatisfy { !$0.isActive && $0.nextDueDate > date })
        try expectCount(PaymentCard.self, 1, in: context)
        // Renewed consents must not create another copy of this known synthetic scenario.
        let renewed = fixture.feeds.reversed().map { data in
            BankingAccountFeed(connection: ConnectedBankSession(id: UUID().uuidString, bank: data.connection.bank,
                validUntil: data.connection.validUntil, accounts: data.connection.accounts, testScenario: scenario),
                account: data.account, balances: data.balances, movements: data.movements)
        }
        let second = try BankingWorkspaceImporter.apply(renewed, server: server, mode: "sandbox", in: context,
            observedAt: date.addingTimeInterval(60), scenario: scenario)
        precondition(second.inserted == 0 && second.skipped == 69)
        try expectCount(FinancialTransaction.self, 69, in: context)
        try expectCount(FinancialAccount.self, 3, in: context)
        try expectCount(ReservedFund.self, 1, in: context)
        try expectCount(RecurringBudget.self, 4, in: context)
        try expectCount(CategoryRule.self, 17, in: context)
        // Refresh must respect user deletions of optional local examples.
        let card = try context.fetch(FetchDescriptor<PaymentCard>())[0]
        context.delete(card); context.delete(budgets[0])
        try context.save()
        _ = try BankingWorkspaceImporter.apply(renewed, server: server, mode: "sandbox", in: context,
            observedAt: date.addingTimeInterval(120), scenario: scenario)
        try expectCount(PaymentCard.self, 0, in: context)
        try expectCount(RecurringBudget.self, 3, in: context)
        let ordinary = try BankingWorkspaceImporter.storeFilename(server: server, mode: "sandbox")
        let complete = try BankingWorkspaceImporter.storeFilename(server: server, mode: "sandbox", scenario: scenario)
        precondition(ordinary != complete, "The user's old manual sandbox workspace must remain separate")
    }

    @MainActor private static func checkUnsupportedBalances() throws {
        let store = try makeContainer(); let context = ModelContext(store)
        let ordinary = feed()
        let unsupported = ["OPBD", "XPCD", "ITAV"].enumerated().map { index, type in
            let base = feed(id: "00000000-0000-0000-0000-00000000000\(index + 2)")
            return BankingAccountFeed(connection: base.connection, account: base.account,
                balances: [.init(amountMinor: 99999, currency: "EUR", type: type)], movements: [])
        }
        let result = try BankingWorkspaceImporter.apply([ordinary] + unsupported, server: server,
            mode: "sandbox", in: context, observedAt: observedAt)
        precondition(result.accounts == 1 && result.inserted == 2 && result.warnings.count == 3)
        let intraday = BankingAccountFeed(connection: ordinary.connection, account: ordinary.account,
            balances: [.init(amountMinor: 10000, currency: "EUR", type: "ITBD"),
                       .init(amountMinor: 9000, currency: "EUR", type: "CLBD")], movements: ordinary.movements)
        let updated = try BankingWorkspaceImporter.apply([intraday], server: server, mode: "sandbox", in: context, observedAt: observedAt)
        precondition(updated.warnings.isEmpty && updated.inserted == 0)
        let snapshots = try context.fetch(FetchDescriptor<BalanceSnapshot>())
        precondition(snapshots.count == 1 && snapshots[0].balanceMinor == 10000)
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
