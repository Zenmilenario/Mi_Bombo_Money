import Foundation
import SwiftData

enum AccountType: String, CaseIterable, Identifiable, Codable {
    case checking
    case savings
    case cash
    case creditCard
    case investment
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .checking: "Cuenta corriente"
        case .savings: "Ahorro"
        case .cash: "Efectivo"
        case .creditCard: "Tarjeta de crédito"
        case .investment: "Inversión"
        case .other: "Otra"
        }
    }

    var systemImage: String {
        switch self {
        case .checking: "building.columns"
        case .savings: "banknote"
        case .cash: "wallet.bifold"
        case .creditCard: "creditcard"
        case .investment: "chart.line.uptrend.xyaxis"
        case .other: "tray.full"
        }
    }

    var isLiability: Bool { self == .creditCard }
}


enum PaymentCardType: String, CaseIterable, Identifiable, Codable {
    case debit
    case credit
    case prepaid
    case virtual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .debit: "Débito"
        case .credit: "Crédito"
        case .prepaid: "Prepago"
        case .virtual: "Virtual"
        }
    }

    var systemImage: String {
        switch self {
        case .debit: "creditcard"
        case .credit: "creditcard.fill"
        case .prepaid: "giftcard"
        case .virtual: "iphone.gen3"
        }
    }
}

enum TransactionType: String, CaseIterable, Identifiable, Codable {
    case income
    case expense
    case interest
    case fee
    case transfer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .income: "Ingreso"
        case .expense: "Gasto"
        case .interest: "Interés"
        case .fee: "Comisión"
        case .transfer: "Transferencia"
        }
    }

    var systemImage: String {
        switch self {
        case .income: "arrow.down.circle"
        case .expense: "arrow.up.circle"
        case .interest: "percent"
        case .fee: "exclamationmark.circle"
        case .transfer: "arrow.left.arrow.right.circle"
        }
    }

    var countsAsIncome: Bool { self == .income || self == .interest }
    var countsAsExpense: Bool { self == .expense || self == .fee }
}

enum CategoryKind: String, CaseIterable, Identifiable, Codable {
    case income
    case expense
    case both
    case transfer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .income: "Ingresos"
        case .expense: "Gastos"
        case .both: "Ingresos y gastos"
        case .transfer: "Transferencias"
        }
    }
}

enum DuplicateState: String, CaseIterable, Identifiable, Codable {
    case none
    case possible
    case confirmed

    var id: String { rawValue }
}

enum RecurrenceFrequency: String, CaseIterable, Identifiable, Codable {
    case weekly
    case monthly
    case quarterly
    case yearly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .weekly: "Semanal"
        case .monthly: "Mensual"
        case .quarterly: "Trimestral"
        case .yearly: "Anual"
        }
    }
}

enum SnapshotSource: String, CaseIterable, Identifiable, Codable {
    case manual
    case importFile
    case bankAPI

    var id: String { rawValue }
}

enum ImportSource: String, CaseIterable, Identifiable, Codable {
    case csv
    case excel
    case bankAPI

    var id: String { rawValue }
}

@Model
final class FinancialInstitution {
    var id: UUID
    var name: String
    var colorHex: String
    var notes: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        colorHex: String = "#1F6B7A",
        notes: String = "",
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class FinancialAccount {
    var id: UUID
    var name: String
    var typeRaw: String
    var currencyCode: String
    var openingBalanceMinor: Int64
    var openingDate: Date
    var annualInterestRate: Double
    var targetBalanceMinor: Int64
    var creditLimitMinor: Int64?
    var includeInNetWorth: Bool
    var isArchived: Bool
    var sortOrder: Int
    var notes: String
    var lastUpdatedAt: Date
    var createdAt: Date
    var updatedAt: Date
    var institution: FinancialInstitution?

    init(
        id: UUID = UUID(),
        name: String,
        type: AccountType,
        currencyCode: String = "EUR",
        openingBalanceMinor: Int64 = 0,
        openingDate: Date = .now,
        annualInterestRate: Double = 0,
        targetBalanceMinor: Int64 = 0,
        creditLimitMinor: Int64? = nil,
        includeInNetWorth: Bool = true,
        isArchived: Bool = false,
        sortOrder: Int = 0,
        notes: String = "",
        lastUpdatedAt: Date = .now,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        institution: FinancialInstitution? = nil
    ) {
        self.id = id
        self.name = name
        self.typeRaw = type.rawValue
        self.currencyCode = currencyCode
        self.openingBalanceMinor = openingBalanceMinor
        self.openingDate = openingDate
        self.annualInterestRate = annualInterestRate
        self.targetBalanceMinor = targetBalanceMinor
        self.creditLimitMinor = creditLimitMinor
        self.includeInNetWorth = includeInNetWorth
        self.isArchived = isArchived
        self.sortOrder = sortOrder
        self.notes = notes
        self.lastUpdatedAt = lastUpdatedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.institution = institution
    }

    var type: AccountType {
        get { AccountType(rawValue: typeRaw) ?? .other }
        set { typeRaw = newValue.rawValue }
    }
}


@Model
final class PaymentCard {
    var id: UUID
    var name: String
    var typeRaw: String
    var lastFour: String
    var isArchived: Bool
    var notes: String
    var createdAt: Date
    var updatedAt: Date
    var institution: FinancialInstitution?
    var linkedAccount: FinancialAccount?

