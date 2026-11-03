import Foundation

// Value-only ledger shared by calculations and backup validation. A transfer relocates
// reserved money; only an expense consumes it. No additional SwiftData schema is needed.
struct ReservedLedgerEntry {
    let id: UUID
    let date: Date
    let source: UUID
    let destination: UUID?
    let amount: Int64
    var isTransfer: Bool { destination != nil }
}

enum ReservedLedger {
    static func balances(origin: UUID, funding: Int64, entries: [ReservedLedgerEntry],
                         through date: Date = .distantFuture) -> [UUID: Int64]? {
        guard funding >= 0 else { return nil }
        var balances = [origin: funding]
        let groups = Dictionary(grouping: entries.filter { $0.date <= date }, by: \.date)
        for instant in groups.keys.sorted() {
            let group = groups[instant]!
            guard group.allSatisfy({ $0.amount > 0 && $0.destination != $0.source }) else { return nil }
            var pending = group.filter(\.isTransfer).sorted { $0.id.uuidString < $1.id.uuidString }
            // Transfers with identical timestamps may form a chain, but an unfunded
            // circular chain must never create reserved money.
            while !pending.isEmpty {
                guard let index = pending.firstIndex(where: { (balances[$0.source] ?? 0) >= $0.amount }) else { return nil }
                let entry = pending.remove(at: index)
                let sum = (balances[entry.destination!] ?? 0).addingReportingOverflow(entry.amount)
                guard !sum.overflow else { return nil }
                balances[entry.source, default: 0] -= entry.amount
                balances[entry.destination!] = sum.partialValue
            }
            for entry in group where !entry.isTransfer {
                guard (balances[entry.source] ?? 0) >= entry.amount else { return nil }
                balances[entry.source, default: 0] -= entry.amount
            }
        }
        return balances
    }
}

