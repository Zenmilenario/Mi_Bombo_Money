import CryptoKit
import Foundation
import SwiftData

/// Only non-secret identity keys enter the financial graph. Consent secrets stay in the Worker.
enum PersonalBankingImporter {
    struct Result { let inserted: Int; let matched: Int; let skipped: Int }
    static func identity(server: URL, accountID: String) -> String {
        "enable:" + hash(server.absoluteString + "|" + accountID)
    }
    @MainActor static func link(_ remote: ConnectedBankAccount, bank: String, server: URL,
                                to selected: FinancialAccount?, in context: ModelContext) throws {
        try requireCloud(context)
        guard !context.hasChanges, remote.currency == "EUR" else { throw PersonalBankingError.changed }
        let key = identity(server: server, accountID: remote.id)
        let accounts = try context.fetch(FetchDescriptor<FinancialAccount>())
        guard !accounts.contains(where: { $0.bankIdentityKey == key && $0.id != selected?.id }),
              selected == nil || (selected?.bankIdentityKey == nil && selected?.currencyCode == "EUR" && selected?.isArchived == false
                && selected?.type.isLiability == false && selected?.type != .investment) else {
            throw PersonalBankingError.accountNotLinked
        }
        do {
            let account: FinancialAccount
            if let selected { account = selected }
            else {
                let institutions = try context.fetch(FetchDescriptor<FinancialInstitution>())
                let institution = institutions.first { $0.name == bank } ?? FinancialInstitution(name: bank)
                if institution.modelContext == nil { context.insert(institution) }
                account = FinancialAccount(id: uuid(key), name: remote.name, type: .checking,
                    openingDate: Date.now.addingTimeInterval(-90 * 86400), institution: institution)
                context.insert(account)
            }
            account.bankIdentityKey = key; account.updatedAt = .now
            try context.save()
        } catch { context.rollback(); throw error }
    }
    @MainActor static func ledger(in context: ModelContext) throws -> [BankingLedgerEntry] {
        try context.fetch(FetchDescriptor<FinancialTransaction>()).map {
            BankingLedgerEntry(id: $0.id, date: $0.date, kind: $0.typeRaw, amount: $0.amountMinor,
                source: $0.sourceAccount?.id, destination: $0.destinationAccount?.id, text: $0.descriptionText, externalID: $0.bankEntryKey)
        }
    }

    @MainActor static func canPairImportedTransfer(_ first: FinancialTransaction, with second: FinancialTransaction) -> Bool {
        // Some providers have no description. One explicit transfer concept can
        // support a review of the opposite posting when its text is our fallback.
        let pair = [first, second]
        guard first.id != second.id, Set(pair.map(\.type)) == Set([.expense, .income]),
              pair.contains(where: \.hasBankTransferConcept),
              pair.allSatisfy({ $0.bankEntryKey != nil && ($0.hasBankTransferConcept || $0.descriptionText == "Movimiento bancario") }),
              first.amountMinor > 0, first.amountMinor == second.amountMinor,
              first.date == second.date,
              let firstAccount = first.sourceAccount, let secondAccount = second.sourceAccount,
              firstAccount.id != secondAccount.id, firstAccount.currencyCode == secondAccount.currencyCode,
              !firstAccount.isArchived, !secondAccount.isArchived else { return false }
        return pair.allSatisfy {
            $0.category == nil && $0.destinationAccount == nil && $0.reservedFundID == nil
                && $0.reservedAmountMinor == nil && $0.recurringMovementID == nil && $0.externalID == nil
                && $0.duplicateState == .none
        }
    }

    @MainActor static func pairImportedTransfer(_ first: FinancialTransaction, with second: FinancialTransaction,
                                                in context: ModelContext) throws {
        try requireCloud(context)
        guard !context.hasChanges, first.modelContext === context, second.modelContext === context,
              canPairImportedTransfer(first, with: second) else { throw PersonalBankingError.changed }
        let keys = try PersonalBankingPlan.keys(first.bankEntryKey) + PersonalBankingPlan.keys(second.bankEntryKey)
        guard keys.count == 2, Set(keys).count == 2 else { throw PersonalBankingError.changed }
        let bankKey = try PersonalBankingPlan.encodedKeys(keys)
        let source = first.type == .expense ? first.sourceAccount : second.sourceAccount
        let destination = first.type == .income ? first.sourceAccount : second.sourceAccount
        let transactions = try context.fetch(FetchDescriptor<FinancialTransaction>())
        guard !transactions.contains(where: {
            $0.type == .transfer && $0.sourceAccount?.id == source?.id && $0.destinationAccount?.id == destination?.id
                && $0.amountMinor == first.amountMinor && Calendar.current.isDate($0.date, inSameDayAs: first.date)
        }) else { throw PersonalBankingError.transferAlreadyRecorded }
        var notes = [first.notes, second.notes].filter { !$0.isEmpty }
        if first.descriptionText != second.descriptionText {
            notes.append("Concepto bancario del otro apunte: \(second.descriptionText)")
        }
        do {
            first.type = .transfer
            first.sourceAccount = source
            first.destinationAccount = destination
            first.bankEntryKey = bankKey
            first.fingerprint = DuplicateDetectionService.fingerprint(date: first.date, sourceAccountID: source?.id,
                destinationAccountID: destination?.id, type: .transfer, amountMinor: first.amountMinor, description: first.descriptionText)
            first.notes = notes.joined(separator: "\n\n")
            first.isReconciled = first.isReconciled && second.isReconciled
            first.updatedAt = .now
            context.delete(second)
            try context.save()
        } catch { context.rollback(); throw error }
    }

