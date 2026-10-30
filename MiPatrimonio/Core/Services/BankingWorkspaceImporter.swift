import CryptoKit
import Foundation
import SwiftData

enum BankingWorkspaceError: LocalizedError {
    case invalidData, unsupportedEnvironment, environmentChanged, editing, incompleteHistory
    var errorDescription: String? {
        switch self {
        case .invalidData: "No se han guardado los datos recibidos: falta un saldo contable en euros o un identificador, o hay movimientos incoherentes."
        case .unsupportedEnvironment: "Este espacio solo admite datos de demostración o sandbox."
        case .environmentChanged: "Ha cambiado el servidor o el entorno. Vuelve a mis finanzas y abre de nuevo el espacio de prueba."
        case .editing: "Termina de guardar tus cambios antes de actualizar las cuentas."
        case .incompleteHistory: "No se ha podido recibir todo el historial. No se han guardado datos parciales. Vuelve a intentarlo."
        }
    }
}

// Only called by the separate banking test workspace. No credentials, IBANs or
// provider session secrets are persisted here. Existing finance models/backup work
// unchanged; each external identity is scoped to origin, environment and account.
enum BankingWorkspaceImporter {
    static let scenarioID = "mi-patrimonio-v1"
    struct Result { let accounts: Int; let inserted: Int; let skipped: Int; let warnings: [String] }

    static func storeFilename(server: URL, mode: String, scenario: String? = nil) throws -> String {
        guard (scenario == nil || (scenario == scenarioID && mode == "sandbox")),
              ["demo", "sandbox"].contains(mode), server.scheme == "https", let host = server.host,
              server.user == nil, server.password == nil, server.port == nil,
              server.query == nil, server.fragment == nil, server.path.isEmpty || server.path == "/" else {
            throw BankingWorkspaceError.unsupportedEnvironment
        }
        let scope = "https://" + host.lowercased() + (scenario.map { "|" + $0 } ?? "")
        return "MiPatrimonioBankingTests-\(mode)-\(hash(scope)).store"
    }
    private struct Movement {
        let key: String; let date: Date; let amount: Int64; let text: String
        let counterparty: String?; let transfer: String?
    }
    private struct Account {
        let id: UUID; let snapshotID: UUID; let bank: String; let name: String
        let balance: Int64; let openingBalance: Int64; let openingDate: Date
        let movements: [Movement]; let ownership: String?; let role: String?
    }

    @MainActor
    static func apply(_ feeds: [BankingAccountFeed], server: URL, mode: String,
                      in context: ModelContext, observedAt: Date = .now, scenario: String? = nil) throws -> Result {
        let expectedStore = try storeFilename(server: server, mode: mode, scenario: scenario)
        guard !context.container.configurations.contains(where: {
            $0.name == "LocalFinance" || (!$0.isStoredInMemoryOnly && $0.url.lastPathComponent != expectedStore)
        }) else { throw BankingWorkspaceError.unsupportedEnvironment }
        guard !context.hasChanges else { throw BankingWorkspaceError.editing }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withFullDate]
        var prepared: [Account] = []
        var accountIDs = Set<UUID>()
        var warnings: [String] = []
        for feed in feeds {
            guard UUID(uuidString: feed.connection.id) != nil,
                  !feed.account.id.isEmpty, !feed.connection.bank.isEmpty else { throw BankingWorkspaceError.invalidData }
            let role = scenario == scenarioID && feed.connection.bank == "Mock ASPSP"
                && feed.connection.testScenario == scenarioID ? feed.account.testRole : nil
            if scenario != nil && !["daily", "reserved", "investment"].contains(role ?? "") {
                throw BankingWorkspaceError.invalidData
            }
            let namespace = role == nil
                ? [server.absoluteString, mode, feed.connection.id, feed.account.id].joined(separator: "|")
                : ["https://" + (server.host ?? "").lowercased(), mode, scenarioID, role ?? feed.account.id].joined(separator: "|")
            let id = uuid(namespace)
            guard accountIDs.insert(id).inserted else { throw BankingWorkspaceError.invalidData }
            // Opening, expected and available balances cannot stand in for booked money.
            // Prefer intraday booked to closing booked; unsupported accounts do not
            // prevent compatible accounts from being imported.
            let booked = feed.balances.filter { $0.currency == "EUR" && $0.type == "ITBD" }
            let balances = booked.isEmpty ? feed.balances.filter { $0.type == "CLBD" && $0.currency == "EUR" } : booked
            if feed.account.currency != "EUR" || balances.count != 1 {
                if scenario != nil { throw BankingWorkspaceError.invalidData }
                warnings.append("\(feed.connection.bank) · •••• \(feed.account.lastFour): sin un saldo contable único en euros. No se ha importado esta cuenta.")
                continue
            }
            guard (-1_000_000_000_000_000...1_000_000_000_000_000).contains(balances[0].amountMinor),
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
                let row = Movement(key: key, date: date, amount: item.signedAmountMinor, text: text,
                    counterparty: item.counterpartyKey, transfer: item.transferKey)
                if let duplicate = seen[key] {
                    guard duplicate.date == date, duplicate.amount == row.amount, duplicate.text == text,
                          duplicate.counterparty == row.counterparty, duplicate.transfer == row.transfer else {
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
                name: role.map { $0 == "daily" ? "Día a día · Prueba" : ($0 == "reserved" ? "Máster · Prueba" : "Inversión · Prueba") }
                    ?? (feed.account.lastFour.isEmpty ? feed.account.name : "Cuenta •••• \(feed.account.lastFour)"),
                balance: balances[0].amountMinor, openingBalance: opening.partialValue,
                openingDate: rows.map(\.date).min() ?? observedAt, movements: rows,
                ownership: feed.account.ownershipKey, role: role))
        }

