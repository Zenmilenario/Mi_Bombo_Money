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
                .init(id: "bank-payment", bookingDate: "2026-10-15", signedAmountMinor: -1000, currency: "EUR", description: "/TXT/D|Universidad")])
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
        // A different description becomes an explicit proposal, preserving the full manual record on acceptance.
        let extra = FinancialTransaction(date: day, type: .expense, amountMinor: 750, descriptionText: "Material para estudiar",
            notes: "Mi nota", reservedFundID: fund.id, reservedAmountMinor: 750, sourceAccount: local, category: category)
        context.insert(extra); try context.save()
        let proposalFeed = BankingAccountFeed(connection: feed.connection, account: remote,
            balances: [.init(amountMinor: 6250, currency: "EUR", type: "CLBD")], movements: transferFeed.movements + [
                .init(id: "other-description", bookingDate: "2026-10-15", signedAmountMinor: -750, currency: "EUR", description: "/TXT/D|Academia cuota")])
        let proposalPlan = try PersonalBankingImporter.plan([proposalFeed], server: server, in: context)
        precondition(proposalPlan.items.count == 1 && proposalPlan.items[0].suggestedMatch == extra.id)
        do { _ = try PersonalBankingImporter.apply([proposalFeed], server: server, in: context, observedAt: observed); preconditionFailure("Unconfirmed proposal was applied") }
        catch PersonalBankingError.needsReview { }
        precondition(extra.bankEntryKey == nil)
        let confirmed = try PersonalBankingImporter.apply([proposalFeed], server: server,
            choices: proposalPlan.acceptingSuggestions([:]), in: context, observedAt: observed)
        precondition(confirmed.inserted == 0 && confirmed.matched == 1)
        precondition(extra.bankEntryKey != nil && extra.notes == "Mi nota" && extra.descriptionText == "Material para estudiar")
        precondition(extra.category?.id == category.id && extra.reservedFundID == fund.id && extra.reservedAmountMinor == 750)
        let afterBulk = try context.fetch(FetchDescriptor<FinancialTransaction>())
        precondition(afterBulk.count == 3)
        let repeatedBulk = try PersonalBankingImporter.apply([proposalFeed], server: server, in: context, observedAt: observed)
        precondition(repeatedBulk.inserted == 0 && repeatedBulk.matched == 0 && repeatedBulk.skipped == 3)
        // One bank's ordinary postings can be imported while an own transfer waits for its peer.
        let partialContainer = try ModelContainer(for: schema, configurations: ModelConfiguration("CloudFinance", schema: schema, isStoredInMemoryOnly: true))
        let partialContext = partialContainer.mainContext
        let firstAccount = FinancialAccount(name: "Synthetic A", type: .checking, openingBalanceMinor: 10000, openingDate: day.addingTimeInterval(-86400))
        let secondAccount = FinancialAccount(name: "Synthetic B", type: .checking, openingBalanceMinor: 5000, openingDate: day.addingTimeInterval(-86400))
        partialContext.insert(firstAccount); partialContext.insert(secondAccount); try partialContext.save()
        let a = ConnectedBankAccount(id: "independent-a", name: "Synthetic A", currency: "EUR", lastFour: "0000", ownershipKey: "own-a")
        let b = ConnectedBankAccount(id: "independent-b", name: "Synthetic B", currency: "EUR", lastFour: "0000", ownershipKey: "own-b")
        try PersonalBankingImporter.link(a, bank: "Bankinter", server: server, to: firstAccount, in: partialContext)
        try PersonalBankingImporter.link(b, bank: "BBVA", server: server, to: secondAccount, in: partialContext)
        let aFeed = BankingAccountFeed(connection: .init(id: UUID().uuidString, bank: "Bankinter", validUntil: "2099-01-01", accounts: [a]),
            account: a, balances: [.init(amountMinor: 5000, currency: "EUR", type: "CLBD")], movements: [
                .init(id: "out", bookingDate: "2026-10-15", signedAmountMinor: -5000, currency: "EUR", description: "Synthetic transfer", counterpartyKey: "own-b", transferKey: "pair")])
        let bFeed = BankingAccountFeed(connection: .init(id: UUID().uuidString, bank: "BBVA", validUntil: "2099-01-01", accounts: [b]),
            account: b, balances: [.init(amountMinor: 9250, currency: "EUR", type: "CLBD")], movements: [
                .init(id: "in", bookingDate: "2026-10-15", signedAmountMinor: 5000, currency: "EUR", description: "Synthetic transfer", counterpartyKey: "own-a", transferKey: "pair"),
                .init(id: "expense", bookingDate: "2026-10-15", signedAmountMinor: -750, currency: "EUR", description: "Synthetic purchase")])
        let independent = try PersonalBankingDownloadSelection.prepare([bFeed], knownAccounts: [a, b])
        let firstResult = try PersonalBankingImporter.apply(independent.feeds, server: server, in: partialContext, observedAt: observed)
        let firstRows = try partialContext.fetch(FetchDescriptor<FinancialTransaction>())
        precondition(firstResult.inserted == 1 && firstRows.count == 1 && firstRows[0].type == .expense)
        precondition(FinanceCalculator.monthlySummary(for: observed, transactions: firstRows).incomeMinor == 0)
        let complete = try PersonalBankingDownloadSelection.prepare([aFeed, bFeed], knownAccounts: [a, b])
        let recovered = try PersonalBankingImporter.apply(complete.feeds, server: server, in: partialContext, observedAt: observed)
        let recoveredRows = try partialContext.fetch(FetchDescriptor<FinancialTransaction>())
        let recoveredSnapshots = try partialContext.fetch(FetchDescriptor<BalanceSnapshot>())
        precondition(recovered.inserted == 1 && recoveredRows.count == 2 && recoveredRows.filter { $0.type == .transfer }.count == 1)
        let recoveredSummary = FinanceCalculator.monthlySummary(for: observed, transactions: recoveredRows)
        precondition(recoveredSummary.expenseMinor == 750 && recoveredSummary.incomeMinor == 0)
        precondition(FinanceCalculator.balance(of: firstAccount, at: observed, transactions: recoveredRows, snapshots: recoveredSnapshots) == 5000)
        precondition(FinanceCalculator.balance(of: secondAccount, at: observed, transactions: recoveredRows, snapshots: recoveredSnapshots) == 9250)
        let repeatedRecovery = try PersonalBankingImporter.apply(complete.feeds, server: server, in: partialContext, observedAt: observed)
        precondition(repeatedRecovery.inserted == 0 && repeatedRecovery.skipped == 2)
        let plainDebit = BankingAccountFeed(connection: aFeed.connection, account: a, balances: aFeed.balances, movements: [
            .init(id: "text-debit", bookingDate: "2026-10-15", signedAmountMinor: -1250, currency: "EUR", description: "/TXT/D|TRANS INM/ Persona Ficticia")])
        let plainCredit = BankingAccountFeed(connection: bFeed.connection, account: b, balances: bFeed.balances, movements: [
            .init(id: "text-credit", bookingDate: "2026-10-15", signedAmountMinor: 1250, currency: "EUR", description: "Movimiento bancario")])
        let plainFeeds = [plainDebit, plainCredit]
        let initialPlain = try PersonalBankingImporter.apply(plainFeeds, server: server, in: partialContext, observedAt: observed)
        precondition(initialPlain.inserted == 2)
        let plainRows = try partialContext.fetch(FetchDescriptor<FinancialTransaction>()).filter { $0.amountMinor == 1250 }
        let debit = plainRows.first { $0.type == .expense }!, credit = plainRows.first { $0.type == .income }!
        let bankKeys = Set([debit.bankEntryKey!, credit.bankEntryKey!])
        let retainedID = credit.id
        precondition(PersonalBankingImporter.canPairImportedTransfer(credit, with: debit))
        try PersonalBankingImporter.pairImportedTransfer(credit, with: debit, in: partialContext)
        let pairedRows = try partialContext.fetch(FetchDescriptor<FinancialTransaction>())
        let combined = pairedRows.first { $0.id == retainedID }!
        let combinedKeys = Set(try PersonalBankingPlan.keys(combined.bankEntryKey))
        precondition(pairedRows.count == recoveredRows.count + 1 && combined.type == .transfer && combinedKeys == bankKeys)
        precondition(combined.sourceAccount?.id == firstAccount.id && combined.destinationAccount?.id == secondAccount.id)
        precondition(combined.notes.contains("TRANS INM/") && combined.descriptionText == "Movimiento bancario")
        let pairedSummary = FinanceCalculator.monthlySummary(for: observed, transactions: pairedRows)
        precondition(pairedSummary.expenseMinor == recoveredSummary.expenseMinor && pairedSummary.incomeMinor == recoveredSummary.incomeMinor)
        let repeatPlain = try PersonalBankingImporter.apply(plainFeeds, server: server, in: partialContext, observedAt: observed)
        precondition(repeatPlain.inserted == 0 && repeatPlain.skipped == 2)
        try checkTradeRepublicWithoutBookedBalance(server: server, in: context, day: day, observed: observed)
        try checkSplitContributions(server: server, in: context, day: day, observed: observed)
        // Live financial imports can never write to the separate sandbox workspace.
        let isolated = try ModelContainer(for: schema, configurations: ModelConfiguration("BankingTests", schema: schema, isStoredInMemoryOnly: true))
        do { _ = try PersonalBankingImporter.apply([feed], server: server, in: isolated.mainContext, observedAt: observed); preconditionFailure("Sandbox accepted real-account import") }
        catch PersonalBankingError.wrongWorkspace { }
        print("Personal banking importer passed: linked existing account, CSV provenance, reserve allocation, budget exclusion, snapshot balance, repeat imports and periodic posting suppression.")
    }

    @MainActor private static func checkSplitContributions(server: URL, in context: ModelContext, day: Date, observed: Date) throws {
        let cash = FinancialAccount(name: "Efectivo de prueba", type: .checking, openingDate: day.addingTimeInterval(-86400))
        let portfolio = FinancialAccount(name: "Valores de prueba", type: .investment, openingDate: cash.openingDate)
        let rule = RecurringMovement(name: "Inversión periódica", type: .transfer, amountMinor: 35000,
            descriptionText: "Inversión", frequency: .monthly, nextDueDate: day,
            sourceAccount: cash, destinationAccount: portfolio)
        let planned = FinancialTransaction(date: day, type: .transfer, amountMinor: 35000, descriptionText: "Previsión",
            notes: "Conservar esta nota", recurringMovementID: rule.id, sourceAccount: cash, destinationAccount: portfolio)
        context.insert(cash); context.insert(portfolio); context.insert(rule); context.insert(planned)
        try context.save()
        let remote = ConnectedBankAccount(id: "contribution-test", name: "Prueba", currency: "EUR", lastFour: "0000")
        try PersonalBankingImporter.link(remote, bank: "Banco de prueba", server: server, to: cash, in: context)
        let feed = BankingAccountFeed(connection: .init(id: UUID().uuidString, bank: "Banco de prueba", validUntil: "2026-11-01", accounts: [remote]),
            account: remote, balances: [.init(amountMinor: 88000, currency: "EUR", type: "CLBD")], movements: [
                .init(id: "one", bookingDate: "2026-10-15", signedAmountMinor: -12000, currency: "EUR", description: "Movimiento bancario"),
                .init(id: "two", bookingDate: "2026-10-15", signedAmountMinor: -23000, currency: "EUR", description: "Movimiento bancario")])
        let imported = try PersonalBankingImporter.apply([feed], server: server, in: context, observedAt: observed)
        precondition(imported.inserted == 2)
        let before = try context.fetch(FetchDescriptor<FinancialTransaction>())
        let proposal = PersonalBankingImporter.contributionProposals(recurring: [rule], transactions: before, at: observed).first!
        guard case .unique(let ids) = proposal.match else { preconditionFailure("Uneven split was not recognized") }
        precondition(ids.count == 2 && proposal.planned.map(\.id) == [planned.id])
        let bankKeys = Set(before.filter { ids.contains($0.id) }.compactMap(\.bankEntryKey))
        try PersonalBankingImporter.confirmContribution(proposal, selectedIDs: ids, in: context)
        let after = try context.fetch(FetchDescriptor<FinancialTransaction>())
        let recognized = after.filter { ids.contains($0.id) }
        precondition(!after.contains { $0.id == planned.id })
        precondition(recognized.count == 2 && recognized.allSatisfy {
            $0.type == .transfer && $0.destinationAccount?.id == portfolio.id && $0.recurringMovementID == rule.id
                && $0.notes.contains("Conservar esta nota")
        })
        precondition(Set(recognized.compactMap(\.bankEntryKey)) == bankKeys)
        precondition(FinanceCalculator.investmentFlows(for: portfolio, month: day, transactions: after, at: observed).contributedMinor == 35000)
        precondition(PersonalBankingImporter.contributionProposals(recurring: [rule], transactions: after, at: observed).isEmpty)
        do {
            try PersonalBankingImporter.confirmContribution(proposal, selectedIDs: ids, in: context)
            preconditionFailure("The same contribution was applied twice")
        } catch PersonalBankingError.changed { }
        let repeated = try PersonalBankingImporter.apply([feed], server: server, in: context, observedAt: observed)
        precondition(repeated.inserted == 0 && repeated.skipped == 2)
        cash.bankIdentityKey = nil
        rule.postsAutomatically = true
        rule.nextDueDate = day.addingTimeInterval(-86400)
        try context.save()
        let automaticallyPosted = try RecurringMovementService.postDueMovements(in: context, through: observed)
        precondition(automaticallyPosted == 0 && rule.nextDueDate > observed,
                     "Recognized split contributions must not be generated again after disconnecting the bank")
    }

    @MainActor private static func checkTradeRepublicWithoutBookedBalance(server: URL, in context: ModelContext,
                                                                         day: Date, observed: Date) throws {
        let local = FinancialAccount(name: "Trade Republic ficticia", type: .checking, openingDate: day.addingTimeInterval(-86400))
        context.insert(local)
        try context.save()
        let remote = ConnectedBankAccount(id: "trade-test", name: "Prueba", currency: "EUR", lastFour: "0000")
        try PersonalBankingImporter.link(remote, bank: "Trade Republic", server: server, to: local, in: context)
        let feed = BankingAccountFeed(connection: .init(id: UUID().uuidString, bank: "Trade Republic", validUntil: "2026-11-01", accounts: [remote]),
            account: remote, balances: [.init(amountMinor: 40000, currency: "EUR", type: "CLAV")], movements: [
                .init(id: nil, bookingDate: "2026-10-15", signedAmountMinor: -2000, currency: "EUR", description: "Movimiento bancario"),
                .init(id: nil, bookingDate: "2026-10-16", signedAmountMinor: -1000, currency: "EUR", description: "Movimiento bancario")])
        let plan = try PersonalBankingImporter.plan([feed], server: server, in: context)
        do {
            _ = try PersonalBankingImporter.apply([feed], server: server, in: context, observedAt: observed)
            preconditionFailure("An import without a booked balance bypassed review")
        } catch PersonalBankingError.needsReview { }
        let manual = [local.id: PersonalBankingImporter.ManualBalance(amount: 12000, date: day.addingTimeInterval(43200))]
        let previews = try PersonalBankingImporter.balanceReviews(plan, choices: [:], manualBalances: manual, accounts: [local],
            transactions: [], snapshots: [], at: observed)
        precondition(previews.first?.current == 0 && previews.first?.projected == 11000)
        let imported = try PersonalBankingImporter.apply([feed], server: server, manualBalances: manual,
            reviewedBalances: previews, in: context, observedAt: observed)
        let rows = try context.fetch(FetchDescriptor<FinancialTransaction>())
        let snapshots = try context.fetch(FetchDescriptor<BalanceSnapshot>()).filter { $0.account?.id == local.id }
        precondition(imported.inserted == 2 && snapshots.count == 1 && snapshots.first?.source == .manual)
        precondition(FinanceCalculator.balance(of: local, at: observed, transactions: rows, snapshots: snapshots) == 11000)
        let repeated = try PersonalBankingImporter.apply([feed], server: server, in: context, observedAt: observed)
        precondition(repeated.inserted == 0 && repeated.skipped == 2)
    }
}