    init(
        id: UUID = UUID(),
        name: String,
        type: PaymentCardType,
        lastFour: String = "",
        isArchived: Bool = false,
        notes: String = "",
        createdAt: Date = .now,
        updatedAt: Date = .now,
        institution: FinancialInstitution? = nil,
        linkedAccount: FinancialAccount? = nil
    ) {
        self.id = id
        self.name = name
        self.typeRaw = type.rawValue
        self.lastFour = String(lastFour.filter(\.isNumber).suffix(4))
        self.isArchived = isArchived
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.institution = institution
        self.linkedAccount = linkedAccount
    }

    var type: PaymentCardType {
        get { PaymentCardType(rawValue: typeRaw) ?? .debit }
        set { typeRaw = newValue.rawValue }
    }
}

@Model
final class FinanceCategory {
    var id: UUID
    var name: String
    var kindRaw: String
    var systemImage: String
    var colorHex: String
    var isArchived: Bool
    var isSystem: Bool
    var sortOrder: Int
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        kind: CategoryKind,
        systemImage: String = "tag",
        colorHex: String = "#4D7C8A",
        isArchived: Bool = false,
        isSystem: Bool = false,
        sortOrder: Int = 0,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.kindRaw = kind.rawValue
        self.systemImage = systemImage
        self.colorHex = colorHex
        self.isArchived = isArchived
        self.isSystem = isSystem
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var kind: CategoryKind {
        get { CategoryKind(rawValue: kindRaw) ?? .expense }
        set { kindRaw = newValue.rawValue }
    }
}

@Model
final class FinancialTransaction {
    var id: UUID
    var date: Date
    var typeRaw: String
    var amountMinor: Int64
    var descriptionText: String
    var notes: String
    var isReconciled: Bool
    var fingerprint: String
    var duplicateStateRaw: String
    var externalID: String?
    var importBatchID: UUID?
    var recurringMovementID: UUID?
    var createdAt: Date
    var updatedAt: Date
    var sourceAccount: FinancialAccount?
    var destinationAccount: FinancialAccount?
    var category: FinanceCategory?

    init(
        id: UUID = UUID(),
        date: Date,
        type: TransactionType,
        amountMinor: Int64,
        descriptionText: String,
        notes: String = "",
        isReconciled: Bool = false,
        fingerprint: String = "",
        duplicateState: DuplicateState = .none,
        externalID: String? = nil,
        importBatchID: UUID? = nil,
        recurringMovementID: UUID? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        sourceAccount: FinancialAccount?,
        destinationAccount: FinancialAccount? = nil,
        category: FinanceCategory? = nil
    ) {
        self.id = id
        self.date = date
        self.typeRaw = type.rawValue
        self.amountMinor = Swift.abs(amountMinor)
        self.descriptionText = descriptionText
        self.notes = notes
        self.isReconciled = isReconciled
        self.fingerprint = fingerprint
        self.duplicateStateRaw = duplicateState.rawValue
        self.externalID = externalID
        self.importBatchID = importBatchID
        self.recurringMovementID = recurringMovementID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sourceAccount = sourceAccount
        self.destinationAccount = destinationAccount
        self.category = category
    }

    var type: TransactionType {
        get { TransactionType(rawValue: typeRaw) ?? .expense }
        set { typeRaw = newValue.rawValue }
    }

    var duplicateState: DuplicateState {
        get { DuplicateState(rawValue: duplicateStateRaw) ?? .none }
        set { duplicateStateRaw = newValue.rawValue }
    }
}

@Model
final class MonthlyBudget {
    var id: UUID
    var monthStart: Date
    var limitMinor: Int64
    var notes: String
    var createdAt: Date
    var updatedAt: Date
    var category: FinanceCategory?

    init(
        id: UUID = UUID(),
        monthStart: Date,
        limitMinor: Int64,
        notes: String = "",
        createdAt: Date = .now,
        updatedAt: Date = .now,
        category: FinanceCategory?
    ) {
        self.id = id
        self.monthStart = monthStart
        self.limitMinor = Swift.max(0, limitMinor)
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.category = category
    }
}

@Model
final class SavingsGoal {
    var id: UUID
    var name: String
    var targetAmountMinor: Int64
    var currentAmountMinor: Int64
    var targetDate: Date?
    var colorHex: String
    var notes: String
    var isCompleted: Bool
    var createdAt: Date
    var updatedAt: Date
    var linkedAccount: FinancialAccount?

