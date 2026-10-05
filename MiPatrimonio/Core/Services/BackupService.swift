import Foundation
import SwiftData

enum BackupError: LocalizedError {
    case unsupportedVersion(Int)
    case invalidFile(String)
    case fileTooLarge

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            "La versión de esta copia (\(version)) no es compatible con la app."
        case .invalidFile(let reason):
            "La copia de seguridad no es válida: \(reason)"
        case .fileTooLarge:
            "El archivo supera el límite de 50 MB."
        }
    }
}

struct FinanceBackup: Codable {
    static let currentVersion = 1

    let formatVersion: Int
    let exportedAt: Date
    let institutions: [InstitutionBackup]
    let accounts: [AccountBackup]
    let cards: [CardBackup]
    let reservedFunds: [ReservedFundBackup]
    let categories: [CategoryBackup]
    let categoryRules: [CategoryRuleBackup]?
    let transactions: [TransactionBackup]
    let budgets: [BudgetBackup]
    let recurringBudgets: [RecurringBudgetBackup]?
    let goals: [GoalBackup]
    let recurringMovements: [RecurringBackup]
    let snapshots: [SnapshotBackup]
    let importBatches: [ImportBatchBackup]

    var totalRecords: Int {
        institutions.count + accounts.count + cards.count + reservedFunds.count
            + categories.count + transactions.count + budgets.count + goals.count
            + recurringMovements.count + snapshots.count + importBatches.count
            + (categoryRules?.count ?? 0) + (recurringBudgets?.count ?? 0)
    }

