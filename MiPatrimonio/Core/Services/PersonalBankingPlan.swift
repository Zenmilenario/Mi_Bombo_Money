import Foundation

/// An unavailable bank must not discard another bank's complete download.
enum PersonalBankingDownloadBatch {
    enum Outcome {
        case downloaded(bank: String, feeds: [BankingAccountFeed])
        case failed(bank: String, error: Error)
    }
    @MainActor static func load(_ connections: [ConnectedBankSession],
                               fetch: ([ConnectedBankSession]) async throws -> [BankingAccountFeed]) async throws -> [Outcome] {
        let groups = Dictionary(grouping: connections, by: \.bank)
        var outcomes: [Outcome] = []
        for bank in groups.keys.sorted() {
            try Task.checkCancellation()
            do { outcomes.append(.downloaded(bank: bank, feeds: try await fetch(groups[bank]!))) }
            catch is CancellationError { throw CancellationError() }
            catch let error as URLError where error.code == .cancelled { throw error }
            catch { outcomes.append(.failed(bank: bank, error: error)) }
        }
        return outcomes
    }
}

/// Keep unpaired own transfers out of expenses/income while importing independent postings.
struct PersonalBankingDownloadSelection {
    let feeds: [BankingAccountFeed]
    let deferredByBank: [String: Int]

    static func prepare(_ feeds: [BankingAccountFeed], knownAccounts: [ConnectedBankAccount]) throws -> Self {
        var identities: [String: String] = [:]
        for remote in knownAccounts {
            if let own = remote.ownershipKey {
                if let previous = identities[own], previous != remote.id { throw PersonalBankingError.invalidData }
                identities[own] = remote.id
            }
        }
        var deferred: [String: Int] = [:]
        let selected = feeds.map { feed in
            let rows = feed.movements.filter { row in
                guard let otherKey = row.counterpartyKey, let other = identities[otherKey], other != feed.account.id else { return true }
                let own = feed.account.ownershipKey
                let matches = feeds.filter { $0.account.id == other }.flatMap(\.movements).filter {
                    own != nil && $0.counterpartyKey == own && row.transferKey != nil && $0.transferKey == row.transferKey
                        && $0.bookingDate == row.bookingDate && $0.signedAmountMinor != Int64.min
                        && row.signedAmountMinor == -$0.signedAmountMinor && $0.currency == row.currency
                }
                if matches.count == 1 {
                    let peer = matches[0]
                    let reverse = feed.movements.filter {
                        $0.counterpartyKey == otherKey && $0.transferKey == peer.transferKey
                            && $0.bookingDate == peer.bookingDate && peer.signedAmountMinor != Int64.min
                            && $0.signedAmountMinor == -peer.signedAmountMinor && $0.currency == peer.currency
                    }
                    if reverse.count == 1 { return true }
                }
                deferred[feed.connection.bank, default: 0] += 1
                return false
            }
            return BankingAccountFeed(connection: feed.connection, account: feed.account, balances: feed.balances, movements: rows)
        }
        return Self(feeds: selected, deferredByBank: deferred)
    }
}

enum PersonalBankingError: LocalizedError {
    case invalidData, accountNotLinked, needsReview, changed, incompleteTransfer, wrongWorkspace, transferAlreadyRecorded
    case unavailableBookedBalance(String), invalidMovement(String), missingMovementReference(String)
    var errorDescription: String? {
        switch self {
        case .invalidData: "Los datos bancarios no son compatibles o están incompletos. No se ha guardado la importación."
        case .unavailableBookedBalance(let bank): "\(bank) no ha enviado un saldo contable en euros que se pueda verificar."
        case .invalidMovement(let bank): "\(bank) ha enviado un movimiento con fecha, importe, moneda o concepto no válido."
        case .missingMovementReference(let bank): "\(bank) ha enviado un movimiento sin una referencia que permita identificarlo."
        case .accountNotLinked: "Asocia primero las cuentas bancarias con las cuentas de la app."
        case .needsReview: "Revisa las posibles coincidencias antes de incorporar los movimientos."
        case .changed: "Tus datos han cambiado. Actualiza la consulta antes de confirmar."
        case .incompleteTransfer: "Falta la otra parte de una transferencia propia. Conecta y actualiza ambas cuentas antes de importar."
        case .wrongWorkspace: "Las cuentas reales solo se incorporan a tu espacio personal cloud, nunca al sandbox."
        case .transferAlreadyRecorded: "Ya hay una transferencia con esas cuentas, importe y fecha. Comprueba ese movimiento antes de unir los apuntes."
        }
    }
}