        let accounts = try context.fetch(FetchDescriptor<FinancialAccount>())
        var institutions = try context.fetch(FetchDescriptor<FinancialInstitution>())
        let existing = try context.fetch(FetchDescriptor<FinancialTransaction>())
        let snapshots = try context.fetch(FetchDescriptor<BalanceSnapshot>())
        let categories = try context.fetch(FetchDescriptor<FinanceCategory>())
        var rules = try context.fetch(FetchDescriptor<CategoryRule>())
        let setupID = uuid(scenarioID + "|setup")
        let batches = try context.fetch(FetchDescriptor<ImportBatch>())
        let needsSetup = scenario != nil && !batches.contains(where: { $0.id == setupID })
        var known = Set(existing.compactMap(\.externalID))
        var inserted = 0; var skipped = 0
        let batch = ImportBatch(fileName: "Sincronización bancaria de prueba", source: .bankAPI,
            institutionName: prepared.map(\.bank).sorted().joined(separator: ", "), importedAt: observedAt,
            notes: "Datos ficticios · Almacenamiento separado de las finanzas reales")
        do {
            if scenario != nil {
                guard prepared.count == 3, Set(prepared.compactMap(\.role)).count == 3 else { throw BankingWorkspaceError.invalidData }
                if needsSetup { try installScenarioRules(categories: categories, rules: &rules, context: context) }
            }
            var imported: [UUID: FinancialAccount] = [:]
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
                    account = FinancialAccount(id: data.id, name: data.name, type: data.role == "investment" ? .investment : (data.role == "reserved" ? .savings : .checking),
                        openingBalanceMinor: data.openingBalance, openingDate: data.openingDate,
                        notes: "Datos bancarios ficticios · No incluye una cartera de valores", institution: institution)
                    context.insert(account)
                }
                imported[data.id] = account
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
            // Pair only explicit, reciprocal account/reference metadata. Equal
            // coffee purchases remain separate; amount/description alone never pair.
            struct Leg { let account: Account; let row: Movement }
            var groups: [String: [Leg]] = [:]
            for data in prepared {
                for row in data.movements {
                    guard let own = data.ownership, let other = row.counterparty,
                          let reference = row.transfer, !own.isEmpty, !other.isEmpty, !reference.isEmpty,
                          own != other, prepared.filter({ $0.ownership == own }).count == 1,
                          prepared.filter({ $0.ownership == other }).count == 1 else { continue }
                    let direction = row.amount < 0 ? [own, other] : [other, own]
                    let key = ([reference, formatter.string(from: row.date), String(abs(row.amount))] + direction).joined(separator: "|")
                    groups[key, default: []].append(Leg(account: data, row: row))
                }
            }
            var paired = Set<String>()
            for legs in groups.values {
                guard legs.count == 2, let debit = legs.first(where: { $0.row.amount < 0 }),
                      let credit = legs.first(where: { $0.row.amount > 0 }),
                      debit.account.id != credit.account.id else { continue }
                // Existing separately imported legs retain their original meaning;
                // don't silently rewrite a user's previously reviewed records.
                if known.contains(debit.row.key) || known.contains(credit.row.key) { continue }
                paired.insert(debit.row.key); paired.insert(credit.row.key)
                let key = "bank-test-transfer:" + hash([debit.row.key, credit.row.key].sorted().joined(separator: "|"))
                guard known.insert(key).inserted else { skipped += 1; continue }
                context.insert(FinancialTransaction(date: debit.row.date, type: .transfer, amountMinor: -debit.row.amount,
                    descriptionText: debit.row.text, notes: "Transferencia entre cuentas propias · Datos ficticios",
                    isReconciled: true, externalID: key, importBatchID: batch.id,
                    sourceAccount: imported[debit.account.id], destinationAccount: imported[credit.account.id],
                    category: categories.first { $0.name == "Transferencias" }))
                inserted += 1
            }
            for data in prepared {
                for row in data.movements where !paired.contains(row.key) {
                    guard known.insert(row.key).inserted else { skipped += 1; continue }
                    let type: TransactionType = row.amount > 0 ? .income : .expense
                    let category = CategoryRuleService.match(description: row.text, type: type, rules: rules)?.category
                        ?? categories.first(where: { !$0.isArchived && $0.name == (type == .income ? "Otros ingresos" : "Otros gastos") })
                    context.insert(FinancialTransaction(date: row.date, type: type, amountMinor: row.amount,
                        descriptionText: row.text, notes: "Sincronizado · Datos ficticios", isReconciled: true,
                        externalID: row.key, importBatchID: batch.id, sourceAccount: imported[data.id], category: category))
                    inserted += 1
                }
            }
            if needsSetup {
                try installScenarioFeatures(accounts: prepared, imported: imported, categories: categories,
                    context: context, observedAt: observedAt)
                context.insert(ImportBatch(id: setupID, fileName: "Configuración de Mock ASPSP", source: .bankAPI,
                    importedAt: observedAt, notes: "Ejemplos locales instalados una vez. Puedes editarlos o eliminarlos."))
            }
            if inserted > 0 {
                batch.importedRows = inserted; batch.skippedDuplicates = skipped
                context.insert(batch)
            }
            try context.save()
            return Result(accounts: prepared.count, inserted: inserted, skipped: skipped, warnings: warnings)
        } catch { context.rollback(); throw error }
    }

    @MainActor private static func installScenarioRules(categories: [FinanceCategory], rules: inout [CategoryRule], context: ModelContext) throws {
        let mappings = [("Nómina", "Nómina"), ("Supermercado", "Supermercado"), ("Alquiler", "Vivienda"),
            ("Electricidad", "Servicios del hogar"), ("Internet", "Internet y móvil"), ("Transporte", "Transporte"),
            ("Farmacia", "Farmacia"), ("Restaurante", "Restaurantes"), ("Café", "Restaurantes"),
            ("Compras", "Compras"), ("Suscripción", "Suscripciones"), ("Cine", "Ocio"), ("Mascotas", "Mascotas"),
            ("Reembolso", "Reembolsos"), ("Intereses", "Intereses"), ("Dividendos", "Dividendos"),
            ("Comisión", "Impuestos y comisiones")]
        for (phrase, name) in mappings {
            guard let category = categories.first(where: { $0.name == name && !$0.isArchived }) else { continue }
            let type: TransactionType = category.kind == .income ? .income : .expense
            let id = uuid(scenarioID + "|rule|" + phrase)
            guard !rules.contains(where: { $0.id == id || ($0.phrase == phrase && $0.transactionType == type) }) else { continue }
            let rule = CategoryRule(id: id, phrase: phrase, transactionType: type, category: category)
            context.insert(rule); rules.append(rule)
        }
    }

    @MainActor private static func installScenarioFeatures(accounts: [Account], imported: [UUID: FinancialAccount],
        categories: [FinanceCategory], context: ModelContext, observedAt: Date) throws {
        guard let dailyID = accounts.first(where: { $0.role == "daily" })?.id, let daily = imported[dailyID],
              let reservedID = accounts.first(where: { $0.role == "reserved" })?.id, let reserved = imported[reservedID],
              let investmentID = accounts.first(where: { $0.role == "investment" })?.id, let investment = imported[investmentID] else {
            throw BankingWorkspaceError.invalidData
        }
        let funds = try context.fetch(FetchDescriptor<ReservedFund>())
        let fundID = uuid(scenarioID + "|master")
        if !funds.contains(where: { $0.id == fundID }) {
            context.insert(ReservedFund(id: fundID, name: "Máster universitario · Prueba", amountMinor: 150_000,
                notes: "Ejemplo de dinero reservado: se incluye en el patrimonio y se descuenta del disponible.", account: reserved))
        }
        let budgets = try context.fetch(FetchDescriptor<RecurringBudget>())
        let month = observedAt.startOfMonth()
        let limits: [(String, Int64, BudgetRemainderChoice)] = [
            ("Supermercado", 18_000, .save), ("Restaurantes", 6_000, .carryForward),
            ("Transporte", 5_000, .save), ("Suscripciones", 2_000, .carryForward)]
        for (name, limit, choice) in limits {
            let id = uuid(scenarioID + "|budget|" + name)
            guard !budgets.contains(where: { $0.id == id }), let category = categories.first(where: { $0.name == name }) else { continue }
            context.insert(RecurringBudget(id: id, startMonth: month, baseLimitMinor: limit, remainderChoice: choice, category: category))
        }
        let cards = try context.fetch(FetchDescriptor<PaymentCard>())
        let cardID = uuid(scenarioID + "|card")
        if !cards.contains(where: { $0.id == cardID }) {
            context.insert(PaymentCard(id: cardID, name: "Tarjeta diaria · Prueba", type: .debit, lastFour: "4444",
                limitMinor: 60_000, limitKind: .monthly, onlinePurchasesEnabled: true, contactlessEnabled: true,
                atmWithdrawalsEnabled: true, cashbackEnabled: true, cashbackPercent: 1, roundUpEnabled: false,
                notes: "Ejemplo local de tarjeta. No añade saldo al de su cuenta.", institution: daily.institution, linkedAccount: daily))
        }
        // Banked historical entries are already imported. These templates are
        // paused to avoid posting a second copy beside future bank synchronization.
        let recurring = try context.fetch(FetchDescriptor<RecurringMovement>())
        let templates: [(String, TransactionType, Int64, Int, FinancialAccount?, FinanceCategory?)] = [
            ("Aportación a inversión · Prueba", .transfer, 25_000, 5, investment, nil),
            ("Suscripción streaming · Prueba", .expense, 1_299, 12, nil, categories.first { $0.name == "Suscripciones" })]
        for (name, type, amount, day, destination, category) in templates {
            let id = uuid(scenarioID + "|recurring|" + name)
            guard !recurring.contains(where: { $0.id == id }) else { continue }
            let nextMonth = Calendar.current.date(byAdding: .month, value: 1, to: month) ?? observedAt
            let due = Calendar.current.date(byAdding: .day, value: day - 1, to: nextMonth) ?? nextMonth
            context.insert(RecurringMovement(id: id, name: name, type: type, amountMinor: amount, descriptionText: name,
                notes: "Plantilla de prueba pausada: el historial ya viene del banco. Actívala solo para probar el registro periódico sin sincronizar esos mismos cargos.",
                frequency: .monthly, nextDueDate: due, isActive: false, isSubscription: type == .expense,
                postsAutomatically: true, sourceAccount: daily, destinationAccount: destination, category: category))
        }
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func uuid(_ value: String) -> UUID {
        let b = Array(SHA256.hash(data: Data(value.utf8)))
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}