    func validate() throws {
        guard formatVersion == Self.currentVersion else {
            throw BackupError.unsupportedVersion(formatVersion)
        }

        func unique(_ ids: [UUID], label: String) throws -> Set<UUID> {
            let set = Set(ids)
            guard set.count == ids.count else {
                throw BackupError.invalidFile("hay identificadores repetidos en \(label).")
            }
            return set
        }

        func linked(_ id: UUID?, to ids: Set<UUID>, label: String) throws {
            if let id, !ids.contains(id) {
                throw BackupError.invalidFile("falta la relación \(label).")
            }
        }

        let institutionIDs = try unique(institutions.map(\.id), label: "entidades")
        let accountIDs = try unique(accounts.map(\.id), label: "cuentas")
        let categoryIDs = try unique(categories.map(\.id), label: "categorías")
        _ = try unique(cards.map(\.id), label: "tarjetas")
        _ = try unique(reservedFunds.map(\.id), label: "reservas")
        _ = try unique(transactions.map(\.id), label: "movimientos")
        _ = try unique(budgets.map(\.id), label: "presupuestos")
        _ = try unique((recurringBudgets ?? []).map(\.id), label: "presupuestos repetidos")
        _ = try unique((categoryRules ?? []).map(\.id), label: "reglas de categorías")
        _ = try unique(goals.map(\.id), label: "objetivos")
        _ = try unique(recurringMovements.map(\.id), label: "reglas periódicas")
        _ = try unique(snapshots.map(\.id), label: "valoraciones")
        _ = try unique(importBatches.map(\.id), label: "importaciones")

        for account in accounts {
            guard AccountType(rawValue: account.typeRaw) != nil else {
                throw BackupError.invalidFile("tipo de cuenta desconocido.")
            }
            try linked(account.institutionID, to: institutionIDs, label: "entidad de una cuenta")
        }
        for card in cards {
            guard PaymentCardType(rawValue: card.typeRaw) != nil else {
                throw BackupError.invalidFile("tipo o límite de tarjeta desconocido.")
            }
            if let raw = card.limitKindRaw, CardLimitKind(rawValue: raw) == nil {
                throw BackupError.invalidFile("tipo de límite de tarjeta desconocido.")
            }
            try linked(card.institutionID, to: institutionIDs, label: "entidad de una tarjeta")
            try linked(card.linkedAccountID, to: accountIDs, label: "cuenta de una tarjeta")
        }
        for fund in reservedFunds {
            guard fund.amountMinor >= 0 else {
                throw BackupError.invalidFile("importe reservado negativo.")
            }
            try linked(fund.accountID, to: accountIDs, label: "cuenta de una reserva")
        }
        for category in categories where CategoryKind(rawValue: category.kindRaw) == nil {
            throw BackupError.invalidFile("tipo de categoría desconocido.")
        }
        for rule in categoryRules ?? [] {
            guard TransactionType(rawValue: rule.transactionTypeRaw) != nil,
                  CategoryRuleService.normalized(rule.phrase).count >= 3,
                  rule.categoryID != nil else {
                throw BackupError.invalidFile("regla de categoría inválida.")
            }
            try linked(rule.categoryID, to: categoryIDs, label: "categoría de una regla")
        }
        for transaction in transactions {
            guard TransactionType(rawValue: transaction.typeRaw) != nil,
                  DuplicateState(rawValue: transaction.duplicateStateRaw) != nil,
                  transaction.amountMinor >= 0 else {
                throw BackupError.invalidFile("movimiento con tipo, estado o importe inválido.")
            }
            try linked(transaction.sourceAccountID, to: accountIDs, label: "cuenta origen de un movimiento")
            try linked(transaction.destinationAccountID, to: accountIDs, label: "cuenta destino de un movimiento")
            try linked(transaction.categoryID, to: categoryIDs, label: "categoría de un movimiento")
        }
        for budget in budgets {
            guard budget.limitMinor >= 0 else {
                throw BackupError.invalidFile("límite de presupuesto negativo.")
            }
            try linked(budget.categoryID, to: categoryIDs, label: "categoría de un presupuesto")
        }
        for plan in recurringBudgets ?? [] {
            guard plan.baseLimitMinor > 0,
                  BudgetRemainderChoice(rawValue: plan.remainderChoiceRaw) != nil,
                  plan.endMonth.map({ $0 > plan.startMonth }) ?? true,
                  plan.categoryID != nil else {
                throw BackupError.invalidFile("presupuesto repetido inválido.")
            }
            try linked(plan.categoryID, to: categoryIDs, label: "categoría de un presupuesto repetido")
        }
        for goal in goals {
            guard goal.targetAmountMinor >= 0, goal.currentAmountMinor >= 0 else {
                throw BackupError.invalidFile("importe de objetivo negativo.")
            }
            try linked(goal.linkedAccountID, to: accountIDs, label: "cuenta de un objetivo")
        }
        for recurring in recurringMovements {
            guard TransactionType(rawValue: recurring.typeRaw) != nil,
                  RecurrenceFrequency(rawValue: recurring.frequencyRaw) != nil,
                  recurring.amountMinor >= 0, recurring.interval > 0 else {
                throw BackupError.invalidFile("regla periódica inválida.")
            }
            try linked(recurring.sourceAccountID, to: accountIDs, label: "cuenta origen de una regla")
            try linked(recurring.destinationAccountID, to: accountIDs, label: "cuenta destino de una regla")
            try linked(recurring.categoryID, to: categoryIDs, label: "categoría de una regla")
        }
        for snapshot in snapshots {
            guard SnapshotSource(rawValue: snapshot.sourceRaw) != nil else {
                throw BackupError.invalidFile("origen de valoración desconocido.")
            }
            try linked(snapshot.accountID, to: accountIDs, label: "cuenta de una valoración")
        }
        for batch in importBatches where ImportSource(rawValue: batch.sourceRaw) == nil {
            throw BackupError.invalidFile("origen de importación desconocido.")
        }
    }
}

struct InstitutionBackup: Codable {
    let id: UUID
    let name: String
    let colorHex: String
    let notes: String
    let createdAt: Date
    let updatedAt: Date

    init(_ value: FinancialInstitution) {
        id = value.id; name = value.name; colorHex = value.colorHex; notes = value.notes
        createdAt = value.createdAt; updatedAt = value.updatedAt
    }
}