    @MainActor static func plan(_ feeds: [BankingAccountFeed], server: URL, in context: ModelContext) throws -> PersonalBankingPlan {
        try requireCloud(context)
        let accounts = try context.fetch(FetchDescriptor<FinancialAccount>())
        var links: [String: UUID] = [:]
        for feed in feeds {
            let matches = accounts.filter { $0.bankIdentityKey == identity(server: server, accountID: feed.account.id) && !$0.isArchived }
            guard matches.count == 1, let match = matches.first, match.currencyCode == "EUR" else { throw PersonalBankingError.accountNotLinked }
            links[feed.account.id] = match.id
        }
        return try PersonalBankingPlan.build(feeds: feeds, links: links, ledger: ledger(in: context), namespace: hash(server.absoluteString))
    }
    @MainActor static func apply(_ feeds: [BankingAccountFeed], server: URL,
                                 choices: [String: PersonalBankingPlan.Choice] = [:],
                                 in context: ModelContext, observedAt: Date) throws -> Result {
        try requireCloud(context)
        guard !context.hasChanges else { throw PersonalBankingError.changed }
        let plan = try plan(feeds, server: server, in: context)
        let decisions = try plan.resolutions(choices)
        let accounts = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<FinancialAccount>()).map { ($0.id, $0) })
        let existing = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<FinancialTransaction>()).map { ($0.id, $0) })
        let rules = try context.fetch(FetchDescriptor<CategoryRule>())
        let snapshots = try context.fetch(FetchDescriptor<BalanceSnapshot>())
        let batch = ImportBatch(fileName: "Enable Banking", source: .bankAPI, importedAt: observedAt)
        var inserted = 0; var matched = 0
        do {
            for item in plan.items {
                guard let choice = decisions[item.id] else { throw PersonalBankingError.needsReview }
                switch choice {
                case .match(let id):
                    guard let transaction = existing[id], transaction.bankEntryKey == nil || transaction.type == .transfer else { throw PersonalBankingError.changed }
                    // Preserve the user's category, notes, reserve allocation, recurring provenance and date.
                    transaction.bankEntryKey = try PersonalBankingPlan.encodedKeys(PersonalBankingPlan.keys(transaction.bankEntryKey) + PersonalBankingPlan.keys(item.id))
                    transaction.isReconciled = true; transaction.updatedAt = observedAt
                    matched += 1
                case .new:
                    guard let source = accounts[item.source], let type = TransactionType(rawValue: item.kind) else { throw PersonalBankingError.invalidData }
                    let category = CategoryRuleService.match(description: item.text, type: type, rules: rules)?.category
                    let transaction = FinancialTransaction(id: uuid(item.id), date: item.date, type: type, amountMinor: item.amount,
                        descriptionText: item.text, isReconciled: true, bankEntryKey: item.id, importBatchID: batch.id,
                        sourceAccount: source, destinationAccount: item.destination.flatMap { accounts[$0] }, category: category)
                    transaction.fingerprint = DuplicateDetectionService.fingerprint(date: item.date, sourceAccountID: item.source,
                        destinationAccountID: item.destination, type: type, amountMinor: item.amount, description: item.text)
                    context.insert(transaction); inserted += 1
                }
            }
            for balance in plan.balances {
                guard let account = accounts[balance.account], let key = account.bankIdentityKey else { throw PersonalBankingError.changed }
                let snapshotID = uuid(key + "|booked-balance")
                if let snapshot = snapshots.first(where: { $0.id == snapshotID }) {
                    snapshot.date = observedAt; snapshot.balanceMinor = balance.amount
                } else {
                    context.insert(BalanceSnapshot(id: snapshotID, date: observedAt, balanceMinor: balance.amount,
                        source: .bankAPI, notes: "Saldo contable de Enable Banking", account: account))
                }
                account.lastUpdatedAt = observedAt; account.updatedAt = observedAt
            }
            if inserted + matched > 0 {
                batch.importedRows = inserted; batch.skippedDuplicates = plan.alreadyImported + matched
                context.insert(batch)
            }
            try context.save()
        } catch { context.rollback(); throw error }
        return Result(inserted: inserted, matched: matched, skipped: plan.alreadyImported)
    }
    private static func requireCloud(_ context: ModelContext) throws {
        guard context.container.configurations.allSatisfy({ $0.name == "CloudFinance" }) else { throw PersonalBankingError.wrongWorkspace }
    }
    private static func hash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    private static func uuid(_ text: String) -> UUID {
        let b = Array(SHA256.hash(data: Data(text.utf8)))
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}
