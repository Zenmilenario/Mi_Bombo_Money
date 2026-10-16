import CryptoKit
import Foundation
import SwiftData

struct BankingAccountFeed {
    let connection: ConnectedBankSession
    let account: ConnectedBankAccount
    let balances: [BankingPreview.Balance]
    let movements: [BankingPreview.Movement]
}

enum BankingWorkspaceError: LocalizedError {
    case invalidData, unsupportedEnvironment, editing, incompleteHistory
    var errorDescription: String? {
        switch self {
        case .invalidData: "No se han guardado los datos recibidos: falta un saldo contable en euros o un identificador, o hay movimientos incoherentes."
        case .unsupportedEnvironment: "Este espacio solo admite datos de demostración o sandbox."
        case .editing: "Termina de guardar tus cambios antes de actualizar las cuentas."
        case .incompleteHistory: "No se ha podido recibir todo el historial. No se han guardado datos parciales. Vuelve a intentarlo."
        }
    }
}

// Only called by the separate banking test workspace. No credentials, IBANs or
// provider session secrets are persisted here. Existing finance models/backup work
// unchanged; each external identity is scoped to origin, environment and account.
enum BankingWorkspaceImporter {
    struct Result { let accounts: Int; let inserted: Int; let skipped: Int }
    private struct Movement {
        let key: String; let date: Date; let amount: Int64; let text: String
    }
    private struct Account {
        let id: UUID; let snapshotID: UUID; let bank: String; let name: String
        let balance: Int64; let openingBalance: Int64; let openingDate: Date
        let movements: [Movement]
    }

    @MainActor
    static func apply(_ feeds: [BankingAccountFeed], server: URL, mode: String,
                      in context: ModelContext, observedAt: Date = .now) throws -> Result {
        guard ["demo", "sandbox"].contains(mode) else { throw BankingWorkspaceError.unsupportedEnvironment }
        guard !context.container.configurations.contains(where: {
            $0.name == "LocalFinance" || (!$0.isStoredInMemoryOnly && $0.url.lastPathComponent != "MiPatrimonioBankingTests.store")
        }) else { throw BankingWorkspaceError.unsupportedEnvironment }
        guard !context.hasChanges else { throw BankingWorkspaceError.editing }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withFullDate]
        var prepared: [Account] = []
        var accountIDs = Set<UUID>()
        for feed in feeds {
            guard feed.account.currency == "EUR", UUID(uuidString: feed.connection.id) != nil,
                  !feed.account.id.isEmpty, !feed.connection.bank.isEmpty else { throw BankingWorkspaceError.invalidData }
            let namespace = [server.absoluteString, mode, feed.connection.id, feed.account.id].joined(separator: "|")
            let id = uuid(namespace)
            guard accountIDs.insert(id).inserted else { throw BankingWorkspaceError.invalidData }
            // An available balance can include overdraft or card reservations.
            // Only a closed/booked balance is used in this first integration.
            let balances = feed.balances.filter { $0.type == "CLBD" && $0.currency == "EUR" }
            guard balances.count == 1, (-1_000_000_000_000_000...1_000_000_000_000_000).contains(balances[0].amountMinor),
                  feed.movements.count <= 20_000 else { throw BankingWorkspaceError.invalidData }
            var rows: [Movement] = []; var seen: [String: Movement] = [:]; var total: Int64 = 0
            for item in feed.movements {
                guard let externalID = item.id, !externalID.isEmpty, externalID.count <= 512,
                      item.currency == "EUR", item.signedAmountMinor != 0,
                      (-1_000_000_000_000...1_000_000_000_000).contains(item.signedAmountMinor),
                      let date = formatter.date(from: item.bookingDate), formatter.string(from: date) == item.bookingDate,
                      date <= observedAt else { throw BankingWorkspaceError.invalidData }
                let text = item.description.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, text.count <= 4096 else { throw BankingWorkspaceError.invalidData }
                // IDs are never inferred from amount/text: records without stable
                // provider IDs are rejected instead of silently merging purchases.
                let key = "bank-test:" + hash(namespace + "|" + externalID)
                let row = Movement(key: key, date: date, amount: item.signedAmountMinor, text: text)
                if let duplicate = seen[key] {
                    guard duplicate.date == date, duplicate.amount == row.amount, duplicate.text == text else {
                        throw BankingWorkspaceError.invalidData
                    }
                    continue
                }
                let sum = total.addingReportingOverflow(row.amount)
                guard !sum.overflow else { throw BankingWorkspaceError.invalidData }
                total = sum.partialValue; seen[key] = row; rows.append(row)
            }
            let opening = balances[0].amountMinor.subtractingReportingOverflow(total)
            guard !opening.overflow else { throw BankingWorkspaceError.invalidData }
            prepared.append(Account(id: id, snapshotID: uuid(namespace + "|snapshot"), bank: feed.connection.bank,
                name: feed.account.lastFour.isEmpty ? feed.account.name : "Cuenta •••• \(feed.account.lastFour)",
                balance: balances[0].amountMinor, openingBalance: opening.partialValue,
                openingDate: rows.map(\.date).min() ?? observedAt, movements: rows))
        }