struct BankingLedgerEntry: Equatable {
    let id: UUID
    let date: Date
    let kind: String
    let amount: Int64
    let source: UUID?
    let destination: UUID?
    let text: String
    let externalID: String?
}

struct PersonalBankingPlan {
    enum Choice: Equatable { case new, match(UUID) }
    struct Item: Identifiable {
        let id: String
        let date: Date
        let kind: String
        let amount: Int64
        let source: UUID
        let destination: UUID?
        let text: String
        var hasLocalReference = false
        var candidates: [UUID] = []
        var transferCandidates: Set<UUID> = []
        var automaticMatch: UUID?
        var suggestedMatch: UUID?
        var suggestionReason: String?
    }
    struct Balance { let account: UUID; let amount: Int64 }
    let items: [Item]
    let balances: [Balance]
    let alreadyImported: Int
    var requiresReferenceReview: Bool { items.contains(where: \.hasLocalReference) }

    static func build(feeds: [BankingAccountFeed], links: [String: UUID], ledger: [BankingLedgerEntry], namespace: String = "test") throws -> Self {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withFullDate]
        struct Leg { let key: String; let row: BankingPreview.Movement; let local: UUID; let own: String?; let date: Date; let hasLocalReference: Bool }
        var legs: [Leg] = []; var seen = Set<String>(); var balances: [Balance] = []
        var localAccounts = Set<UUID>(); var ownership: [String: UUID] = [:]
        var accountPrefixes: [UUID: String] = [:]
        for feed in feeds {
            guard let local = links[feed.account.id], localAccounts.insert(local).inserted else { throw PersonalBankingError.accountNotLinked }
            guard feed.account.currency == "EUR", !feed.account.id.isEmpty else { throw PersonalBankingError.invalidData }
            let accountPrefix = "enable-entry:\(namespace):\(feed.account.id):"
            accountPrefixes[local] = accountPrefix
            let intraday = feed.balances.filter { $0.type == "ITBD" && $0.currency == "EUR" }
            let booked = intraday.isEmpty ? feed.balances.filter { $0.type == "CLBD" && $0.currency == "EUR" } : intraday
            guard booked.count == 1, absSafe(booked[0].amountMinor, limit: 1_000_000_000_000_000) else {
                throw PersonalBankingError.unavailableBookedBalance(feed.connection.bank)
            }
            balances.append(Balance(account: local, amount: booked[0].amountMinor))
            if let own = feed.account.ownershipKey {
                guard ownership.updateValue(local, forKey: own) == nil else { throw PersonalBankingError.invalidData }
            }
            var pageRows: [String: BankingPreview.Movement] = [:]
            var occurrences: [String: Int] = [:]
            for row in feed.movements {
                guard row.currency == "EUR",
                      row.signedAmountMinor != 0, absSafe(row.signedAmountMinor, limit: 1_000_000_000_000),
                      let date = formatter.date(from: row.bookingDate), formatter.string(from: date) == row.bookingDate,
                      date <= Date.now, row.description.count <= 4096,
                      !row.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw PersonalBankingError.invalidMovement(feed.connection.bank)
                }
                let id: String
                let hasLocalReference: Bool
                if let reference = row.id, !reference.isEmpty {
                    guard reference.count <= 512 else { throw PersonalBankingError.invalidData }
                    id = reference
                    hasLocalReference = false
                } else {
                    guard feed.connection.bank == "Trade Republic", row.counterpartyKey == nil, row.transferKey == nil else {
                        throw PersonalBankingError.missingMovementReference(feed.connection.bank)
                    }
                    // Count identical postings across the complete feed, independently of page order.
                    let group = "\(row.bookingDate):\(row.currency):\(row.signedAmountMinor)"
                    let occurrence = occurrences[group, default: 0] + 1
                    occurrences[group] = occurrence
                    id = "local-occurrence:\(group):\(occurrence)"
                    hasLocalReference = true
                }
                let key = accountPrefix + id
                if let old = pageRows[key] {
                    guard old.bookingDate == row.bookingDate, old.signedAmountMinor == row.signedAmountMinor,
                          old.description == row.description, old.counterpartyKey == row.counterpartyKey,
                          old.transferKey == row.transferKey else { throw PersonalBankingError.invalidData }
                    continue
                }
                guard seen.insert(key).inserted else { throw PersonalBankingError.invalidData }
                pageRows[key] = row
                legs.append(Leg(key: key, row: row, local: local, own: feed.account.ownershipKey, date: date, hasLocalReference: hasLocalReference))
            }
        }
        var knownRows: [String: BankingLedgerEntry] = [:]
        for entry in ledger {
            for key in try keys(entry.externalID) {
                guard knownRows.updateValue(entry, forKey: key) == nil else { throw PersonalBankingError.invalidData }
            }
        }
        let known = Set(knownRows.keys)
        func validateKnown(_ key: String, source: UUID, destination: UUID?, amount: Int64, kind: String) throws {
            guard let old = knownRows[key] else { return }
            let probe = Item(id: key, date: old.date, kind: kind, amount: amount, source: source, destination: destination, text: "")
            guard compatible(old, with: probe) else {
                throw PersonalBankingError.changed
            }
        }
        var used = Set<String>(); var items: [Item] = []; var skipped = 0
        for leg in legs.sorted(by: { $0.key < $1.key }) where !used.contains(leg.key) {
            let ownOther = leg.row.counterpartyKey.flatMap { ownership[$0] }
            if let other = ownOther, other != leg.local {
                let matches = legs.filter {
                    $0.local == other && $0.row.counterpartyKey == leg.own
                        && $0.row.transferKey != nil && $0.row.transferKey == leg.row.transferKey
                        && $0.row.bookingDate == leg.row.bookingDate && $0.row.signedAmountMinor == -leg.row.signedAmountMinor
                }
                guard matches.count == 1, let paired = matches.first, !used.contains(paired.key) else { throw PersonalBankingError.incompleteTransfer }
                used.insert(leg.key); used.insert(paired.key)
                let debit = leg.row.signedAmountMinor < 0 ? leg : paired
                let credit = leg.row.signedAmountMinor > 0 ? leg : paired
                let atomicKeys = [debit.key, credit.key]
                let key = try encodedKeys(atomicKeys)
                var item = Item(id: key, date: debit.date, kind: "transfer", amount: -debit.row.signedAmountMinor,
                    source: debit.local, destination: credit.local, text: debit.row.description)
                let prior = atomicKeys.compactMap { knownRows[$0] }
                if let old = prior.first {
                    guard prior.allSatisfy({ $0.id == old.id }), compatible(old, with: item), old.kind == "transfer" else {
                        throw PersonalBankingError.incompleteTransfer
                    }
                    if Set(try keys(old.externalID)).isSuperset(of: atomicKeys) { skipped += 1; continue }
                    item.candidates = [old.id]; item.transferCandidates = [old.id]; item.automaticMatch = old.id
                }
                items.append(item)
            } else {
                used.insert(leg.key)
                if known.contains(leg.key) {
                    try validateKnown(leg.key, source: leg.local, destination: nil, amount: abs(leg.row.signedAmountMinor), kind: leg.row.signedAmountMinor < 0 ? "expense" : "income")
                    skipped += 1; continue
                }
                items.append(Item(id: leg.key, date: leg.date, kind: leg.row.signedAmountMinor < 0 ? "expense" : "income",
                    amount: abs(leg.row.signedAmountMinor), source: leg.local, destination: nil, text: leg.row.description,
                    hasLocalReference: leg.hasLocalReference))
            }
        }
        struct CandidateKey: Hashable { let source: UUID?; let destination: UUID?; let kind: String; let amount: Int64 }
        func family(_ kind: String) -> String { kind == "fee" ? "expense" : (kind == "interest" ? "income" : kind) }
        let candidateIndex = Dictionary(grouping: ledger.filter { $0.externalID == nil }) {
            CandidateKey(source: $0.source, destination: $0.destination, kind: family($0.kind), amount: $0.amount)
        }
        for i in items.indices {
            let item = items[i]
            if item.automaticMatch != nil { continue }
            let key = CandidateKey(source: item.source, destination: item.destination, kind: item.kind, amount: item.amount)
            var candidates = (candidateIndex[key] ?? []).filter { abs($0.date.timeIntervalSince(item.date)) <= 3 * 86400 }
            // A single bank debit may be the visible leg of an existing investment transfer.
            // Matching it preserves the original transfer instead of creating an expense.
            let transfers = try ledger.filter { transfer in
                guard transfer.kind == "transfer", compatible(transfer, with: item),
                      abs(transfer.date.timeIntervalSince(item.date)) <= 3 * 86400 else { return false }
                guard item.hasLocalReference, let prefix = accountPrefixes[item.source] else { return true }
                let references = try keys(transfer.externalID)
                return references.count < 2 && !references.contains { $0.hasPrefix(prefix) }
            }
            candidates.append(contentsOf: transfers.filter { transfer in !candidates.contains { $0.id == transfer.id } })
            // Keep the best textual match first, with stable ordering for equal scores.
            candidates.sort {
                let left = Self.conceptScore($0.text, item.text), right = Self.conceptScore($1.text, item.text)
                if left != right { return left > right }
                let ld = abs($0.date.timeIntervalSince(item.date)), rd = abs($1.date.timeIntervalSince(item.date))
                return ld == rd ? $0.id.uuidString < $1.id.uuidString : ld < rd
            }
            items[i].candidates = candidates.map(\.id)
            items[i].transferCandidates = Set(transfers.map(\.id))
            let exact = candidates.filter { formatter.string(from: $0.date) == formatter.string(from: item.date)
                && !normalized(item.text).isEmpty && normalized($0.text) == normalized(item.text) }
            // Ambiguous repeated purchases and two bank rows competing for one local row require review.
            if !item.hasLocalReference, candidates.count == 1, exact.count == 1 { items[i].automaticMatch = exact[0].id }
            if items[i].automaticMatch == nil, let best = candidates.first {
                let score = Self.conceptScore(best.text, item.text)
                let distinctConcept = score > 0 && (candidates.count == 1 || score > Self.conceptScore(candidates[1].text, item.text))
                let sameDay = formatter.string(from: best.date) == formatter.string(from: item.date)
                if distinctConcept || (candidates.count == 1 && sameDay) {
                    items[i].suggestedMatch = best.id
                    items[i].suggestionReason = distinctConcept
                        ? "Misma cuenta e importe, fecha cercana y concepto relacionado."
                        : "Único registro de la misma cuenta, importe y día. El concepto es distinto: compruébalo."
                }
            }
        }
        let proposedItems = items
        for i in items.indices {
            if let proposed = items[i].automaticMatch {
                let competing = proposedItems.filter { $0.automaticMatch == proposed }
                if competing.count > 1 && !canShareTransfer(competing, id: proposed) { items[i].automaticMatch = nil }
            }
        }
        // Never propose two purchases against one local record, or consume a record
        // already recognized automatically. Complementary legs of a transfer can share it.
        let suggestions = items
        for i in items.indices {
            if let proposed = items[i].suggestedMatch {
                let competing = suggestions.filter { ($0.automaticMatch ?? $0.suggestedMatch) == proposed }
                if competing.count > 1 && !canShareTransfer(competing, id: proposed) {
                    items[i].suggestedMatch = nil; items[i].suggestionReason = nil
                }
            }
        }
        return Self(items: items.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }, balances: balances, alreadyImported: skipped)
    }

    func resolutions(_ choices: [String: Choice]) throws -> [String: Choice] {
        var result: [String: Choice] = [:]; var assigned: [UUID: [Item]] = [:]
        for item in items {
            let choice = choices[item.id] ?? item.automaticMatch.map { Choice.match($0) } ?? (item.candidates.isEmpty ? .new : nil)
            guard let choice else { throw PersonalBankingError.needsReview }
            if case .match(let id) = choice {
                guard item.candidates.contains(id) else { throw PersonalBankingError.needsReview }
                let previous = assigned[id] ?? []
                if !previous.isEmpty && !Self.canShareTransfer(previous + [item], id: id) { throw PersonalBankingError.needsReview }
                assigned[id, default: []].append(item)
            }
            result[item.id] = choice
        }
        return result
    }
    func unresolvedItems(_ choices: [String: Choice]) -> [Item] {
        items.filter { !$0.candidates.isEmpty && $0.automaticMatch == nil && choices[$0.id] == nil }
    }
    func canMatch(_ item: Item, to id: UUID, choices: [String: Choice]) -> Bool {
        guard item.candidates.contains(id) else { return false }
        let assigned = items.filter { other in
            other.id != item.id && (choices[other.id] ?? other.automaticMatch.map { Choice.match($0) }) == .match(id)
        }
        return assigned.isEmpty || Self.canShareTransfer(assigned + [item], id: id)
    }
    /// Only prepares explicit choices; it neither writes data nor bypasses final review.
    func acceptingSuggestions(_ choices: [String: Choice]) -> [String: Choice] {
        var result = choices
        for item in unresolvedItems(choices) {
            if let id = item.suggestedMatch, canMatch(item, to: id, choices: result) { result[item.id] = .match(id) }
        }
        return result
    }
    static func keys(_ value: String?) throws -> [String] {
        guard let value else { return [] }
        if value.hasPrefix("enable-entry:") { return [value] }
        guard value.hasPrefix("enable-keys:"),
              let data = String(value.dropFirst("enable-keys:".count)).data(using: .utf8),
              let keys = try? JSONDecoder().decode([String].self, from: data), (1...2).contains(keys.count),
              Set(keys).count == keys.count, keys.allSatisfy({ $0.hasPrefix("enable-entry:") }) else { throw PersonalBankingError.invalidData }
        return keys
    }
    static func encodedKeys(_ keys: [String]) throws -> String {
        let unique = Array(Set(keys)).sorted()
        guard (1...2).contains(unique.count) else { throw PersonalBankingError.invalidData }
        if unique.count == 1 { return unique[0] }
        return "enable-keys:" + String(decoding: try JSONEncoder().encode(unique), as: UTF8.self)
    }
    private static func compatible(_ entry: BankingLedgerEntry, with item: Item) -> Bool {
        guard entry.amount == item.amount else { return false }
        if item.kind == "transfer" { return entry.kind == "transfer" && entry.source == item.source && entry.destination == item.destination }
        if entry.kind == "transfer" { return item.kind == "expense" ? entry.source == item.source : entry.destination == item.source }
        let family = entry.kind == "fee" ? "expense" : (entry.kind == "interest" ? "income" : entry.kind)
        return family == item.kind && entry.source == item.source && entry.destination == item.destination
    }
    private static func canShareTransfer(_ items: [Item], id: UUID) -> Bool {
        items.count == 2 && items.allSatisfy { $0.transferCandidates.contains(id) }
            && Set(items.map(\.kind)) == Set(["expense", "income"]) && items[0].source != items[1].source
    }
    private static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es_ES"))
        // Strip only the known technical prefix, not meaningful purchase or transfer text.
        let cleaned = folded.replacingOccurrences(of: #"^(?:\s*/txt/[a-z]\|)+"#, with: "", options: .regularExpression)
        return cleaned.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }
    private static func conceptScore(_ lhs: String, _ rhs: String) -> Int {
        let left = normalized(lhs), right = normalized(rhs)
        if !left.isEmpty && left == right { return 3 }
        let ignored: Set<String> = ["pago", "compra", "tarjeta", "transferencia", "transfer", "recibo", "cargo", "abono", "bizum", "paypal", "para", "desde", "cuenta"]
        func tokens(_ value: String) -> Set<String> {
            Set(value.split(separator: " ").map(String.init).filter {
                $0.count >= 3 && $0.contains(where: \.isLetter) && !ignored.contains($0)
            })
        }
        let a = tokens(left), b = tokens(right), common = a.intersection(b)
        if common.count >= 2 { return 2 }
        if common.contains(where: { $0.count >= 5 }) { return 1 }
        return 0
    }
    private static func absSafe(_ amount: Int64, limit: Int64) -> Bool { amount >= -limit && amount <= limit }
}