    init(
        id: UUID = UUID(),
        name: String,
        targetAmountMinor: Int64,
        currentAmountMinor: Int64 = 0,
        targetDate: Date? = nil,
        colorHex: String = "#2F7D66",
        notes: String = "",
        isCompleted: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        linkedAccount: FinancialAccount? = nil
    ) {
        self.id = id
        self.name = name
        self.targetAmountMinor = Swift.max(0, targetAmountMinor)
        self.currentAmountMinor = Swift.max(0, currentAmountMinor)
        self.targetDate = targetDate
        self.colorHex = colorHex
        self.notes = notes
        self.isCompleted = isCompleted
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.linkedAccount = linkedAccount
    }
}

@Model
final class RecurringMovement {
    var id: UUID
    var name: String
    var typeRaw: String
    var amountMinor: Int64
    var descriptionText: String
    var notes: String
    var frequencyRaw: String
    var interval: Int
    var nextDueDate: Date
    var endDate: Date?
    var isActive: Bool
    var isSubscription: Bool
    var createdAt: Date
    var updatedAt: Date
    var sourceAccount: FinancialAccount?
    var destinationAccount: FinancialAccount?
    var category: FinanceCategory?

    init(
        id: UUID = UUID(),
        name: String,
        type: TransactionType,
        amountMinor: Int64,
        descriptionText: String,
        notes: String = "",
        frequency: RecurrenceFrequency,
        interval: Int = 1,
        nextDueDate: Date,
        endDate: Date? = nil,
        isActive: Bool = true,
        isSubscription: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        sourceAccount: FinancialAccount?,
        destinationAccount: FinancialAccount? = nil,
        category: FinanceCategory? = nil
    ) {
        self.id = id
        self.name = name
        self.typeRaw = type.rawValue
        self.amountMinor = Swift.abs(amountMinor)
        self.descriptionText = descriptionText
        self.notes = notes
        self.frequencyRaw = frequency.rawValue
        self.interval = Swift.max(1, interval)
        self.nextDueDate = nextDueDate
        self.endDate = endDate
        self.isActive = isActive
        self.isSubscription = isSubscription
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sourceAccount = sourceAccount
        self.destinationAccount = destinationAccount
        self.category = category
    }

    var type: TransactionType {
        get { TransactionType(rawValue: typeRaw) ?? .expense }
        set { typeRaw = newValue.rawValue }
    }

    var frequency: RecurrenceFrequency {
        get { RecurrenceFrequency(rawValue: frequencyRaw) ?? .monthly }
        set { frequencyRaw = newValue.rawValue }
    }
}

@Model
final class BalanceSnapshot {
    var id: UUID
    var date: Date
    var balanceMinor: Int64
    var sourceRaw: String
    var notes: String
    var createdAt: Date
    var account: FinancialAccount?

    init(
        id: UUID = UUID(),
        date: Date,
        balanceMinor: Int64,
        source: SnapshotSource = .manual,
        notes: String = "",
        createdAt: Date = .now,
        account: FinancialAccount?
    ) {
        self.id = id
        self.date = date
        self.balanceMinor = balanceMinor
        self.sourceRaw = source.rawValue
        self.notes = notes
        self.createdAt = createdAt
        self.account = account
    }

    var source: SnapshotSource {
        get { SnapshotSource(rawValue: sourceRaw) ?? .manual }
        set { sourceRaw = newValue.rawValue }
    }
}

@Model
final class ImportBatch {
    var id: UUID
    var fileName: String
    var sourceRaw: String
    var institutionName: String
    var importedAt: Date
    var importedRows: Int
    var skippedDuplicates: Int
    var possibleDuplicates: Int
    var checksum: String
    var notes: String

    init(
        id: UUID = UUID(),
        fileName: String,
        source: ImportSource,
        institutionName: String = "",
        importedAt: Date = .now,
        importedRows: Int = 0,
        skippedDuplicates: Int = 0,
        possibleDuplicates: Int = 0,
        checksum: String = "",
        notes: String = ""
    ) {
        self.id = id
        self.fileName = fileName
        self.sourceRaw = source.rawValue
        self.institutionName = institutionName
        self.importedAt = importedAt
        self.importedRows = importedRows
        self.skippedDuplicates = skippedDuplicates
        self.possibleDuplicates = possibleDuplicates
        self.checksum = checksum
        self.notes = notes
    }

    var source: ImportSource {
        get { ImportSource(rawValue: sourceRaw) ?? .csv }
        set { sourceRaw = newValue.rawValue }
    }
}