struct AccountBackup: Codable {
    let id: UUID
    let name: String
    let typeRaw: String
    let currencyCode: String
    let openingBalanceMinor: Int64
    let openingDate: Date
    let annualInterestRate: Double
    let targetBalanceMinor: Int64
    let creditLimitMinor: Int64?
    let includeInNetWorth: Bool
    let isArchived: Bool
    let sortOrder: Int
    let notes: String
    let lastUpdatedAt: Date
    let createdAt: Date
    let updatedAt: Date
    let institutionID: UUID?

    init(_ value: FinancialAccount) {
        id = value.id; name = value.name; typeRaw = value.typeRaw
        currencyCode = value.currencyCode; openingBalanceMinor = value.openingBalanceMinor
        openingDate = value.openingDate; annualInterestRate = value.annualInterestRate
        targetBalanceMinor = value.targetBalanceMinor; creditLimitMinor = value.creditLimitMinor
        includeInNetWorth = value.includeInNetWorth; isArchived = value.isArchived
        sortOrder = value.sortOrder; notes = value.notes; lastUpdatedAt = value.lastUpdatedAt
        createdAt = value.createdAt; updatedAt = value.updatedAt
        institutionID = value.institution?.id
    }
}

struct CardBackup: Codable {
    let id: UUID
    let name: String
    let typeRaw: String
    let lastFour: String
    let limitMinor: Int64?
    let limitKindRaw: String?
    let onlinePurchasesEnabled: Bool?
    let contactlessEnabled: Bool?
    let atmWithdrawalsEnabled: Bool?
    let internationalPaymentsEnabled: Bool?
    let cashbackEnabled: Bool?
    let cashbackPercent: Double?
    let roundUpEnabled: Bool?
    let isArchived: Bool
    let notes: String
    let createdAt: Date
    let updatedAt: Date
    let institutionID: UUID?
    let linkedAccountID: UUID?

    init(_ value: PaymentCard) {
        id = value.id; name = value.name; typeRaw = value.typeRaw; lastFour = value.lastFour
        limitMinor = value.limitMinor; limitKindRaw = value.limitKindRaw
        onlinePurchasesEnabled = value.onlinePurchasesEnabled
        contactlessEnabled = value.contactlessEnabled
        atmWithdrawalsEnabled = value.atmWithdrawalsEnabled
        internationalPaymentsEnabled = value.internationalPaymentsEnabled
        cashbackEnabled = value.cashbackEnabled; cashbackPercent = value.cashbackPercent
        roundUpEnabled = value.roundUpEnabled; isArchived = value.isArchived
        notes = value.notes; createdAt = value.createdAt; updatedAt = value.updatedAt
        institutionID = value.institution?.id; linkedAccountID = value.linkedAccount?.id
    }
}

struct ReservedFundBackup: Codable {
    let id: UUID
    let name: String
    let amountMinor: Int64
    let notes: String
    let createdAt: Date
    let updatedAt: Date
    let accountID: UUID?

    init(_ value: ReservedFund) {
        id = value.id; name = value.name; amountMinor = value.amountMinor; notes = value.notes
        createdAt = value.createdAt; updatedAt = value.updatedAt; accountID = value.account?.id
    }
}

struct CategoryBackup: Codable {
    let id: UUID
    let name: String
    let kindRaw: String
    let systemImage: String
    let colorHex: String
    let isArchived: Bool
    let isSystem: Bool
    let sortOrder: Int
    let createdAt: Date
    let updatedAt: Date

    init(_ value: FinanceCategory) {
        id = value.id; name = value.name; kindRaw = value.kindRaw
        systemImage = value.systemImage; colorHex = value.colorHex
        isArchived = value.isArchived; isSystem = value.isSystem; sortOrder = value.sortOrder
        createdAt = value.createdAt; updatedAt = value.updatedAt
    }
}

