import Foundation

/// JSON values preserve integer cents without routing them through Double.
enum CloudJSON: Codable, Equatable, Sendable {
    case object([String: CloudJSON]), array([CloudJSON]), string(String), integer(Int64), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int64.self) { self = .integer(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([CloudJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: CloudJSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    var object: [String: CloudJSON] { if case .object(let v) = self { return v }; return [:] }
    var array: [CloudJSON] { if case .array(let v) = self { return v }; return [] }
    var string: String? { if case .string(let v) = self { return v }; return nil }
    var double: Double? {
        switch self { case .integer(let v): Double(v); case .number(let v): v; default: nil }
    }
}

struct CloudSnapshot: Codable, Sendable {
    let workspaceID: UUID
    let revision: Int64
    let document: CloudJSON
    enum CodingKeys: String, CodingKey { case workspaceID = "workspace_id", revision, document }
}

struct CloudMergeConflict: Error, LocalizedError {
    let records: [String]
    var errorDescription: String? {
        "Hay cambios distintos en \(records.count) registros de este dispositivo y de la nube. Tus cambios se conservan aquí. Revisa el conflicto antes de sincronizar."
    }
}

enum CloudDocument {
    static let entities = ["institutions", "accounts", "categories", "cards", "reservedFunds", "categoryRules", "recurringBudgets", "budgets", "goals", "recurringMovements", "importBatches", "snapshots", "transactions"]
    static func normalized(_ document: CloudJSON) -> CloudJSON {
        var result: [String: CloudJSON] = ["formatVersion": .integer(2)]
        for key in entities { result[key] = .array(document.object[key]?.array ?? []) }
        result["exportedAt"] = document.object["exportedAt"] ?? .number(Date.now.timeIntervalSinceReferenceDate)
        return .object(result)
    }
    static func indexed(_ document: CloudJSON, entity: String) throws -> [String: CloudJSON] {
        var records: [String: CloudJSON] = [:]
        for record in document.object[entity]?.array ?? [] {
            guard let raw = record.object["id"]?.string, let id = UUID(uuidString: raw)?.uuidString.lowercased(), records[id] == nil else {
                throw CloudTransportError.invalidData
            }
            records[id] = record
        }
        return records
    }
    static func canonical(_ record: CloudJSON?) -> CloudJSON? {
        guard let record else { return nil }
        var result = record.object.filter { !["createdAt", "updatedAt"].contains($0.key) && $0.value != .null }
        for (key, value) in result {
            if let text = value.string, let id = UUID(uuidString: text) {
                result[key] = .string(id.uuidString.lowercased())
            } else if ["monthStart", "startMonth", "endMonth"].contains(key), let number = value.double {
                var calendar = Calendar(identifier: .gregorian)
                // Month dates exported by the server are noon UTC to preserve the month worldwide.
                // Locally created months follow the device's calendar.
                calendar.timeZone = .autoupdatingCurrent
                let parts = calendar.dateComponents([.year, .month], from: Date(timeIntervalSinceReferenceDate: number))
                result[key] = .string("\(parts.year ?? 0)-\(parts.month ?? 0)")
            } else if ["date", "openingDate", "nextDueDate", "endDate", "targetDate", "importedAt", "lastUpdatedAt"].contains(key), let number = value.double {
                result[key] = .integer(Int64((number * 1000).rounded()))
            } else if let number = value.double, number.isFinite, number.rounded() == number,
                      number >= Double(Int64.min) + 2048, number < Double(Int64.max) - 2048,
                      case .number = value {
                result[key] = .integer(Int64(number))
            }
        }
        return .object(result)
    }
    static func same(_ a: CloudJSON, _ b: CloudJSON) throws -> Bool {
        for entity in entities {
            let left = try indexed(a, entity: entity).mapValues(canonical)
            let right = try indexed(b, entity: entity).mapValues(canonical)
            if left != right { return false }
        }
        return true
    }
    static func merge(base: CloudJSON, local: CloudJSON, remote: CloudJSON) throws -> CloudJSON {
        var merged = normalized(remote).object
        var conflicts: [String] = []
        for entity in entities {
            let original = try indexed(base, entity: entity)
            let device = try indexed(local, entity: entity)
            let server = try indexed(remote, entity: entity)
            var output: [CloudJSON] = []
            for id in Set(original.keys).union(device.keys).union(server.keys).sorted() {
                let b = canonical(original[id]), l = canonical(device[id]), r = canonical(server[id])
                let chosen: CloudJSON?
                if l == b { chosen = server[id] }
                else if r == b || l == r { chosen = device[id] }
                else { conflicts.append("\(entity):\(id)"); chosen = nil }
                if let chosen { output.append(chosen) }
            }
            merged[entity] = .array(output)
        }
        guard conflicts.isEmpty else { throw CloudMergeConflict(records: conflicts) }
        let graphIssues = try integrityConflicts(.object(merged))
        guard graphIssues.isEmpty else { throw CloudMergeConflict(records: graphIssues) }
        return .object(merged)
    }
    /// Resolves only conflicting records. Independent edits on either side remain intact.
    static func resolving(base: CloudJSON, local: CloudJSON, remote: CloudJSON, preferLocal: Bool) throws -> CloudJSON {
        var adjusted = base.object
        let opposite = preferLocal ? remote : local
        for _ in 0..<32 {
            do { return try merge(base: .object(adjusted), local: local, remote: remote) }
            catch let conflict as CloudMergeConflict {
                var changed = false
                for key in conflict.records {
                    let pieces = key.split(separator: ":", maxSplits: 1).map(String.init)
                    guard pieces.count == 2, entities.contains(pieces[0]) else { continue }
                    var values = try indexed(.object(adjusted), entity: pieces[0])
                    let replacement = try indexed(opposite, entity: pieces[0])[pieces[1]]
                    if canonical(values[pieces[1]]) != canonical(replacement) { changed = true }
                    values[pieces[1]] = replacement
                    adjusted[pieces[0]] = .array(values.keys.sorted().compactMap { values[$0] })
                }
                if !changed { throw conflict }
            }
        }
        throw CloudTransportError.invalidData
    }

    /// A merge can be valid record by record yet break a relationship or overspend a reserve.
    static func integrityConflicts(_ document: CloudJSON) throws -> [String] {
        let maps = try Dictionary(uniqueKeysWithValues: entities.map { ($0, try indexed(document, entity: $0)) })
        let relations: [String: [String: String]] = [
            "accounts":["institutionID":"institutions"],
            "cards":["institutionID":"institutions","linkedAccountID":"accounts"],
            "reservedFunds":["accountID":"accounts"],
            "categoryRules":["categoryID":"categories"],
            "budgets":["categoryID":"categories"], "recurringBudgets":["categoryID":"categories"],
            "goals":["linkedAccountID":"accounts"],
            "recurringMovements":["sourceAccountID":"accounts","destinationAccountID":"accounts","categoryID":"categories"],
            "snapshots":["accountID":"accounts"],
            // Import/rule UUIDs are historical provenance, even after their source is removed.
            "transactions":["sourceAccountID":"accounts","destinationAccountID":"accounts","categoryID":"categories", "reservedFundID":"reservedFunds"]
        ]
        var problems = Set<String>()
        for (entity, fields) in relations {
            for (id, record) in maps[entity] ?? [:] {
                for (field, target) in fields {
                    if let reference = record.object[field]?.string?.lowercased(), maps[target]?[reference] == nil {
                        problems.insert("\(entity):\(id)"); problems.insert("\(target):\(reference)")
                    }
                }
            }
        }
        var allocations: [String: [(String, Int64)]] = [:]
        var uniqueGroups: [String: [String]] = [:]
        for (id, record) in maps["transactions"] ?? [:] {
            let fields = record.object
            if let fund = fields["reservedFundID"]?.string?.lowercased(), case .integer(let amount) = fields["reservedAmountMinor"] {
                allocations[fund, default: []].append((id,amount))
                let fundAccount = maps["reservedFunds"]?[fund]?.object["accountID"]?.string?.lowercased()
                if fundAccount != fields["sourceAccountID"]?.string?.lowercased() {
                    problems.insert("transactions:\(id)"); problems.insert("reservedFunds:\(fund)")
                }
            }
            if let external = fields["externalID"]?.string, let account = fields["sourceAccountID"]?.string?.lowercased() {
                uniqueGroups["external:\(account):\(external)",default:[]].append("transactions:\(id)")
            }
            if let rule = fields["recurringMovementID"]?.string?.lowercased(), let timestamp = fields["date"]?.double {
                let day = Int64(floor((timestamp + 978307200) / 86400))
                uniqueGroups["recurring:\(rule):\(day)",default:[]].append("transactions:\(id)")
            }
        }
        for (fund, records) in allocations {
            let limit = maps["reservedFunds"]?[fund]?.object["amountMinor"]
            var total: Int64 = 0
            var overflow = false
            for (_, amount) in records {
                let next = total.addingReportingOverflow(amount)
                overflow = overflow || next.overflow
                total = next.partialValue
            }
            if case .integer(let maximum) = limit, overflow || total > maximum {
                problems.insert("reservedFunds:\(fund)")
                for (id, _) in records { problems.insert("transactions:\(id)") }
            }
        }
        for (id, record) in maps["budgets"] ?? [:] {
            let fields = canonical(record)?.object ?? [:]
            if let category = fields["categoryID"]?.string, let month = fields["monthStart"]?.string {
                uniqueGroups["budget:\(category):\(month)",default:[]].append("budgets:\(id)")
            }
        }
        for ids in uniqueGroups.values where ids.count > 1 { problems.formUnion(ids) }
        return problems.sorted()
    }
    static var empty: CloudJSON { normalized(.object([:])) }
    static func financialRecordCount(_ document: CloudJSON) -> Int {
        entities.filter { $0 != "categories" }.reduce(0) { $0 + (document.object[$1]?.array.count ?? 0) }
    }
}
