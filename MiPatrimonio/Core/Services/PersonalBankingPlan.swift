import Foundation

enum PersonalBankingError: LocalizedError {
    case invalidData, accountNotLinked, needsReview, changed, incompleteTransfer, wrongWorkspace
    var errorDescription: String? {
        switch self {
        case .invalidData: "Los datos bancarios no son compatibles o están incompletos. No se ha guardado la importación."
        case .accountNotLinked: "Asocia primero las cuentas bancarias con las cuentas de la app."
        case .needsReview: "Revisa las posibles coincidencias antes de incorporar los movimientos."
        case .changed: "Tus datos han cambiado. Actualiza la consulta antes de confirmar."
        case .incompleteTransfer: "Falta la otra parte de una transferencia propia. Conecta y actualiza ambas cuentas antes de importar."
        case .wrongWorkspace: "Las cuentas reales solo se incorporan a tu espacio personal cloud, nunca al sandbox."
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
        var candidates: [UUID] = []
        var transferCandidates: Set<UUID> = []
        var automaticMatch: UUID?
    }
    struct Balance { let account: UUID; let amount: Int64 }
    let items: [Item]
    let balances: [Balance]
    let alreadyImported: Int

    static func build(feeds: [BankingAccountFeed], links: [String: UUID], ledger: [BankingLedgerEntry], namespace: String = "test") throws -> Self {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withFullDate]
        struct Leg { let key: String; let row: BankingPreview.Movement; let local: UUID; let own: String?; let date: Date }
        var legs: [Leg] = []; var seen = Set<String>(); var balances: [Balance] = []
        var localAccounts = Set<UUID>(); var ownership: [String: UUID] = [:]
        for feed in feeds {
            guard let local = links[feed.account.id], localAccounts.insert(local).inserted else { throw PersonalBankingError.accountNotLinked }
            guard feed.account.currency == "EUR", !feed.account.id.isEmpty else { throw PersonalBankingError.invalidData }
            let intraday = feed.balances.filter { $0.type == "ITBD" && $0.currency == "EUR" }
            let booked = intraday.isEmpty ? feed.balances.filter { $0.type == "CLBD" && $0.currency == "EUR" } : intraday
            guard booked.count == 1, absSafe(booked[0].amountMinor, limit: 1_000_000_000_000_000) else { throw PersonalBankingError.invalidData }
            balances.append(Balance(account: local, amount: booked[0].amountMinor))
            if let own = feed.account.ownershipKey {
                guard ownership.updateValue(local, forKey: own) == nil else { throw PersonalBankingError.invalidData }
            }
            var pageRows: [String: BankingPreview.Movement] = [:]
            for row in feed.movements {
                guard let id = row.id, !id.isEmpty, id.count <= 512, row.currency == "EUR",
                      row.signedAmountMinor != 0, absSafe(row.signedAmountMinor, limit: 1_000_000_000_000),
                      let date = formatter.date(from: row.bookingDate), formatter.string(from: date) == row.bookingDate,
                      !row.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PersonalBankingError.invalidData }
                guard date <= Date.now, row.description.count <= 4096 else { throw PersonalBankingError.invalidData }
                let key = "enable-entry:\(namespace):\(feed.account.id):\(id)"
                if let old = pageRows[key] {
                    guard old.bookingDate == row.bookingDate, old.signedAmountMinor == row.signedAmountMinor,
                          old.description == row.description, old.counterpartyKey == row.counterpartyKey,
                          old.transferKey == row.transferKey else { throw PersonalBankingError.invalidData }
                    continue
                }
                guard seen.insert(key).inserted else { throw PersonalBankingError.invalidData }
                pageRows[key] = row
                legs.append(Leg(key: key, row: row, local: local, own: feed.account.ownershipKey, date: date))
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
                    amount: abs(leg.row.signedAmountMinor), source: leg.local, destination: nil, text: leg.row.description))
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
            let transfers = ledger.filter { $0.kind == "transfer" && compatible($0, with: item)
                && abs($0.date.timeIntervalSince(item.date)) <= 3 * 86400 }
            candidates.append(contentsOf: transfers.filter { transfer in !candidates.contains { $0.id == transfer.id } })
            items[i].candidates = candidates.map(\.id)
            items[i].transferCandidates = Set(transfers.map(\.id))
            let exact = candidates.filter { formatter.string(from: $0.date) == formatter.string(from: item.date) && normalized($0.text) == normalized(item.text) }
            // Ambiguous repeated purchases and two bank rows competing for one local row require review.
            if candidates.count == 1, exact.count == 1 { items[i].automaticMatch = exact[0].id }
        }
        let proposedItems = items
        for i in items.indices {
            if let proposed = items[i].automaticMatch {
                let competing = proposedItems.filter { $0.automaticMatch == proposed }
                if competing.count > 1 && !canShareTransfer(competing, id: proposed) { items[i].automaticMatch = nil }
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
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es_ES"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    private static func absSafe(_ amount: Int64, limit: Int64) -> Bool { amount >= -limit && amount <= limit }
}
