import CryptoKit
import Foundation
import SwiftData

/// Only non-secret identity keys enter the financial graph. Consent secrets stay in the Worker.
enum PersonalBankingImporter {
    struct Result { let inserted: Int; let matched: Int; let skipped: Int }
    struct ManualBalance { let amount: Int64; let date: Date }
    struct BalanceReview: Equatable {
        let account: UUID
        let current: Int64
        let projected: Int64
        let baseDate: Date
        let hasSnapshot: Bool
    }
    struct ContributionProposal: Identifiable {
        let recurringID: UUID
        let sourceID: UUID
        let destinationID: UUID
        let period: DateInterval
        let expected: Int64
        let recognized: Int64
        let candidates: [FinancialTransaction]
        let planned: [FinancialTransaction]
        let match: ContributionRecognition.Match
        let revisions: [UUID: Date]
        var remaining: Int64 { expected - recognized }
        var id: String { recurringID.uuidString + "|" + String(period.start.timeIntervalSince1970) }
    }

    @MainActor static func contributionProposals(recurring: [RecurringMovement], transactions: [FinancialTransaction],
                                                 at date: Date = .now, calendar: Calendar = .autoupdatingCurrent) -> [ContributionProposal] {
        var proposals: [ContributionProposal] = []
        for rule in recurring where rule.isActive && rule.type == .transfer && rule.amountMinor > 0 && rule.amountMinor <= 1_000_000_000_000 {
            guard let source = rule.sourceAccount, let destination = rule.destinationAccount,
                  source.id != destination.id, !source.isArchived, !destination.isArchived,
                  source.type != .investment, !source.type.isLiability, destination.type == .investment,
                  source.currencyCode == destination.currencyCode else { continue }
            let endDay = rule.endDate.map { calendar.startOfDay(for: $0) } ?? .distantFuture
            let candidates = transactions.filter {
                $0.type == .expense && $0.sourceAccount?.id == source.id && $0.destinationAccount == nil
                    && $0.bankEntryKey != nil && $0.recurringMovementID == nil
                    && $0.reservedFundID == nil && $0.reservedAmountMinor == nil && $0.duplicateState != .possible
                    && $0.amountMinor > 0 && $0.amountMinor <= rule.amountMinor && $0.date <= date
                    && $0.date >= max(source.openingDate, destination.openingDate)
                    && calendar.startOfDay(for: $0.date) <= endDay
            }
            let groups = Dictionary(grouping: candidates) { RecurringMovementService.period(containing: $0.date, for: rule, calendar: calendar) }
            for (period, rows) in groups {
                guard let period else { continue }
                let existing = transactions.filter {
                    $0.type == .transfer && $0.sourceAccount?.id == source.id && $0.destinationAccount?.id == destination.id
                        && $0.date >= period.start && $0.date < period.end
                }
                let planned = existing.filter {
                    $0.recurringMovementID == rule.id && $0.bankEntryKey == nil && $0.externalID == nil
                        && $0.reservedFundID == nil && $0.reservedAmountMinor == nil
                }
                let plannedIDs = Set(planned.map(\.id))
                let actual = existing.filter { !plannedIDs.contains($0.id) }
                // Stop adding once the target is reached, including discretionary contributions.
                let recognized = actual.reduce(Int64.zero) { min(rule.amountMinor, $0 + min(rule.amountMinor, $1.amountMinor)) }
                guard recognized < rule.amountMinor else { continue }
                let remaining = rule.amountMinor - recognized
                let plannedAmount = planned.reduce(Int64.zero) { min(rule.amountMinor + 1, $0 + min(rule.amountMinor + 1, $1.amountMinor)) }
                guard planned.isEmpty || plannedAmount == remaining || plannedAmount == rule.amountMinor else { continue }
                let ordered = rows.sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date }
                let match = ContributionRecognition.match(ordered.map { .init(id: $0.id, amount: $0.amountMinor) }, remaining: remaining)
                guard match != .none else { continue }
                proposals.append(ContributionProposal(recurringID: rule.id, sourceID: source.id, destinationID: destination.id,
                    period: period, expected: rule.amountMinor, recognized: recognized, candidates: ordered, planned: planned,
                    match: match, revisions: Dictionary(uniqueKeysWithValues: (ordered + planned).map { ($0.id, $0.updatedAt) })))
            }
        }
        return proposals.sorted { $0.period.start == $1.period.start ? $0.id < $1.id : $0.period.start > $1.period.start }
    }

    @MainActor static func confirmContribution(_ proposal: ContributionProposal, selectedIDs: Set<UUID>, in context: ModelContext) throws {
        try requireCloud(context)
        guard !context.hasChanges else { throw PersonalBankingError.changed }
        let rules = try context.fetch(FetchDescriptor<RecurringMovement>())
        let transactions = try context.fetch(FetchDescriptor<FinancialTransaction>())
        guard let current = contributionProposals(recurring: rules, transactions: transactions).first(where: { $0.id == proposal.id }),
              current.expected == proposal.expected, current.recognized == proposal.recognized,
              current.sourceID == proposal.sourceID, current.destinationID == proposal.destinationID,
              current.period == proposal.period, current.revisions == proposal.revisions,
              Set(current.planned.map(\.id)) == Set(proposal.planned.map(\.id)),
              let rule = rules.first(where: { $0.id == current.recurringID }),
              let destination = rule.destinationAccount, let source = rule.sourceAccount,
              !selectedIDs.isEmpty, selectedIDs.isSubset(of: Set(current.candidates.map(\.id))) else {
            throw PersonalBankingError.changed
        }
        let selected = current.candidates.filter { selectedIDs.contains($0.id) }
        let amount = selected.reduce(Int64.zero) { min(current.remaining + 1, $0 + min(current.remaining + 1, $1.amountMinor)) }
        guard amount == current.remaining else { throw PersonalBankingError.needsReview }
        // An opposite bank posting needs normal transfer reconciliation first.
        guard !selected.contains(where: { debit in
            transactions.contains {
                $0.type == .income && $0.sourceAccount?.id == destination.id && $0.amountMinor == debit.amountMinor
                    && Calendar.current.isDate($0.date, inSameDayAs: debit.date)
            }
        }) else { throw PersonalBankingError.contributionNeedsTransferReview }
        do {
            let plannedNotes = current.planned.map(\.notes).filter { !$0.isEmpty }.joined(separator: "\n\n")
            for transaction in selected {
                transaction.type = .transfer
                transaction.destinationAccount = destination
                transaction.recurringMovementID = rule.id
                if transaction.category?.kind != .transfer { transaction.category = nil }
                if !plannedNotes.isEmpty { transaction.notes += (transaction.notes.isEmpty ? "" : "\n\n") + plannedNotes }
                transaction.fingerprint = DuplicateDetectionService.fingerprint(date: transaction.date, sourceAccountID: source.id,
                    destinationAccountID: destination.id, type: .transfer, amountMinor: transaction.amountMinor,
                    description: transaction.descriptionText)
                transaction.updatedAt = .now
            }
            for planned in current.planned { context.delete(planned) }
            try context.save()
        } catch { context.rollback(); throw error }
    }
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

    /// A single bank posting that duplicates an existing movement can hand its bank reference to it.
    /// The kept movement must pass the same identity check as the next download, so it is not imported again.
    @MainActor static func canMergeBankEntry(_ duplicate: FinancialTransaction, into kept: FinancialTransaction) -> Bool {
        guard duplicate.id != kept.id, duplicate.amountMinor == kept.amountMinor,
              abs(kept.date.timeIntervalSince(duplicate.date)) <= 7 * 86400,
              duplicate.type != .transfer, duplicate.destinationAccount == nil,
              duplicate.reservedFundID == nil, duplicate.reservedAmountMinor == nil, duplicate.recurringMovementID == nil,
              let source = duplicate.sourceAccount, kept.sourceAccount != nil,
              let duplicateKeys = try? PersonalBankingPlan.keys(duplicate.bankEntryKey), duplicateKeys.count == 1,
              let keptKeys = try? PersonalBankingPlan.keys(kept.bankEntryKey) else { return false }
        if !keptKeys.isEmpty {
            // Only an own transfer may already hold one reference: the other bank account's leg.
            guard kept.type == .transfer, keptKeys.count == 1,
                  accountPrefix(keptKeys[0]) != accountPrefix(duplicateKeys[0]) else { return false }
        }
        let entry = BankingLedgerEntry(id: kept.id, date: kept.date, kind: kept.typeRaw, amount: kept.amountMinor,
            source: kept.sourceAccount?.id, destination: kept.destinationAccount?.id, text: kept.descriptionText,
            externalID: kept.bankEntryKey)
        let item = PersonalBankingPlan.Item(id: duplicateKeys[0], date: duplicate.date,
            kind: duplicate.type.countsAsIncome ? "income" : "expense", amount: duplicate.amountMinor,
            source: source.id, destination: nil, text: duplicate.descriptionText)
        return PersonalBankingPlan.compatible(entry, with: item)
    }

    @MainActor static func mergeCandidates(for duplicate: FinancialTransaction,
                                          in transactions: [FinancialTransaction]) -> [FinancialTransaction] {
        guard duplicate.bankEntryKey != nil else { return [] }
        return transactions.filter { canMergeBankEntry(duplicate, into: $0) }.sorted {
            let left = abs($0.date.timeIntervalSince(duplicate.date)), right = abs($1.date.timeIntervalSince(duplicate.date))
            return left == right ? $0.id.uuidString < $1.id.uuidString : left < right
        }
    }

    /// Keeps the user's movement (category, notes, reserve, recurrence) and deletes only the duplicate bank row.
    @MainActor static func mergeBankEntry(_ duplicate: FinancialTransaction, into kept: FinancialTransaction,
                                         in context: ModelContext) throws {
        try requireCloud(context)
        guard !context.hasChanges, duplicate.modelContext === context, kept.modelContext === context,
              canMergeBankEntry(duplicate, into: kept) else { throw PersonalBankingError.changed }
        let bankKey = try PersonalBankingPlan.encodedKeys(PersonalBankingPlan.keys(kept.bankEntryKey)
            + PersonalBankingPlan.keys(duplicate.bankEntryKey))
        let concept = duplicate.descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if concept != kept.descriptionText && concept != "Movimiento bancario" && !kept.notes.contains(concept) {
                kept.notes = [kept.notes, "Concepto bancario: \(concept)"].filter { !$0.isEmpty }.joined(separator: "\n\n")
            }
            kept.bankEntryKey = bankKey
            kept.isReconciled = true
            kept.updatedAt = .now
            context.delete(duplicate)
            try context.save()
        } catch { context.rollback(); throw error }
    }
    private static func accountPrefix(_ key: String) -> String {
        key.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false).prefix(3).joined(separator: ":")
    }

    // MARK: Own transfers between linked banks

    /// A debit in one linked account and a credit in another that are the two sides of the same own transfer.
    /// `strong` pairs are joined automatically after an import; the rest are only proposed.
    struct OwnTransferPair {
        let debit: FinancialTransaction
        let credit: FinancialTransaction
        let strong: Bool
    }

    private struct OwnTransferAudit: Codable {
        struct Joined: Codable {
            let debitKey: String, creditKey: String
            let debitText: String, debitNotes: String, debitCategoryID: UUID?, debitFingerprint: String, debitReconciled: Bool
            let creditID: UUID, creditDate: Date, creditCreatedAt: Date, creditText: String, creditNotes: String
            let creditAccountID: UUID, creditCategoryID: UUID?, creditFingerprint: String, creditReconciled: Bool
            let creditImportBatchID: UUID?
        }
        var joined: [UUID: Joined] = [:]
        /// Keys the user separated: they are never joined automatically again.
        var separated: Set<String> = []
    }

    @MainActor static func isOwnTransferLeg(_ transaction: FinancialTransaction) -> Bool {
        guard transaction.type == .expense || transaction.type == .income, transaction.destinationAccount == nil,
              transaction.amountMinor > 0, let account = transaction.sourceAccount, account.bankIdentityKey != nil,
              !account.isArchived, transaction.reservedFundID == nil, transaction.reservedAmountMinor == nil,
              transaction.recurringMovementID == nil, transaction.externalID == nil, transaction.duplicateState == .none,
              transaction.category == nil || transaction.category?.kind == .transfer,
              let keys = try? PersonalBankingPlan.keys(transaction.bankEntryKey), keys.count == 1 else { return false }
        return true
    }

    /// Pairs need equal amounts, different linked accounts and at most two days apart, with exactly one
    /// candidate on each side. An existing transfer between those accounts means it is already recorded.
    /// Strong: a transfer concept on either side (or a bank that named the other own account) and at most one day apart.
    @MainActor static func ownTransferPairs(in transactions: [FinancialTransaction], involving ids: Set<UUID>? = nil,
                                           excluding separated: Set<String> = [], hints: Set<String> = []) -> [OwnTransferPair] {
        let legs = transactions.filter { leg in
            isOwnTransferLeg(leg) && !((try? PersonalBankingPlan.keys(leg.bankEntryKey)) ?? []).contains { separated.contains($0) }
        }
        let debits = legs.filter { $0.type == .expense }
        let credits = legs.filter { $0.type == .income }
        func near(_ debit: FinancialTransaction, _ credit: FinancialTransaction) -> Bool {
            debit.amountMinor == credit.amountMinor && debit.sourceAccount?.id != credit.sourceAccount?.id
                && debit.sourceAccount?.currencyCode == credit.sourceAccount?.currencyCode
                && abs(debit.date.timeIntervalSince(credit.date)) <= 2 * 86400
        }
        var pairs: [OwnTransferPair] = []
        for debit in debits {
            let options = credits.filter { near(debit, $0) }
            guard options.count == 1, let credit = options.first, debits.filter({ near($0, credit) }).count == 1 else { continue }
            if let ids, !ids.contains(debit.id) && !ids.contains(credit.id) { continue }
            let recorded = transactions.contains {
                $0.type == .transfer && $0.amountMinor == debit.amountMinor
                    && $0.sourceAccount?.id == debit.sourceAccount?.id && $0.destinationAccount?.id == credit.sourceAccount?.id
                    && abs($0.date.timeIntervalSince(debit.date)) <= 2 * 86400
            }
            guard !recorded else { continue }
            let named = [debit.bankEntryKey, credit.bankEntryKey].contains { key in key.map { hints.contains($0) } ?? false }
            let concept = debit.hasBankTransferConcept || credit.hasBankTransferConcept
            let days = abs(debit.date.timeIntervalSince(credit.date))
            pairs.append(OwnTransferPair(debit: debit, credit: credit, strong: named || (concept && days <= 86400)))
        }
        return pairs.sorted { $0.debit.date == $1.debit.date ? $0.debit.id.uuidString < $1.debit.id.uuidString : $0.debit.date < $1.debit.date }
    }

    /// Joins the strong pairs that involve the given movements. Recovery data is written before the financial save.
    @MainActor @discardableResult
    static func pairOwnTransfersAutomatically(involving ids: Set<UUID>, hints: Set<String> = [],
                                              in context: ModelContext) throws -> Set<UUID> {
        try requireCloud(context)
        guard !context.hasChanges, let location = ownTransferAuditLocation(in: context) else { return [] }
        var audit = try readOwnTransferAudit(location)
        let pairs = ownTransferPairs(in: try context.fetch(FetchDescriptor<FinancialTransaction>()), involving: ids,
                                     excluding: audit.separated, hints: hints).filter(\.strong)
        guard !pairs.isEmpty else { return [] }
        for pair in pairs { audit.joined[pair.debit.id] = try auditRecord(pair) }
        try writeOwnTransferAudit(audit, at: location)
        var removed = Set<UUID>()
        do {
            for pair in pairs {
                try join(pair.debit, with: pair.credit, in: context)
                removed.insert(pair.credit.id)
            }
            try context.save()
        } catch { context.rollback(); throw error }
        return removed
    }

    /// Joins a proposed pair confirmed by the user. The pair must still be the unique match.
    @MainActor static func pairOwnTransfer(_ debit: FinancialTransaction, with credit: FinancialTransaction,
                                           in context: ModelContext) throws {
        try requireCloud(context)
        guard !context.hasChanges, debit.modelContext === context, credit.modelContext === context,
              let location = ownTransferAuditLocation(in: context) else { throw PersonalBankingError.changed }
        var audit = try readOwnTransferAudit(location)
        let pairs = ownTransferPairs(in: try context.fetch(FetchDescriptor<FinancialTransaction>()), involving: [debit.id])
        guard let pair = pairs.first(where: { $0.debit.id == debit.id && $0.credit.id == credit.id }) else {
            throw PersonalBankingError.changed
        }
        audit.joined[debit.id] = try auditRecord(pair)
        try writeOwnTransferAudit(audit, at: location)
        do {
            try join(debit, with: credit, in: context)
            try context.save()
        } catch { context.rollback(); throw error }
    }

    @MainActor static func canSeparateOwnTransfer(_ transaction: FinancialTransaction) -> Bool {
        guard let context = transaction.modelContext, let location = ownTransferAuditLocation(in: context),
              let record = try? readOwnTransferAudit(location).joined[transaction.id] else { return false }
        return transaction.type == .transfer && transaction.destinationAccount?.id == record.creditAccountID
            && Set((try? PersonalBankingPlan.keys(transaction.bankEntryKey)) ?? []) == Set([record.debitKey, record.creditKey])
            && transaction.reservedFundID == nil && transaction.reservedAmountMinor == nil && transaction.recurringMovementID == nil
    }

    /// Restores both bank postings exactly as they were and keeps them from being joined automatically again.
    @MainActor static func separateOwnTransfer(_ transaction: FinancialTransaction, in context: ModelContext) throws {
        try requireCloud(context)
        guard !context.hasChanges, transaction.modelContext === context, canSeparateOwnTransfer(transaction),
              let location = ownTransferAuditLocation(in: context) else { throw PersonalBankingError.changed }
        var audit = try readOwnTransferAudit(location)
        guard let record = audit.joined[transaction.id] else { throw PersonalBankingError.changed }
        let accounts = try context.fetch(FetchDescriptor<FinancialAccount>())
        let categories = try context.fetch(FetchDescriptor<FinanceCategory>())
        let existing = try context.fetch(FetchDescriptor<FinancialTransaction>())
        guard let creditAccount = accounts.first(where: { $0.id == record.creditAccountID }),
              !existing.contains(where: { $0.id == record.creditID }) else { throw PersonalBankingError.changed }
        do {
            let credit = FinancialTransaction(id: record.creditID, date: record.creditDate, type: .income,
                amountMinor: transaction.amountMinor, descriptionText: record.creditText, notes: record.creditNotes,
                isReconciled: record.creditReconciled, fingerprint: record.creditFingerprint, bankEntryKey: record.creditKey,
                importBatchID: record.creditImportBatchID, createdAt: record.creditCreatedAt, sourceAccount: creditAccount,
                category: categories.first { $0.id == record.creditCategoryID })
            transaction.type = .expense
            transaction.destinationAccount = nil
            transaction.bankEntryKey = record.debitKey
            transaction.descriptionText = record.debitText
            transaction.notes = record.debitNotes
            transaction.category = categories.first { $0.id == record.debitCategoryID }
            transaction.fingerprint = record.debitFingerprint
            transaction.isReconciled = record.debitReconciled
            transaction.updatedAt = .now
            context.insert(credit)
            try context.save()
        } catch { context.rollback(); throw error }
        audit.joined[transaction.id] = nil
        audit.separated.formUnion([record.debitKey, record.creditKey])
        try? writeOwnTransferAudit(audit, at: location)
    }

    @MainActor private static func join(_ debit: FinancialTransaction, with credit: FinancialTransaction,
                                        in context: ModelContext) throws {
        guard let destination = credit.sourceAccount else { throw PersonalBankingError.changed }
        debit.bankEntryKey = try PersonalBankingPlan.encodedKeys(PersonalBankingPlan.keys(debit.bankEntryKey)
            + PersonalBankingPlan.keys(credit.bankEntryKey))
        let concept = credit.descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        var notes = [debit.notes, credit.notes].filter { !$0.isEmpty }
        if debit.descriptionText == "Movimiento bancario" && !concept.isEmpty && concept != "Movimiento bancario" {
            debit.descriptionText = concept
        } else if !concept.isEmpty && concept != debit.descriptionText && concept != "Movimiento bancario" {
            notes.append("Concepto bancario del otro apunte: \(concept)")
        }
        debit.type = .transfer
        debit.destinationAccount = destination
        if debit.category?.kind != .transfer { debit.category = nil }
        debit.notes = notes.joined(separator: "\n\n")
        debit.isReconciled = debit.isReconciled && credit.isReconciled
        debit.fingerprint = DuplicateDetectionService.fingerprint(date: debit.date, sourceAccountID: debit.sourceAccount?.id,
            destinationAccountID: destination.id, type: .transfer, amountMinor: debit.amountMinor, description: debit.descriptionText)
        debit.updatedAt = .now
        context.delete(credit)
    }

    @MainActor private static func auditRecord(_ pair: OwnTransferPair) throws -> OwnTransferAudit.Joined {
        guard let debitKey = pair.debit.bankEntryKey, let creditKey = pair.credit.bankEntryKey,
              let creditAccount = pair.credit.sourceAccount else { throw PersonalBankingError.changed }
        return OwnTransferAudit.Joined(debitKey: debitKey, creditKey: creditKey,
            debitText: pair.debit.descriptionText, debitNotes: pair.debit.notes, debitCategoryID: pair.debit.category?.id,
            debitFingerprint: pair.debit.fingerprint, debitReconciled: pair.debit.isReconciled,
            creditID: pair.credit.id, creditDate: pair.credit.date, creditCreatedAt: pair.credit.createdAt,
            creditText: pair.credit.descriptionText, creditNotes: pair.credit.notes, creditAccountID: creditAccount.id,
            creditCategoryID: pair.credit.category?.id, creditFingerprint: pair.credit.fingerprint,
            creditReconciled: pair.credit.isReconciled, creditImportBatchID: pair.credit.importBatchID)
    }

    /// Local to the device, like the learning history: undo data never enters backups or the cloud.
    private static func ownTransferAuditLocation(in context: ModelContext) -> URL? {
        guard let configuration = context.container.configurations.first, configuration.name == "CloudFinance",
              !configuration.isStoredInMemoryOnly else { return nil }
        return configuration.url.appendingPathExtension("own-transfers-v1.json")
    }
    private static func readOwnTransferAudit(_ url: URL) throws -> OwnTransferAudit {
        guard FileManager.default.fileExists(atPath: url.path) else { return OwnTransferAudit() }
        return try JSONDecoder().decode(OwnTransferAudit.self, from: Data(contentsOf: url))
    }
    private static func writeOwnTransferAudit(_ audit: OwnTransferAudit, at url: URL) throws {
        try JSONEncoder().encode(audit).write(to: url, options: [.atomic, .completeFileProtection])
        var destination = url, values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? destination.setResourceValues(values)
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
    @MainActor static func balanceReviews(_ plan: PersonalBankingPlan, choices: [String: PersonalBankingPlan.Choice],
                                          manualBalances: [UUID: ManualBalance], accounts: [FinancialAccount],
                                          transactions: [FinancialTransaction], snapshots: [BalanceSnapshot],
                                          at date: Date = .now) throws -> [BalanceReview] {
        guard Set(manualBalances.keys).isSubset(of: Set(plan.balanceGaps.map(\.id))) else { throw PersonalBankingError.changed }
        guard !plan.balanceGaps.isEmpty else { return [] }
        let decisions = try plan.resolutions(choices)
        return try plan.balanceGaps.map { gap in
            guard let account = accounts.first(where: { $0.id == gap.id }) else { throw PersonalBankingError.changed }
            let snapshot = snapshots.filter { $0.account?.id == gap.id && $0.date <= date }.max { $0.date < $1.date }
            let current = FinanceCalculator.balance(of: account, at: date, transactions: transactions, snapshots: snapshots)
            let baseDate: Date
            let base: Int64
            if let manual = manualBalances[gap.id] {
                guard manual.date <= date, snapshot == nil,
                      (-1_000_000_000_000_000...1_000_000_000_000_000).contains(manual.amount) else {
                    throw PersonalBankingError.changed
                }
                baseDate = manual.date
                base = transactions.filter { $0.date > manual.date && $0.date <= date }.reduce(manual.amount) {
                    $0 + FinanceCalculator.effect(of: $1, on: account)
                }
            } else {
                baseDate = snapshot?.date ?? account.openingDate
                base = current
            }
            let additional = plan.newBalanceEffects(for: gap.id, after: baseDate, through: date,
                includingCutoff: snapshot == nil && manualBalances[gap.id] == nil, decisions: decisions)
            return BalanceReview(account: gap.id, current: current, projected: base + additional,
                                 baseDate: baseDate, hasSnapshot: snapshot != nil)
        }
    }
    @MainActor static func apply(_ feeds: [BankingAccountFeed], server: URL,
                                 choices: [String: PersonalBankingPlan.Choice] = [:],
                                 manualBalances: [UUID: ManualBalance] = [:], reviewedBalances: [BalanceReview]? = nil,
                                 ownTransferHints: [String: Set<String>] = [:],
                                 in context: ModelContext, observedAt: Date) throws -> Result {
        try requireCloud(context)
        guard !context.hasChanges else { throw PersonalBankingError.changed }
        let plan = try plan(feeds, server: server, in: context)
        let decisions = try plan.resolutions(choices)
        let accounts = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<FinancialAccount>()).map { ($0.id, $0) })
        let existing = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<FinancialTransaction>()).map { ($0.id, $0) })
        let rules = try context.fetch(FetchDescriptor<CategoryRule>())
        let snapshots = try context.fetch(FetchDescriptor<BalanceSnapshot>())
        if plan.requiresBalanceReview || !manualBalances.isEmpty || reviewedBalances != nil {
            let reviews = try balanceReviews(plan, choices: choices, manualBalances: manualBalances,
                accounts: Array(accounts.values), transactions: Array(existing.values), snapshots: snapshots)
            guard let reviewedBalances else { throw PersonalBankingError.needsReview }
            guard reviews == reviewedBalances else { throw PersonalBankingError.changed }
        }
        let batch = ImportBatch(fileName: "Enable Banking", source: .bankAPI, importedAt: observedAt)
        var insertedIDs: Set<UUID> = []
        var matched = 0
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
                    context.insert(transaction)
                    insertedIDs.insert(transaction.id)
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
            for (id, manual) in manualBalances {
                guard let account = accounts[id] else { throw PersonalBankingError.changed }
                context.insert(BalanceSnapshot(date: manual.date, balanceMinor: manual.amount, source: .manual,
                    notes: "Saldo de referencia de Trade Republic", account: account))
                account.lastUpdatedAt = manual.date; account.updatedAt = .now
            }
            if !insertedIDs.isEmpty || matched > 0 {
                batch.importedRows = insertedIDs.count; batch.skippedDuplicates = plan.alreadyImported + matched
                context.insert(batch)
            }
            try context.save()
        } catch { context.rollback(); throw error }
        // A separate save: a pairing problem never undoes the import; the postings stay for review.
        let namespace = hash(server.absoluteString)
        let hintKeys = Set(ownTransferHints.flatMap { account, references in
            references.map { "enable-entry:\(namespace):\(account):\($0)" }
        })
        let joined: Set<UUID> = insertedIDs.isEmpty ? []
            : ((try? pairOwnTransfersAutomatically(involving: insertedIDs, hints: hintKeys, in: context)) ?? [])
        BankingMovementCommit.publish(storeURL: context.container.configurations.first?.url,
                                      transactionIDs: insertedIDs.subtracting(joined))
        return Result(inserted: insertedIDs.count, matched: matched, skipped: plan.alreadyImported)
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