struct CategoryRuleBackup: Codable {
    let id: UUID
    let phrase: String
    let transactionTypeRaw: String
    let isActive: Bool
    let createdAt: Date
    let updatedAt: Date
    let categoryID: UUID?

    init(_ value: CategoryRule) {
        id = value.id; phrase = value.phrase
        transactionTypeRaw = value.transactionTypeRaw
        isActive = value.isActive; createdAt = value.createdAt
        updatedAt = value.updatedAt; categoryID = value.category?.id
    }
}

struct TransactionBackup: Codable {
    let id: UUID
    let date: Date
    let typeRaw: String
    let amountMinor: Int64
    let descriptionText: String
    let notes: String
    let isReconciled: Bool
    let fingerprint: String
    let duplicateStateRaw: String
    let externalID: String?
    let importBatchID: UUID?
    let recurringMovementID: UUID?
    let createdAt: Date
    let updatedAt: Date
    let sourceAccountID: UUID?
    let destinationAccountID: UUID?
    let categoryID: UUID?

    init(_ value: FinancialTransaction) {
        id = value.id; date = value.date; typeRaw = value.typeRaw
        amountMinor = value.amountMinor; descriptionText = value.descriptionText
        notes = value.notes; isReconciled = value.isReconciled; fingerprint = value.fingerprint
        duplicateStateRaw = value.duplicateStateRaw; externalID = value.externalID
        importBatchID = value.importBatchID; recurringMovementID = value.recurringMovementID
        createdAt = value.createdAt; updatedAt = value.updatedAt
        sourceAccountID = value.sourceAccount?.id
        destinationAccountID = value.destinationAccount?.id; categoryID = value.category?.id
    }
}

struct BudgetBackup: Codable {
    let id: UUID
    let monthStart: Date
    let limitMinor: Int64
    let notes: String
    let createdAt: Date
    let updatedAt: Date
    let categoryID: UUID?

    init(_ value: MonthlyBudget) {
        id = value.id; monthStart = value.monthStart; limitMinor = value.limitMinor
        notes = value.notes; createdAt = value.createdAt; updatedAt = value.updatedAt
        categoryID = value.category?.id
    }
}

struct RecurringBudgetBackup: Codable {
    let id: UUID
    let startMonth: Date
    let endMonth: Date?
    let baseLimitMinor: Int64
    let remainderChoiceRaw: String
    let createdAt: Date
    let updatedAt: Date
    let categoryID: UUID?

    init(_ value: RecurringBudget) {
        id = value.id; startMonth = value.startMonth
        endMonth = value.endMonth; baseLimitMinor = value.baseLimitMinor
        remainderChoiceRaw = value.remainderChoiceRaw
        createdAt = value.createdAt; updatedAt = value.updatedAt
        categoryID = value.category?.id
    }
}

struct GoalBackup: Codable {
    let id: UUID
    let name: String
    let targetAmountMinor: Int64
    let currentAmountMinor: Int64
    let targetDate: Date?
    let colorHex: String
    let notes: String
    let isCompleted: Bool
    let createdAt: Date
    let updatedAt: Date
    let linkedAccountID: UUID?

    init(_ value: SavingsGoal) {
        id = value.id; name = value.name; targetAmountMinor = value.targetAmountMinor
        currentAmountMinor = value.currentAmountMinor; targetDate = value.targetDate
        colorHex = value.colorHex; notes = value.notes; isCompleted = value.isCompleted
        createdAt = value.createdAt; updatedAt = value.updatedAt
        linkedAccountID = value.linkedAccount?.id
    }
}

struct RecurringBackup: Codable {
    let id: UUID
    let name: String
    let typeRaw: String
    let amountMinor: Int64
    let descriptionText: String
    let notes: String
    let frequencyRaw: String
    let interval: Int
    let nextDueDate: Date
    let endDate: Date?
    let isActive: Bool
    let isSubscription: Bool
    let postsAutomatically: Bool?
    let createdAt: Date
    let updatedAt: Date
    let sourceAccountID: UUID?
    let destinationAccountID: UUID?
    let categoryID: UUID?

