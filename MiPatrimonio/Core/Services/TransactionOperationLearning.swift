import CryptoKit
import Foundation
import SwiftData

/// Confirmations belong to a financial profile, never to a global model.
@MainActor
enum TransactionOperationLearning {
    static let didChange = Notification.Name("TransactionOperationLearning.didChange")
    enum LearningError: Error { case unavailable }
    private struct Record: Codable {
        let signature: String
        let kind: TransactionOperationKind
    }
    private struct History: Codable {
        var records: [UUID: Record] = [:]
        var terms: [UUID: [TransactionOperationModel.CardTerms]] = [:]
        var corrections: [UUID: HumanCorrection] = [:]
        var priorCorrections: [UUID: HumanCorrection] = [:]
        var manualReviewIDs: Set<UUID> = []
        var automatic: [UUID: AutomaticCorrection] = [:]
        var automationEnabled = true
        var enabledAt: Date?
        init() { }
        private enum CodingKeys: String, CodingKey { case records, terms, corrections, priorCorrections, manualReviewIDs, automatic, automationEnabled, enabledAt }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            records = try values.decodeIfPresent([UUID: Record].self, forKey: .records) ?? [:]
            terms = try values.decodeIfPresent([UUID: [TransactionOperationModel.CardTerms]].self, forKey: .terms) ?? [:]
            corrections = try values.decodeIfPresent([UUID: HumanCorrection].self, forKey: .corrections) ?? [:]
            priorCorrections = try values.decodeIfPresent([UUID: HumanCorrection].self, forKey: .priorCorrections) ?? [:]
            manualReviewIDs = try values.decodeIfPresent(Set<UUID>.self, forKey: .manualReviewIDs) ?? []
            automatic = try values.decodeIfPresent([UUID: AutomaticCorrection].self, forKey: .automatic) ?? [:]
            automationEnabled = try values.decodeIfPresent(Bool.self, forKey: .automationEnabled) ?? true
            enabledAt = try values.decodeIfPresent(Date.self, forKey: .enabledAt)
        }
    }
    struct Review {
        let confirmed: TransactionOperationKind?
        let prediction: TransactionOperationModel.Prediction?
    }
    private struct Training: Equatable, Sendable {
        let location: URL
        let examples: [TransactionOperationModel.Example]
    }
    private static var training: Training?
    private static var job: Task<TransactionOperationModel?, Never>?
    private struct HumanCorrection: Codable {
        let example: TransactionCorrectionModel.Example
        let signature: String
    }
    private struct AutomaticCorrection: Codable {
        let before: TransactionCorrectionModel.Action
        let after: TransactionCorrectionModel.Action
        let signature: String
        let fingerprint: String
        let validated: Int
    }
    struct EditSnapshot {
        let input: TransactionOperationModel.Input
        let action: TransactionCorrectionModel.Action
        let sourceID: UUID
        let amount: Int64
        let date: Date
        let bankKey: String
        let kind: TransactionOperationKind?
        let signature: String
    }
    struct AutomationStatus {
        let enabled: Bool
        let savedExamples: Int
        let automaticallyApplied: Bool
        let validatedPredictions: Int
    }
    private struct CorrectionTraining: Equatable, Sendable {
        let location: URL
        let examples: [TransactionCorrectionModel.Example]
    }
    private static var correctionTraining: CorrectionTraining?
    private static var correctionJob: Task<TransactionCorrectionModel?, Never>?
    private static var applying: Set<URL> = []

    private static func location(in context: ModelContext) -> URL? {
        guard let configuration = context.container.configurations.first,
              ["LocalFinance", "CloudFinance"].contains(configuration.name) else { return nil }
        return configuration.url.appendingPathExtension("operation-learning-v1.json")
    }
    private static func read(_ url: URL) throws -> History {
        guard FileManager.default.fileExists(atPath: url.path) else { return History() }
        return try JSONDecoder().decode(History.self, from: Data(contentsOf: url))
    }
    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func input(_ transaction: FinancialTransaction, terms: TransactionOperationModel.CardTerms? = nil) -> TransactionOperationModel.Input? {
        guard let account = transaction.sourceAccount, transaction.bankEntryKey != nil,
              !account.isArchived, account.type != .investment, !account.type.isLiability,
              transaction.duplicateState != .possible,
              [.expense, .income, .transfer].contains(transaction.type) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        // Provider booking dates are parsed as UTC; travel must not change the training label.
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month, .day, .weekday], from: transaction.date)
        return .init(text: transaction.descriptionText, amountMinor: transaction.amountMinor,
                     isCredit: transaction.type.countsAsIncome, day: components.day ?? 0,
                     weekday: components.weekday ?? 0,
                     month: "\(components.year ?? 0)-\(components.month ?? 0)",
                     accountKey: hash(account.id.uuidString + "|" + account.currencyCode),
                     savebackPercent: terms?.savebackPercent, roundUpMultiplier: terms?.roundUpMultiplier)
    }
    private static func signature(_ transaction: FinancialTransaction, applying action: TransactionCorrectionModel.Action? = nil) -> String {
        let destinationID: String
        let destinationCurrency: String
        if let action {
            destinationID = action.destinationID?.uuidString ?? ""
            destinationCurrency = action.destinationID == nil ? "" : (transaction.sourceAccount?.currencyCode ?? "")
        } else {
            destinationID = transaction.destinationAccount?.id.uuidString ?? ""
            destinationCurrency = transaction.destinationAccount?.currencyCode ?? ""
        }
        // Preserve the pre-0.6.17 signature format so confirmed identities survive an update.
        let fields: [String] = [transaction.id.uuidString, action?.type ?? transaction.typeRaw, String(transaction.amountMinor),
              String(transaction.date.timeIntervalSince1970), transaction.descriptionText,
              transaction.sourceAccount?.id.uuidString ?? "", destinationID,
              transaction.sourceAccount?.currencyCode ?? "", destinationCurrency, transaction.bankEntryKey ?? ""]
        return hash(fields.joined(separator: "|"))
    }
    static func supports(_ transaction: FinancialTransaction) -> Bool { input(transaction)?.valid == true }

    private static func action(_ row: FinancialTransaction) -> TransactionCorrectionModel.Action {
        .init(type: row.typeRaw, destinationID: row.destinationAccount?.id, categoryID: row.category?.id)
    }

    /// Capture bank facts before an edit; the resulting action is recorded only for a human decision.
    static func captureEdit(_ row: FinancialTransaction, in context: ModelContext) throws -> EditSnapshot? {
        guard row.modelContext === context, supports(row), let location = location(in: context),
              let sourceID = row.sourceAccount?.id, let bankKey = row.bankEntryKey else { return nil }
        if row.type == .transfer {
            guard row.destinationAccount?.type == .investment, row.destinationAccount?.bankIdentityKey == nil else { return nil }
        }
        let history = try read(location)
        guard let value = input(row, terms: applicableTerms(history, transaction: row)) else { return nil }
        let saved = history.records[row.id]
        let priorInput = history.corrections[row.id].flatMap { $0.signature == signature(row) ? $0.example.input : nil }
        return EditSnapshot(input: priorInput ?? value, action: action(row), sourceID: sourceID,
            amount: row.amountMinor, date: row.date, bankKey: bankKey,
            kind: saved?.signature == signature(row) ? saved?.kind : nil, signature: signature(row))
    }

    /// May be staged before the financial save. Signature/action validation ignores failed saves.
    @discardableResult
    static func rememberEdit(_ before: EditSnapshot?, after row: FinancialTransaction, explicitlyReviewed: Bool = false,
                             in context: ModelContext) throws -> Bool {
        guard let before, row.modelContext === context, let location = location(in: context) else { return false }
        var history = try read(location)
        history.manualReviewIDs.insert(row.id)
        let desired = action(row)
        guard (explicitlyReviewed || desired != before.action), supports(row),
              row.sourceAccount?.id == before.sourceID, row.amountMinor == before.amount,
              row.date == before.date, row.bankEntryKey == before.bankKey,
              row.reservedFundID == nil, row.reservedAmountMinor == nil, row.recurringMovementID == nil,
              !before.input.isCredit || row.type != .transfer else {
            try write(history, at: location)
            return true
        }
        if let previous = history.corrections[row.id], previous.signature == before.signature, previous.example.action == before.action {
            history.priorCorrections[row.id] = previous
        }
        history.corrections[row.id] = HumanCorrection(example: .init(input: before.input, action: desired), signature: signature(row))
        history.enabledAt = history.enabledAt ?? .now
        if let kind = before.kind { history.records[row.id] = Record(signature: signature(row), kind: kind) }
        try write(history, at: location)
        return true
    }

    static func rememberCategoryReviews(_ rows: [FinancialTransaction], in context: ModelContext) throws {
        var changed = false
        defer { if changed { feedbackDidSave(in: context) } }
        for row in rows {
            guard row.category != nil else { continue }
            if try rememberEdit(captureEdit(row, in: context), after: row, explicitlyReviewed: true, in: context) {
                changed = true
            }
        }
    }

    static func feedbackDidSave(in context: ModelContext) {
        guard !context.hasChanges, location(in: context) != nil,
              let storeURL = context.container.configurations.first?.url else { return }
        NotificationCenter.default.post(name: didChange, object: storeURL)
    }

    static func automationStatus(for row: FinancialTransaction, in context: ModelContext) throws -> AutomationStatus {
        guard row.modelContext === context, let location = location(in: context) else { throw LearningError.unavailable }
        let history = try read(location)
        let audit = history.automatic[row.id]
        let applied = audit.map { $0.signature == signature(row) && $0.after == action(row) } ?? false
        return .init(enabled: history.automationEnabled, savedExamples: history.corrections.count,
                     automaticallyApplied: applied, validatedPredictions: applied ? audit?.validated ?? 0 : 0)
    }

    static func setAutomationEnabled(_ enabled: Bool, in context: ModelContext) throws {
        guard !context.hasChanges, let location = location(in: context) else { throw LearningError.unavailable }
        var history = try read(location)
        history.automationEnabled = enabled
        try write(history, at: location)
        feedbackDidSave(in: context)
    }

    static func undoAutomaticCorrection(_ row: FinancialTransaction, in context: ModelContext) throws {
        guard !context.hasChanges, row.modelContext === context, let location = location(in: context) else { throw LearningError.unavailable }
        let history = try read(location)
        guard let audit = history.automatic[row.id], audit.signature == signature(row), audit.after == action(row),
              row.reservedFundID == nil, row.reservedAmountMinor == nil, row.recurringMovementID == nil,
              let previousType = TransactionType(rawValue: audit.before.type),
              let before = try captureEdit(row, in: context) else { throw LearningError.unavailable }
        let accounts = try context.fetch(FetchDescriptor<FinancialAccount>())
        let categories = try context.fetch(FetchDescriptor<FinanceCategory>())
        guard audit.before.destinationID == nil || accounts.contains(where: { $0.id == audit.before.destinationID }),
              audit.before.categoryID == nil || categories.contains(where: { $0.id == audit.before.categoryID }) else { throw LearningError.unavailable }
        do {
            row.type = previousType
            row.destinationAccount = accounts.first { $0.id == audit.before.destinationID }
            row.category = categories.first { $0.id == audit.before.categoryID }
            row.fingerprint = audit.fingerprint
            row.updatedAt = .now
            try rememberEdit(before, after: row, explicitlyReviewed: true, in: context)
            try context.save()
            feedbackDidSave(in: context)
        } catch { context.rollback(); throw error }
    }

    static func canApply(_ desired: TransactionCorrectionModel.Action, to row: FinancialTransaction,
                         accounts: [FinancialAccount], categories: [FinanceCategory], transactions: [FinancialTransaction]) -> Bool {
        guard supports(row), row.date <= .now, row.type == .expense || row.type == .income,
              row.destinationAccount == nil, row.category == nil, row.externalID == nil,
              row.reservedFundID == nil, row.reservedAmountMinor == nil, row.recurringMovementID == nil,
              row.duplicateState == .none, let source = row.sourceAccount, action(row) != desired else { return false }
        let category = categories.first { $0.id == desired.categoryID }
        guard desired.categoryID == nil || (category != nil && category?.isArchived == false) else { return false }
        if desired.type == row.typeRaw {
            guard desired.destinationID == nil, let category else { return false }
            return CategoryRuleService.supports(category, for: row.type)
        }
        guard desired.type == TransactionType.transfer.rawValue, row.type == .expense,
              let destination = accounts.first(where: { $0.id == desired.destinationID }), destination.id != source.id,
              destination.type == .investment, !destination.isArchived, destination.bankIdentityKey == nil,
              destination.currencyCode == source.currencyCode, destination.openingDate <= row.date,
              category == nil || category?.kind == .transfer else { return false }
        return !transactions.contains { other in
            guard other.id != row.id, other.amountMinor == row.amountMinor,
                  abs(other.date.timeIntervalSince(row.date)) <= 7 * 86400 else { return false }
            if other.type == .income && other.sourceAccount?.id == destination.id { return true }
            return other.type == .transfer && other.sourceAccount?.id == source.id
                && other.destinationAccount?.id == destination.id && other.bankEntryKey == nil
        }
    }

    static func isApplyingCorrections(in context: ModelContext) -> Bool {
        location(in: context).map { applying.contains($0) } ?? false
    }

    static func applyLearnedCorrections(in context: ModelContext, transactionIDs: Set<UUID>? = nil,
                                        canRun: () -> Bool = { true }) async throws -> Int {
        guard !context.hasChanges, canRun(), !Task.isCancelled, let location = location(in: context),
              !applying.contains(location) else { return 0 }
        applying.insert(location)
        defer { applying.remove(location) }
        var history = try read(location)
        guard history.automationEnabled, let enabledAt = history.enabledAt else { return 0 }
        let rows = try context.fetch(FetchDescriptor<FinancialTransaction>())
        let candidates = rows.filter { row in
            (transactionIDs?.contains(row.id) ?? true) && row.createdAt >= enabledAt
                && row.category == nil && row.destinationAccount == nil
                && history.corrections[row.id] == nil && history.records[row.id] == nil
                && !history.manualReviewIDs.contains(row.id)
                && history.automatic[row.id].map { $0.signature != signature(row) || $0.after != action(row) } != false
                && supports(row)
        }
        guard !candidates.isEmpty else { return 0 }
        let next = CorrectionTraining(location: location, examples: correctionExamples(rows, history: history))
        if correctionTraining != next || correctionJob == nil {
            correctionJob?.cancel()
            correctionTraining = next
            correctionJob = Task.detached(priority: .utility) { TransactionCorrectionModel.train(next.examples) }
        }
        guard let model = await correctionJob?.value, correctionTraining == next,
              !Task.isCancelled, !context.hasChanges, canRun() else { return 0 }
        history = try read(location)
        guard history.automationEnabled else { return 0 }
        let currentRows = try context.fetch(FetchDescriptor<FinancialTransaction>())
        // A cloud merge may have committed changes while the detached model was training.
        guard correctionExamples(currentRows, history: history) == next.examples else { return 0 }
        let candidateIDs = Set(candidates.map(\.id))
        let accounts = try context.fetch(FetchDescriptor<FinancialAccount>())
        let categories = try context.fetch(FetchDescriptor<FinanceCategory>())
        var changes: [(FinancialTransaction, TransactionCorrectionModel.Action)] = []
        for row in currentRows where candidateIDs.contains(row.id) {
            guard history.corrections[row.id] == nil, history.records[row.id] == nil,
                  !history.manualReviewIDs.contains(row.id),
                  let value = input(row, terms: applicableTerms(history, transaction: row)),
                  let decision = model.automaticDecision(value),
                  canApply(decision.action, to: row, accounts: accounts, categories: categories, transactions: currentRows) else { continue }
            history.automatic[row.id] = AutomaticCorrection(before: action(row), after: decision.action,
                signature: signature(row, applying: decision.action), fingerprint: row.fingerprint, validated: decision.validatedPredictions)
            changes.append((row, decision.action))
        }
        guard !changes.isEmpty, canRun(), !Task.isCancelled else { return 0 }
        // Persist recovery information first. A failed financial save leaves an inactive audit.
        try write(history, at: location, invalidateModels: false)
        do {
            for (row, desired) in changes {
                row.type = TransactionType(rawValue: desired.type)!
                row.destinationAccount = accounts.first { $0.id == desired.destinationID }
                row.category = categories.first { $0.id == desired.categoryID }
                row.fingerprint = DuplicateDetectionService.fingerprint(date: row.date, sourceAccountID: row.sourceAccount?.id,
                    destinationAccountID: row.destinationAccount?.id, type: row.type, amountMinor: row.amountMinor, description: row.descriptionText)
                row.updatedAt = .now
            }
            try context.save()
        } catch { context.rollback(); throw error }
        return changes.count
    }

    private static func correctionExamples(_ rows: [FinancialTransaction], history: History) -> [TransactionCorrectionModel.Example] {
        let ordered = rows.sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date }
        let examples = ordered.compactMap { row -> TransactionCorrectionModel.Example? in
            let sample = [history.corrections[row.id], history.priorCorrections[row.id]].compactMap { $0 }
                .first { $0.signature == signature(row) && $0.example.action == action(row) }
            return sample?.example
        }
        return Array(examples.suffix(700))
    }

    static func specializedIDs(in transactions: [FinancialTransaction], context: ModelContext) throws -> Set<UUID> {
        guard let location = location(in: context) else { return [] }
        let history = try read(location)
        return Set(transactions.compactMap { row in
            guard row.modelContext === context, supports(row), let record = history.records[row.id],
                  record.kind != .ordinary, record.signature == signature(row) else { return nil }
            return row.id
        })
    }

    private static func applicableTerms(_ history: History, transaction: FinancialTransaction) -> TransactionOperationModel.CardTerms? {
        guard let accountID = transaction.sourceAccount?.id else { return nil }
        return history.terms[accountID, default: []].filter { $0.valid && $0.validFrom <= transaction.date }
            .max { $0.validFrom < $1.validFrom }
    }
    static func terms(for transaction: FinancialTransaction, in context: ModelContext) throws -> TransactionOperationModel.CardTerms? {
        guard transaction.modelContext === context, let location = location(in: context) else { return nil }
        return applicableTerms(try read(location), transaction: transaction)
    }
    static func saveTerms(_ terms: TransactionOperationModel.CardTerms, transaction: FinancialTransaction, in context: ModelContext) throws {
        guard terms.valid, !context.hasChanges, transaction.modelContext === context,
              supports(transaction), let accountID = transaction.sourceAccount?.id,
              let location = location(in: context) else { throw LearningError.unavailable }
        var history = try read(location)
        history.terms[accountID, default: []].removeAll { $0.validFrom == terms.validFrom }
        history.terms[accountID, default: []].append(terms)
        try write(history, at: location)
        feedbackDidSave(in: context)
    }

    static func review(_ transaction: FinancialTransaction, in context: ModelContext) async throws -> Review {
        guard transaction.modelContext === context, let location = location(in: context) else {
            return Review(confirmed: nil, prediction: nil)
        }
        let history = try read(location)
        guard let current = input(transaction, terms: applicableTerms(history, transaction: transaction)) else {
            return Review(confirmed: nil, prediction: nil)
        }
        if let record = history.records[transaction.id], record.signature == signature(transaction) {
            return Review(confirmed: record.kind, prediction: nil)
        }
        let transactions = try context.fetch(FetchDescriptor<FinancialTransaction>())
        let examples = transactions.sorted { $0.id.uuidString < $1.id.uuidString }.compactMap { row -> TransactionOperationModel.Example? in
            guard let record = history.records[row.id], record.signature == signature(row),
                  let value = input(row, terms: applicableTerms(history, transaction: row)) else { return nil }
            return .init(input: value, kind: record.kind, confirmed: true)
        }
        let next = Training(location: location, examples: Array(examples.prefix(700)))
        if training != next || job == nil {
            job?.cancel()
            training = next
            job = Task.detached(priority: .utility) { TransactionOperationModel.train(next.examples) }
        }
        let revision = signature(transaction)
        let model = await job?.value
        guard !Task.isCancelled, training == next, signature(transaction) == revision else {
            return Review(confirmed: nil, prediction: nil)
        }
        return Review(confirmed: nil, prediction: model?.predict(current))
    }

    /// Only an explicit decision becomes a label. No ledger mutation or bank call occurs here.
    static func confirm(_ kind: TransactionOperationKind?, transaction: FinancialTransaction,
                        in context: ModelContext) throws {
        guard !context.hasChanges, transaction.modelContext === context, let location = location(in: context) else {
            throw LearningError.unavailable
        }
        var history = try read(location)
        guard let value = input(transaction, terms: applicableTerms(history, transaction: transaction)), value.valid else {
            throw LearningError.unavailable
        }
        if let kind {
            history.records[transaction.id] = Record(signature: signature(transaction), kind: kind)
        } else { history.records.removeValue(forKey: transaction.id) }
        try write(history, at: location)
        feedbackDidSave(in: context)
    }

    private static func write(_ history: History, at location: URL, invalidateModels: Bool = true) throws {
        let data = try JSONEncoder().encode(history)
        try data.write(to: location, options: [.atomic, .completeFileProtection])
        var destination = location, attributes = URLResourceValues()
        attributes.isExcludedFromBackup = true
        try destination.setResourceValues(attributes)
        guard invalidateModels else { return }
        training = nil
        job?.cancel()
        job = nil
        correctionJob?.cancel()
        correctionJob = nil
        correctionTraining = nil
    }
}
