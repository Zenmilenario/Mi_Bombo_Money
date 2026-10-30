import Foundation
import SwiftData

enum CloudBackupAdapter {
    static func document(in context: ModelContext) throws -> CloudJSON {
        let backup = try BackupService.capture(in: context)
        return CloudDocument.normalized(try JSONDecoder().decode(CloudJSON.self, from: BackupService.encode(backup)))
    }
    static func backup(from document: CloudJSON) throws -> FinanceBackup {
        try BackupService.decode(JSONEncoder().encode(CloudDocument.normalized(document)))
    }
    // Preserve model identities so a remote update does not invalidate every open detail view.
    static func apply(_ backup: FinanceBackup, in context: ModelContext) throws {
        try backup.validate()
        try context.save()
        let autosave = context.autosaveEnabled
        context.autosaveEnabled = false
        defer { context.autosaveEnabled = autosave }
        do {
            var institutions = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<FinancialInstitution>()).map { ($0.id, $0) })
            var accounts = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<FinancialAccount>()).map { ($0.id, $0) })
            var categories = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<FinanceCategory>()).map { ($0.id, $0) })
            var categoryRules = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<CategoryRule>()).map { ($0.id, $0) })
            var recurringBudgets = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<RecurringBudget>()).map { ($0.id, $0) })
            var cards = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<PaymentCard>()).map { ($0.id, $0) })
            var reservedFunds = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<ReservedFund>()).map { ($0.id, $0) })
            var recurringMovements = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<RecurringMovement>()).map { ($0.id, $0) })
            var transactions = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<FinancialTransaction>()).map { ($0.id, $0) })
            var budgets = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<MonthlyBudget>()).map { ($0.id, $0) })
            var goals = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<SavingsGoal>()).map { ($0.id, $0) })
            var snapshots = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<BalanceSnapshot>()).map { ($0.id, $0) })
            var importBatches = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<ImportBatch>()).map { ($0.id, $0) })
            for record in backup.institutions {
                let value: FinancialInstitution
                if let existing = institutions[record.id] { value = existing } else {
                    value = FinancialInstitution(
                    id: record.id, name: record.name, colorHex: record.colorHex,
                    notes: record.notes, createdAt: record.createdAt, updatedAt: record.updatedAt
                )
                    context.insert(value)
                }
                value.name = record.name
                value.colorHex = record.colorHex
                value.notes = record.notes
                value.createdAt = record.createdAt
                value.updatedAt = record.updatedAt
                institutions[record.id] = value
            }
            for record in backup.accounts {
                let value: FinancialAccount
                if let existing = accounts[record.id] { value = existing } else {
                    value = FinancialAccount(
                    id: record.id, name: record.name,
                    type: AccountType(rawValue: record.typeRaw)!,
                    currencyCode: record.currencyCode,
                    openingBalanceMinor: record.openingBalanceMinor,
                    openingDate: record.openingDate,
                    annualInterestRate: record.annualInterestRate,
                    targetBalanceMinor: record.targetBalanceMinor,
                    creditLimitMinor: record.creditLimitMinor,
                    bankIdentityKey: record.bankIdentityKey,
                    includeInNetWorth: record.includeInNetWorth,
                    isArchived: record.isArchived, sortOrder: record.sortOrder,
                    notes: record.notes, lastUpdatedAt: record.lastUpdatedAt,
                    createdAt: record.createdAt, updatedAt: record.updatedAt,
                    institution: record.institutionID.flatMap { institutions[$0] }
                )
                    context.insert(value)
                }
                value.name = record.name
                value.typeRaw = record.typeRaw
                value.currencyCode = record.currencyCode
                value.openingBalanceMinor = record.openingBalanceMinor
                value.openingDate = record.openingDate
                value.annualInterestRate = record.annualInterestRate
                value.targetBalanceMinor = record.targetBalanceMinor
                value.creditLimitMinor = record.creditLimitMinor
                value.bankIdentityKey = record.bankIdentityKey
                value.includeInNetWorth = record.includeInNetWorth
                value.isArchived = record.isArchived
                value.sortOrder = record.sortOrder
                value.notes = record.notes
                value.lastUpdatedAt = record.lastUpdatedAt
                value.createdAt = record.createdAt
                value.updatedAt = record.updatedAt
                value.institution = record.institutionID.flatMap { institutions[$0] }
                accounts[record.id] = value
            }
            for record in backup.categories {
                let value: FinanceCategory
                if let existing = categories[record.id] { value = existing } else {
                    value = FinanceCategory(
                    id: record.id, name: record.name,
                    kind: CategoryKind(rawValue: record.kindRaw)!,
                    systemImage: record.systemImage, colorHex: record.colorHex,
                    isArchived: record.isArchived, isSystem: record.isSystem,
                    sortOrder: record.sortOrder, createdAt: record.createdAt,
                    updatedAt: record.updatedAt
                )
                    context.insert(value)
                }
                value.name = record.name
                value.kindRaw = record.kindRaw
                value.systemImage = record.systemImage
                value.colorHex = record.colorHex
                value.isArchived = record.isArchived
                value.isSystem = record.isSystem
                value.sortOrder = record.sortOrder
                value.createdAt = record.createdAt
                value.updatedAt = record.updatedAt
                categories[record.id] = value
            }
            for record in backup.categoryRules ?? [] {
                let value: CategoryRule
                if let existing = categoryRules[record.id] { value = existing } else {
                    value = CategoryRule(
                    id: record.id, phrase: record.phrase,
                    transactionType: TransactionType(rawValue: record.transactionTypeRaw)!,
                    isActive: record.isActive,
                    createdAt: record.createdAt, updatedAt: record.updatedAt,
                    category: record.categoryID.flatMap { categories[$0] }
                )
                    context.insert(value)
                }
                value.phrase = record.phrase
                value.transactionTypeRaw = record.transactionTypeRaw
                value.isActive = record.isActive
                value.createdAt = record.createdAt
                value.updatedAt = record.updatedAt
                value.category = record.categoryID.flatMap { categories[$0] }
                categoryRules[record.id] = value
            }
            for record in backup.recurringBudgets ?? [] {
                let value: RecurringBudget
                if let existing = recurringBudgets[record.id] { value = existing } else {
                    value = RecurringBudget(
                    id: record.id, startMonth: record.startMonth,
                    endMonth: record.endMonth,
                    baseLimitMinor: record.baseLimitMinor,
                    remainderChoice: BudgetRemainderChoice(rawValue: record.remainderChoiceRaw)!,
                    createdAt: record.createdAt, updatedAt: record.updatedAt,
                    category: record.categoryID.flatMap { categories[$0] }
                )
                    context.insert(value)
                }
                value.startMonth = record.startMonth
                value.endMonth = record.endMonth
                value.baseLimitMinor = record.baseLimitMinor
                value.remainderChoiceRaw = record.remainderChoiceRaw
                value.createdAt = record.createdAt
                value.updatedAt = record.updatedAt
                value.category = record.categoryID.flatMap { categories[$0] }
                recurringBudgets[record.id] = value
            }
            for record in backup.cards {
                let value: PaymentCard
                if let existing = cards[record.id] { value = existing } else {
                    value = PaymentCard(
                    id: record.id, name: record.name,
                    type: PaymentCardType(rawValue: record.typeRaw)!,
                    lastFour: record.lastFour, limitMinor: record.limitMinor,
                    limitKind: record.limitKindRaw.flatMap(CardLimitKind.init(rawValue:)),
                    onlinePurchasesEnabled: record.onlinePurchasesEnabled,
                    contactlessEnabled: record.contactlessEnabled,
                    atmWithdrawalsEnabled: record.atmWithdrawalsEnabled,
                    internationalPaymentsEnabled: record.internationalPaymentsEnabled,
                    cashbackEnabled: record.cashbackEnabled,
                    cashbackPercent: record.cashbackPercent,
                    roundUpEnabled: record.roundUpEnabled, isArchived: record.isArchived,
                    notes: record.notes, createdAt: record.createdAt, updatedAt: record.updatedAt,
                    institution: record.institutionID.flatMap { institutions[$0] },
                    linkedAccount: record.linkedAccountID.flatMap { accounts[$0] }
                )
                    context.insert(value)
                }
                value.name = record.name
                value.typeRaw = record.typeRaw
                value.lastFour = record.lastFour
                value.limitMinor = record.limitMinor
                value.limitKindRaw = record.limitKindRaw
                value.onlinePurchasesEnabled = record.onlinePurchasesEnabled
                value.contactlessEnabled = record.contactlessEnabled
                value.atmWithdrawalsEnabled = record.atmWithdrawalsEnabled
                value.internationalPaymentsEnabled = record.internationalPaymentsEnabled
                value.cashbackEnabled = record.cashbackEnabled
                value.cashbackPercent = record.cashbackPercent
                value.roundUpEnabled = record.roundUpEnabled
                value.isArchived = record.isArchived
                value.notes = record.notes
                value.createdAt = record.createdAt
                value.updatedAt = record.updatedAt
                value.institution = record.institutionID.flatMap { institutions[$0] }
                value.linkedAccount = record.linkedAccountID.flatMap { accounts[$0] }
                cards[record.id] = value
            }
            for record in backup.reservedFunds {
                let value: ReservedFund
                if let existing = reservedFunds[record.id] { value = existing } else {
                    value = ReservedFund(
                    id: record.id, name: record.name, amountMinor: record.amountMinor,
                    notes: record.notes, createdAt: record.createdAt,
                    updatedAt: record.updatedAt,
                    account: record.accountID.flatMap { accounts[$0] }
                )
                    context.insert(value)
                }
                value.name = record.name
                value.amountMinor = record.amountMinor
                value.notes = record.notes
                value.createdAt = record.createdAt
                value.updatedAt = record.updatedAt
                value.account = record.accountID.flatMap { accounts[$0] }
                reservedFunds[record.id] = value
            }
            for record in backup.recurringMovements {
                let value: RecurringMovement
                if let existing = recurringMovements[record.id] { value = existing } else {
                    value = RecurringMovement(
                    id: record.id, name: record.name,
                    type: TransactionType(rawValue: record.typeRaw)!,
                    amountMinor: record.amountMinor,
                    descriptionText: record.descriptionText, notes: record.notes,
                    frequency: RecurrenceFrequency(rawValue: record.frequencyRaw)!,
                    interval: record.interval, nextDueDate: record.nextDueDate,
                    endDate: record.endDate, isActive: record.isActive,
                    isSubscription: record.isSubscription,
                    postsAutomatically: record.postsAutomatically,
                    createdAt: record.createdAt, updatedAt: record.updatedAt,
                    sourceAccount: record.sourceAccountID.flatMap { accounts[$0] },
                    destinationAccount: record.destinationAccountID.flatMap { accounts[$0] },
                    category: record.categoryID.flatMap { categories[$0] }
                )
                    context.insert(value)
                }
                value.name = record.name
                value.typeRaw = record.typeRaw
                value.amountMinor = record.amountMinor
                value.descriptionText = record.descriptionText
                value.notes = record.notes
                value.frequencyRaw = record.frequencyRaw
                value.interval = record.interval
                value.nextDueDate = record.nextDueDate
                value.endDate = record.endDate
                value.isActive = record.isActive
                value.isSubscription = record.isSubscription
                value.postsAutomatically = record.postsAutomatically
                value.createdAt = record.createdAt
                value.updatedAt = record.updatedAt
                value.sourceAccount = record.sourceAccountID.flatMap { accounts[$0] }
                value.destinationAccount = record.destinationAccountID.flatMap { accounts[$0] }
                value.category = record.categoryID.flatMap { categories[$0] }
                recurringMovements[record.id] = value
            }
            for record in backup.transactions {
                let value: FinancialTransaction
                if let existing = transactions[record.id] { value = existing } else {
                    value = FinancialTransaction(
                    id: record.id, date: record.date,
                    type: TransactionType(rawValue: record.typeRaw)!,
                    amountMinor: record.amountMinor,
                    descriptionText: record.descriptionText, notes: record.notes,
                    isReconciled: record.isReconciled, fingerprint: record.fingerprint,
                    duplicateState: DuplicateState(rawValue: record.duplicateStateRaw)!,
                    externalID: record.externalID, bankEntryKey: record.bankEntryKey, importBatchID: record.importBatchID,
                    recurringMovementID: record.recurringMovementID,
                    reservedFundID: record.reservedFundID, reservedAmountMinor: record.reservedAmountMinor,
                    createdAt: record.createdAt, updatedAt: record.updatedAt,
                    sourceAccount: record.sourceAccountID.flatMap { accounts[$0] },
                    destinationAccount: record.destinationAccountID.flatMap { accounts[$0] },
                    category: record.categoryID.flatMap { categories[$0] }
                )
                    context.insert(value)
                }
                value.date = record.date
                value.typeRaw = record.typeRaw
                value.amountMinor = record.amountMinor
                value.descriptionText = record.descriptionText
                value.notes = record.notes
                value.isReconciled = record.isReconciled
                value.fingerprint = record.fingerprint
                value.duplicateStateRaw = record.duplicateStateRaw
                value.externalID = record.externalID
                value.bankEntryKey = record.bankEntryKey
                value.importBatchID = record.importBatchID
                value.recurringMovementID = record.recurringMovementID
                value.reservedFundID = record.reservedFundID
                value.reservedAmountMinor = record.reservedAmountMinor
                value.createdAt = record.createdAt
                value.updatedAt = record.updatedAt
                value.sourceAccount = record.sourceAccountID.flatMap { accounts[$0] }
                value.destinationAccount = record.destinationAccountID.flatMap { accounts[$0] }
                value.category = record.categoryID.flatMap { categories[$0] }
                transactions[record.id] = value
            }
            for record in backup.budgets {
                let value: MonthlyBudget
                if let existing = budgets[record.id] { value = existing } else {
                    value = MonthlyBudget(
                    id: record.id, monthStart: record.monthStart,
                    limitMinor: record.limitMinor, notes: record.notes,
                    createdAt: record.createdAt, updatedAt: record.updatedAt,
                    category: record.categoryID.flatMap { categories[$0] }
                )
                    context.insert(value)
                }
                value.monthStart = record.monthStart
                value.limitMinor = record.limitMinor
                value.notes = record.notes
                value.createdAt = record.createdAt
                value.updatedAt = record.updatedAt
                value.category = record.categoryID.flatMap { categories[$0] }
                budgets[record.id] = value
            }
            for record in backup.goals {
                let value: SavingsGoal
                if let existing = goals[record.id] { value = existing } else {
                    value = SavingsGoal(
                    id: record.id, name: record.name,
                    targetAmountMinor: record.targetAmountMinor,
                    currentAmountMinor: record.currentAmountMinor,
                    targetDate: record.targetDate, colorHex: record.colorHex,
                    notes: record.notes, isCompleted: record.isCompleted,
                    createdAt: record.createdAt, updatedAt: record.updatedAt,
                    linkedAccount: record.linkedAccountID.flatMap { accounts[$0] }
                )
                    context.insert(value)
                }
                value.name = record.name
                value.targetAmountMinor = record.targetAmountMinor
                value.currentAmountMinor = record.currentAmountMinor
                value.targetDate = record.targetDate
                value.colorHex = record.colorHex
                value.notes = record.notes
                value.isCompleted = record.isCompleted
                value.createdAt = record.createdAt
                value.updatedAt = record.updatedAt
                value.linkedAccount = record.linkedAccountID.flatMap { accounts[$0] }
                goals[record.id] = value
            }
            for record in backup.snapshots {
                let value: BalanceSnapshot
                if let existing = snapshots[record.id] { value = existing } else {
                    value = BalanceSnapshot(
                    id: record.id, date: record.date, balanceMinor: record.balanceMinor,
                    source: SnapshotSource(rawValue: record.sourceRaw)!, notes: record.notes,
                    createdAt: record.createdAt,
                    account: record.accountID.flatMap { accounts[$0] }
                )
                    context.insert(value)
                }
                value.date = record.date
                value.balanceMinor = record.balanceMinor
                value.sourceRaw = record.sourceRaw
                value.notes = record.notes
                value.createdAt = record.createdAt
                value.account = record.accountID.flatMap { accounts[$0] }
                snapshots[record.id] = value
            }
            for record in backup.importBatches {
                let value: ImportBatch
                if let existing = importBatches[record.id] { value = existing } else {
                    value = ImportBatch(
                    id: record.id, fileName: record.fileName,
                    source: ImportSource(rawValue: record.sourceRaw)!,
                    institutionName: record.institutionName,
                    importedAt: record.importedAt, importedRows: record.importedRows,
                    skippedDuplicates: record.skippedDuplicates,
                    possibleDuplicates: record.possibleDuplicates,
                    checksum: record.checksum, notes: record.notes
                )
                    context.insert(value)
                }
                value.fileName = record.fileName
                value.sourceRaw = record.sourceRaw
                value.institutionName = record.institutionName
                value.importedAt = record.importedAt
                value.importedRows = record.importedRows
                value.skippedDuplicates = record.skippedDuplicates
                value.possibleDuplicates = record.possibleDuplicates
                value.checksum = record.checksum
                value.notes = record.notes
                importBatches[record.id] = value
            }
            let importBatchesIDs = Set(backup.importBatches.map(\.id))
            for value in importBatches.values where !importBatchesIDs.contains(value.id) { context.delete(value) }
            let snapshotsIDs = Set(backup.snapshots.map(\.id))
            for value in snapshots.values where !snapshotsIDs.contains(value.id) { context.delete(value) }
            let goalsIDs = Set(backup.goals.map(\.id))
            for value in goals.values where !goalsIDs.contains(value.id) { context.delete(value) }
            let budgetsIDs = Set(backup.budgets.map(\.id))
            for value in budgets.values where !budgetsIDs.contains(value.id) { context.delete(value) }
            let transactionsIDs = Set(backup.transactions.map(\.id))
            for value in transactions.values where !transactionsIDs.contains(value.id) { context.delete(value) }
            let recurringMovementsIDs = Set(backup.recurringMovements.map(\.id))
            for value in recurringMovements.values where !recurringMovementsIDs.contains(value.id) { context.delete(value) }
            let reservedFundsIDs = Set(backup.reservedFunds.map(\.id))
            for value in reservedFunds.values where !reservedFundsIDs.contains(value.id) { context.delete(value) }
            let cardsIDs = Set(backup.cards.map(\.id))
            for value in cards.values where !cardsIDs.contains(value.id) { context.delete(value) }
            let recurringBudgetsIDs = Set((backup.recurringBudgets ?? []).map(\.id))
            for value in recurringBudgets.values where !recurringBudgetsIDs.contains(value.id) { context.delete(value) }
            let categoryRulesIDs = Set((backup.categoryRules ?? []).map(\.id))
            for value in categoryRules.values where !categoryRulesIDs.contains(value.id) { context.delete(value) }
            let categoriesIDs = Set(backup.categories.map(\.id))
            for value in categories.values where !categoriesIDs.contains(value.id) { context.delete(value) }
            let accountsIDs = Set(backup.accounts.map(\.id))
            for value in accounts.values where !accountsIDs.contains(value.id) { context.delete(value) }
            let institutionsIDs = Set(backup.institutions.map(\.id))
            for value in institutions.values where !institutionsIDs.contains(value.id) { context.delete(value) }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}