    init(_ value: RecurringMovement) {
        id = value.id; name = value.name; typeRaw = value.typeRaw
        amountMinor = value.amountMinor; descriptionText = value.descriptionText
        notes = value.notes; frequencyRaw = value.frequencyRaw; interval = value.interval
        nextDueDate = value.nextDueDate; endDate = value.endDate; isActive = value.isActive
        isSubscription = value.isSubscription; postsAutomatically = value.postsAutomatically
        createdAt = value.createdAt; updatedAt = value.updatedAt
        sourceAccountID = value.sourceAccount?.id
        destinationAccountID = value.destinationAccount?.id; categoryID = value.category?.id
    }
}

struct SnapshotBackup: Codable {
    let id: UUID
    let date: Date
    let balanceMinor: Int64
    let sourceRaw: String
    let notes: String
    let createdAt: Date
    let accountID: UUID?

    init(_ value: BalanceSnapshot) {
        id = value.id; date = value.date; balanceMinor = value.balanceMinor
        sourceRaw = value.sourceRaw; notes = value.notes; createdAt = value.createdAt
        accountID = value.account?.id
    }
}

struct ImportBatchBackup: Codable {
    let id: UUID
    let fileName: String
    let sourceRaw: String
    let institutionName: String
    let importedAt: Date
    let importedRows: Int
    let skippedDuplicates: Int
    let possibleDuplicates: Int
    let checksum: String
    let notes: String

    init(_ value: ImportBatch) {
        id = value.id; fileName = value.fileName; sourceRaw = value.sourceRaw
        institutionName = value.institutionName; importedAt = value.importedAt
        importedRows = value.importedRows; skippedDuplicates = value.skippedDuplicates
        possibleDuplicates = value.possibleDuplicates; checksum = value.checksum
        notes = value.notes
    }
}

enum BackupService {
    private struct Header: Decodable {
        let formatVersion: Int
    }

    static func capture(in context: ModelContext) throws -> FinanceBackup {
        FinanceBackup(
            formatVersion: FinanceBackup.currentVersion,
            exportedAt: .now,
            institutions: try context.fetch(FetchDescriptor<FinancialInstitution>()).map(InstitutionBackup.init),
            accounts: try context.fetch(FetchDescriptor<FinancialAccount>()).map(AccountBackup.init),
            cards: try context.fetch(FetchDescriptor<PaymentCard>()).map(CardBackup.init),
            reservedFunds: try context.fetch(FetchDescriptor<ReservedFund>()).map(ReservedFundBackup.init),
            categories: try context.fetch(FetchDescriptor<FinanceCategory>()).map(CategoryBackup.init),
            categoryRules: try context.fetch(FetchDescriptor<CategoryRule>()).map(CategoryRuleBackup.init),
            transactions: try context.fetch(FetchDescriptor<FinancialTransaction>()).map(TransactionBackup.init),
            budgets: try context.fetch(FetchDescriptor<MonthlyBudget>()).map(BudgetBackup.init),
            recurringBudgets: try context.fetch(FetchDescriptor<RecurringBudget>()).map(RecurringBudgetBackup.init),
            goals: try context.fetch(FetchDescriptor<SavingsGoal>()).map(GoalBackup.init),
            recurringMovements: try context.fetch(FetchDescriptor<RecurringMovement>()).map(RecurringBackup.init),
            snapshots: try context.fetch(FetchDescriptor<BalanceSnapshot>()).map(SnapshotBackup.init),
            importBatches: try context.fetch(FetchDescriptor<ImportBatch>()).map(ImportBatchBackup.init)
        )
    }

    static func encode(_ backup: FinanceBackup) throws -> Data {
        try backup.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(backup)
        guard data.count <= 50_000_000 else { throw BackupError.fileTooLarge }
        return data
    }

