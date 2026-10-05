import Foundation
import SwiftData

// Run by .github/workflows/test-backup.yml on macOS, where SwiftData is available.
@main
struct BackupRoundTripCheck {
    @MainActor
    static func main() throws {
        let source = try makeContainer()
        let destination = try makeContainer()
        let context = source.mainContext
        let date = Date(timeIntervalSince1970: 1_750_000_000.125)

        let institution = FinancialInstitution(name: "Entidad de prueba", colorHex: "#ABCDEF", notes: "Notas ñ", createdAt: date, updatedAt: date)
        let account = FinancialAccount(
            name: "Corriente", type: .checking, openingBalanceMinor: 250_000,
            openingDate: date, annualInterestRate: 0.025, targetBalanceMinor: 500_000,
            creditLimitMinor: 10_000, sortOrder: 3, notes: "Cuenta de origen",
            lastUpdatedAt: date, createdAt: date, updatedAt: date, institution: institution
        )
        let investment = FinancialAccount(
            name: "Valores", type: .investment, openingBalanceMinor: -1_000,
            openingDate: date, includeInNetWorth: false, isArchived: true,
            sortOrder: 8, institution: institution
        )
        let category = FinanceCategory(name: "Aportaciones", kind: .transfer, systemImage: "arrow.right", colorHex: "#123456", isArchived: true, isSystem: true, sortOrder: 5)
        let recurring = RecurringMovement(
            name: "Aportación mensual", type: .transfer, amountMinor: 20_000,
            descriptionText: "Aportación", notes: "Regla", frequency: .monthly,
            interval: 2, nextDueDate: date, endDate: date.addingTimeInterval(90_000),
            isActive: false, isSubscription: true, postsAutomatically: true,
            sourceAccount: account, destinationAccount: investment, category: category
        )
        let batch = ImportBatch(fileName: "datos.csv", source: .csv, institutionName: institution.name, importedAt: date, importedRows: 2, skippedDuplicates: 3, possibleDuplicates: 4, checksum: "checksum", notes: "Importación")
        context.insert(institution)
        context.insert(account)
        context.insert(investment)
        context.insert(category)
        context.insert(CategoryRule(phrase: "Aportación", transactionType: .transfer, isActive: false, createdAt: date, updatedAt: date, category: category))
        context.insert(RecurringBudget(startMonth: date, endMonth: date.addingTimeInterval(90 * 86_400), baseLimitMinor: 10_000, remainderChoice: .carryForward, createdAt: date, updatedAt: date, category: category))
        context.insert(recurring)
        context.insert(batch)
        context.insert(PaymentCard(
            name: "Tarjeta", type: .debit, lastFour: "1234", limitMinor: 50_000,
            limitKind: .monthly, onlinePurchasesEnabled: true, contactlessEnabled: false,
            atmWithdrawalsEnabled: nil, internationalPaymentsEnabled: true,
            cashbackEnabled: true, cashbackPercent: 1.25, roundUpEnabled: false,
            isArchived: true, notes: "Tarjeta de prueba", institution: institution,
            linkedAccount: account
        ))
        context.insert(ReservedFund(name: "Máster", amountMinor: 100_000, notes: "Matrícula", account: account))
        context.insert(FinancialTransaction(
            date: date, type: .transfer, amountMinor: 20_000,
            descriptionText: "Transferencia de prueba", notes: "Detalle",
            isReconciled: true, fingerprint: "fingerprint", duplicateState: .possible,
            externalID: "ref-banco", importBatchID: batch.id, recurringMovementID: recurring.id,
            sourceAccount: account, destinationAccount: investment, category: category
        ))
        context.insert(MonthlyBudget(monthStart: date, limitMinor: 30_000, notes: "Presupuesto", category: category))
        context.insert(SavingsGoal(name: "Objetivo", targetAmountMinor: 300_000, currentAmountMinor: 100_000, targetDate: date, colorHex: "#ABC123", notes: "Objetivo", isCompleted: true, linkedAccount: account))
        context.insert(BalanceSnapshot(date: date, balanceMinor: -500, source: .importFile, notes: "Valoración", createdAt: date, account: investment))
        try context.save()

        let encoded = try BackupService.encode(BackupService.capture(in: context))
        let decoded = try BackupService.decode(encoded)
        let expected = try normalized(encoded)
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacy.removeValue(forKey: "categoryRules")
        legacy.removeValue(forKey: "recurringBudgets")
        let legacyBackup = try BackupService.decode(JSONSerialization.data(withJSONObject: legacy))
        precondition(legacyBackup.categoryRules == nil && legacyBackup.recurringBudgets == nil,
                     "Older backups without the new optional collections must remain readable")
        destination.mainContext.insert(FinancialAccount(name: "Debe desaparecer", type: .cash, openingBalanceMinor: 999))
        try destination.mainContext.save()

        for _ in 0..<2 {
            try BackupService.restore(decoded, in: destination.mainContext)
            let restored = try BackupService.encode(BackupService.capture(in: destination.mainContext))
            let actual = try normalized(restored)
            precondition(actual == expected, "Round trip changed data or duplicated records")
        }

        var invalid = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        invalid["formatVersion"] = 999
        try expectRejected(invalid)

        invalid = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        var accounts = invalid["accounts"] as! [[String: Any]]
        accounts.append(accounts[0])
        invalid["accounts"] = accounts
        try expectRejected(invalid)

        invalid = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        var cards = invalid["cards"] as! [[String: Any]]
        cards[0]["linkedAccountID"] = UUID().uuidString
        invalid["cards"] = cards
        try expectRejected(invalid)
        let brokenBackup = try JSONDecoder().decode(FinanceBackup.self, from: JSONSerialization.data(withJSONObject: invalid))
        do {
            try BackupService.restore(brokenBackup, in: destination.mainContext)
            preconditionFailure("Restore accepted a broken relationship")
        } catch is BackupError {
            let unchanged = try BackupService.encode(BackupService.capture(in: destination.mainContext))
            let actual = try normalized(unchanged)
            precondition(actual == expected, "Invalid restore changed existing data")
        }

        invalid = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        var transactions = invalid["transactions"] as! [[String: Any]]
        transactions[0]["amountMinor"] = -1
        invalid["transactions"] = transactions
        try expectRejected(invalid)

        do {
            _ = try BackupService.decode(Data("{incomplete".utf8))
            preconditionFailure("Malformed JSON was accepted")
        } catch is BackupError { }

        let empty = try makeContainer()
        try BackupService.restore(BackupService.capture(in: empty.mainContext), in: destination.mainContext)
        let emptyResult = try BackupService.capture(in: destination.mainContext)
        precondition(emptyResult.totalRecords == 0)
        print("Backup checks passed: complete round trip, repeated restore, invalid input, preservation and empty restore.")
    }

    @MainActor
    private static func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            FinancialInstitution.self, FinancialAccount.self, PaymentCard.self,
            ReservedFund.self, FinanceCategory.self, FinancialTransaction.self,
            CategoryRule.self, MonthlyBudget.self, RecurringBudget.self,
            SavingsGoal.self, RecurringMovement.self,
            BalanceSnapshot.self, ImportBatch.self,
        ])
        return try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private static func normalized(_ data: Data) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object.removeValue(forKey: "exportedAt")
        for key in Array(object.keys) {
            if let records = object[key] as? [[String: Any]] {
                object[key] = records.sorted { ($0["id"] as! String) < ($1["id"] as! String) }
            }
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func expectRejected(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        do {
            _ = try BackupService.decode(data)
            preconditionFailure("Invalid backup was accepted")
        } catch is BackupError { }
    }
}