        let accounts = try context.fetch(FetchDescriptor<FinancialAccount>())
        var institutions = try context.fetch(FetchDescriptor<FinancialInstitution>())
        let existing = try context.fetch(FetchDescriptor<FinancialTransaction>())
        let snapshots = try context.fetch(FetchDescriptor<BalanceSnapshot>())
        let categories = try context.fetch(FetchDescriptor<FinanceCategory>())
        let rules = try context.fetch(FetchDescriptor<CategoryRule>())
        var known = Set(existing.compactMap(\.externalID))
        var inserted = 0; var skipped = 0
        let batch = ImportBatch(fileName: "Sincronización bancaria de prueba", source: .bankAPI,
            institutionName: prepared.map(\.bank).sorted().joined(separator: ", "), importedAt: observedAt,
            notes: "Datos ficticios · Almacenamiento separado de las finanzas reales")
        do {
            for data in prepared {
                let account: FinancialAccount
                if let found = accounts.first(where: { $0.id == data.id }) { account = found }
                else {
                    let institution: FinancialInstitution
                    if let found = institutions.first(where: { $0.name == data.bank }) { institution = found }
                    else {
                        institution = FinancialInstitution(name: data.bank)
                        context.insert(institution); institutions.append(institution)
                    }
                    // Trade Republic's cash account is not its investment portfolio.
                    account = FinancialAccount(id: data.id, name: data.name, type: .checking,
                        openingBalanceMinor: data.openingBalance, openingDate: data.openingDate,
                        notes: "Datos bancarios ficticios · No incluye una cartera de valores", institution: institution)
                    context.insert(account)
                }
                for row in data.movements {
                    guard known.insert(row.key).inserted else { skipped += 1; continue }
                    let type: TransactionType = row.amount > 0 ? .income : .expense
                    let category = CategoryRuleService.match(description: row.text, type: type, rules: rules)?.category
                        ?? categories.first(where: { !$0.isArchived && $0.name == (type == .income ? "Otros ingresos" : "Otros gastos") })
                    context.insert(FinancialTransaction(date: row.date, type: type, amountMinor: row.amount,
                        descriptionText: row.text, notes: "Sincronizado · Datos ficticios", isReconciled: true,
                        externalID: row.key, importBatchID: batch.id, sourceAccount: account, category: category))
                    inserted += 1
                }
                // Snapshot is authoritative at observation time. Imported history
                // is not added a second time on top of the bank balance.
                if let snapshot = snapshots.first(where: { $0.id == data.snapshotID }) {
                    snapshot.date = observedAt; snapshot.balanceMinor = data.balance
                } else {
                    context.insert(BalanceSnapshot(id: data.snapshotID, date: observedAt,
                        balanceMinor: data.balance, source: .bankAPI, notes: "Saldo bancario de prueba", account: account))
                }
                account.lastUpdatedAt = observedAt; account.updatedAt = observedAt
            }
            if inserted > 0 {
                batch.importedRows = inserted; batch.skippedDuplicates = skipped
                context.insert(batch)
            }
            try context.save()
            return Result(accounts: prepared.count, inserted: inserted, skipped: skipped)
        } catch { context.rollback(); throw error }
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func uuid(_ value: String) -> UUID {
        let b = Array(SHA256.hash(data: Data(value.utf8)))
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}