    static func decode(_ data: Data) throws -> FinanceBackup {
        guard data.count <= 50_000_000 else { throw BackupError.fileTooLarge }
        do {
            let decoder = JSONDecoder()
            let header = try decoder.decode(Header.self, from: data)
            guard header.formatVersion == FinanceBackup.currentVersion else {
                throw BackupError.unsupportedVersion(header.formatVersion)
            }
            let backup = try decoder.decode(FinanceBackup.self, from: data)
            try backup.validate()
            return backup
        } catch let error as BackupError {
            throw error
        } catch {
            throw BackupError.invalidFile("el JSON está incompleto o dañado.")
        }
    }

    static func restore(_ backup: FinanceBackup, in context: ModelContext) throws {
        try backup.validate()
        // Preserve prior edits and stage the replacement until its single final save.
        try context.save()
        let wasAutosaveEnabled = context.autosaveEnabled
        context.autosaveEnabled = false
        defer { context.autosaveEnabled = wasAutosaveEnabled }

        do {
            try stageDeletion(FinancialTransaction.self, in: context)
            try stageDeletion(RecurringMovement.self, in: context)
            try stageDeletion(MonthlyBudget.self, in: context)
            try stageDeletion(RecurringBudget.self, in: context)
            try stageDeletion(CategoryRule.self, in: context)
            try stageDeletion(SavingsGoal.self, in: context)
            try stageDeletion(ReservedFund.self, in: context)
            try stageDeletion(BalanceSnapshot.self, in: context)
            try stageDeletion(PaymentCard.self, in: context)
            try stageDeletion(ImportBatch.self, in: context)
            try stageDeletion(FinancialAccount.self, in: context)
            try stageDeletion(FinanceCategory.self, in: context)
            try stageDeletion(FinancialInstitution.self, in: context)

            var institutions: [UUID: FinancialInstitution] = [:]
            for record in backup.institutions {
                let value = FinancialInstitution(
                    id: record.id, name: record.name, colorHex: record.colorHex,
                    notes: record.notes, createdAt: record.createdAt, updatedAt: record.updatedAt
                )
                context.insert(value)
                institutions[record.id] = value
            }

            var accounts: [UUID: FinancialAccount] = [:]
            for record in backup.accounts {
                let value = FinancialAccount(
                    id: record.id, name: record.name,
                    type: AccountType(rawValue: record.typeRaw)!,
                    currencyCode: record.currencyCode,
                    openingBalanceMinor: record.openingBalanceMinor,
                    openingDate: record.openingDate,
                    annualInterestRate: record.annualInterestRate,
                    targetBalanceMinor: record.targetBalanceMinor,
                    creditLimitMinor: record.creditLimitMinor,
                    includeInNetWorth: record.includeInNetWorth,
                    isArchived: record.isArchived, sortOrder: record.sortOrder,
                    notes: record.notes, lastUpdatedAt: record.lastUpdatedAt,
                    createdAt: record.createdAt, updatedAt: record.updatedAt,
                    institution: record.institutionID.flatMap { institutions[$0] }
                )
                context.insert(value)
                accounts[record.id] = value
            }

            var categories: [UUID: FinanceCategory] = [:]
            for record in backup.categories {
                let value = FinanceCategory(
                    id: record.id, name: record.name,
                    kind: CategoryKind(rawValue: record.kindRaw)!,
                    systemImage: record.systemImage, colorHex: record.colorHex,
                    isArchived: record.isArchived, isSystem: record.isSystem,
                    sortOrder: record.sortOrder, createdAt: record.createdAt,
                    updatedAt: record.updatedAt
                )
                context.insert(value)
                categories[record.id] = value
            }

            for record in backup.categoryRules ?? [] {
                context.insert(CategoryRule(
                    id: record.id, phrase: record.phrase,
                    transactionType: TransactionType(rawValue: record.transactionTypeRaw)!,
                    isActive: record.isActive,
                    createdAt: record.createdAt, updatedAt: record.updatedAt,
                    category: record.categoryID.flatMap { categories[$0] }
                ))
            }

            for record in backup.recurringBudgets ?? [] {
                context.insert(RecurringBudget(
                    id: record.id, startMonth: record.startMonth,
                    endMonth: record.endMonth,
                    baseLimitMinor: record.baseLimitMinor,
                    remainderChoice: BudgetRemainderChoice(rawValue: record.remainderChoiceRaw)!,
                    createdAt: record.createdAt, updatedAt: record.updatedAt,
                    category: record.categoryID.flatMap { categories[$0] }
                ))
            }

            for record in backup.cards {
                context.insert(PaymentCard(
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
                ))
            }
            for record in backup.reservedFunds {
                context.insert(ReservedFund(
                    id: record.id, name: record.name, amountMinor: record.amountMinor,
                    notes: record.notes, createdAt: record.createdAt,
                    updatedAt: record.updatedAt,
                    account: record.accountID.flatMap { accounts[$0] }
                ))
            }
            for record in backup.recurringMovements {
                context.insert(RecurringMovement(
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
                ))
            }
            for record in backup.transactions {
                context.insert(FinancialTransaction(
                    id: record.id, date: record.date,
                    type: TransactionType(rawValue: record.typeRaw)!,
                    amountMinor: record.amountMinor,
                    descriptionText: record.descriptionText, notes: record.notes,
                    isReconciled: record.isReconciled, fingerprint: record.fingerprint,
                    duplicateState: DuplicateState(rawValue: record.duplicateStateRaw)!,
                    externalID: record.externalID, importBatchID: record.importBatchID,
                    recurringMovementID: record.recurringMovementID,
                    createdAt: record.createdAt, updatedAt: record.updatedAt,
                    sourceAccount: record.sourceAccountID.flatMap { accounts[$0] },
                    destinationAccount: record.destinationAccountID.flatMap { accounts[$0] },
                    category: record.categoryID.flatMap { categories[$0] }
                ))
            }
            for record in backup.budgets {
                context.insert(MonthlyBudget(
                    id: record.id, monthStart: record.monthStart,
                    limitMinor: record.limitMinor, notes: record.notes,
                    createdAt: record.createdAt, updatedAt: record.updatedAt,
                    category: record.categoryID.flatMap { categories[$0] }
                ))
            }
            for record in backup.goals {
                context.insert(SavingsGoal(
                    id: record.id, name: record.name,
                    targetAmountMinor: record.targetAmountMinor,
                    currentAmountMinor: record.currentAmountMinor,
                    targetDate: record.targetDate, colorHex: record.colorHex,
                    notes: record.notes, isCompleted: record.isCompleted,
                    createdAt: record.createdAt, updatedAt: record.updatedAt,
                    linkedAccount: record.linkedAccountID.flatMap { accounts[$0] }
                ))
            }
            for record in backup.snapshots {
                context.insert(BalanceSnapshot(
                    id: record.id, date: record.date, balanceMinor: record.balanceMinor,
                    source: SnapshotSource(rawValue: record.sourceRaw)!, notes: record.notes,
                    createdAt: record.createdAt,
                    account: record.accountID.flatMap { accounts[$0] }
                ))
            }
            for record in backup.importBatches {
                context.insert(ImportBatch(
                    id: record.id, fileName: record.fileName,
                    source: ImportSource(rawValue: record.sourceRaw)!,
                    institutionName: record.institutionName,
                    importedAt: record.importedAt, importedRows: record.importedRows,
                    skippedDuplicates: record.skippedDuplicates,
                    possibleDuplicates: record.possibleDuplicates,
                    checksum: record.checksum, notes: record.notes
                ))
            }

            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    private static func stageDeletion<Model: PersistentModel>(
        _ type: Model.Type,
        in context: ModelContext
    ) throws {
        for model in try context.fetch(FetchDescriptor<Model>()) {
            context.delete(model)
        }
    }
}
