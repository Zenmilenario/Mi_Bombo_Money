import Foundation

/// The shared learning (CloudBackend/learning-contract.md) with the same fictitious cases the Android app checks
/// (Tests/Fixtures/shared_learning_cases.json): signatures, combination and dating of the iPhone's changes.
@main
struct LearningShareCheck {
    static func main() throws {
        guard let data = FileManager.default.contents(atPath: "Tests/Fixtures/shared_learning_cases.json"),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            fatalError("Missing Tests/Fixtures/shared_learning_cases.json")
        }
        func document(_ value: Any?) throws -> SharedLearning {
            try JSONDecoder().decode(SharedLearning.self, from: JSONSerialization.data(withJSONObject: value ?? [:]))
        }
        /// An export has no dates yet: they are added as 0 before decoding.
        func undated(_ value: Any?) -> Any {
            guard var object = value as? [String: Any] else { return value ?? [:] }
            for section in ["categories", "operations", "terms", "corrections", "automatic"] {
                guard var entries = object[section] as? [String: Any] else { continue }
                for (key, entry) in entries {
                    if var fields = entry as? [String: Any], fields["at"] == nil { fields["at"] = 0; entries[key] = fields }
                }
                object[section] = entries
            }
            if var automation = object["automation"] as? [String: Any], automation["at"] == nil {
                automation["at"] = 0; object["automation"] = automation
            }
            return object
        }

        for case let item as [String: Any] in root["signatures"] as? [Any] ?? [] {
            let tx = item["transaction"] as! [String: Any]
            let expected = item["expected"] as! [String: Any]
            let date = Date(timeIntervalSinceReferenceDate: (tx["date"] as! NSNumber).doubleValue)
            let source = UUID(uuidString: tx["sourceAccountID"] as! String)!
            let id = UUID(uuidString: tx["id"] as! String)!
            precondition(LearningCanonical.ms(date) == (expected["dateMs"] as! NSNumber).int64Value, "Same date in milliseconds")
            precondition(LearningCanonical.id(id) == tx["id"] as! String, "Identifiers in lower case")
            precondition(LearningCanonical.accountKey(accountID: source, currency: tx["sourceCurrency"] as! String) == expected["accountKey"] as! String)
            if let category = tx["categoryID"] as? String {
                precondition(LearningCanonical.categorySignature(type: tx["typeRaw"] as! String, categoryID: UUID(uuidString: category)!,
                    description: tx["descriptionText"] as! String) == expected["categorySignature"] as! String, "Same category signature")
            }
            let identity = LearningCanonical.identity(id: id, type: tx["typeRaw"] as! String,
                amountMinor: (tx["amountMinor"] as! NSNumber).int64Value, date: date, description: tx["descriptionText"] as! String,
                sourceID: source, destinationID: (tx["destinationAccountID"] as? String).flatMap(UUID.init(uuidString:)),
                sourceCurrency: tx["sourceCurrency"] as? String, destinationCurrency: tx["destinationCurrency"] as? String,
                bankEntryKey: tx["bankEntryKey"] as? String)
            precondition(identity == expected["identity"] as! String, "Same identity as Android")
        }

        for case let item as [String: Any] in root["merges"] as? [Any] ?? [] {
            let merged = LearningShare.merge(try document(item["local"]), try document(item["remote"]))
            let expected = try document(item["expected"])
            precondition(merged == expected, "Combination: \(item["name"] ?? "")")
            let encoded = try JSONDecoder().decode(SharedLearning.self, from: JSONEncoder().encode(merged))
            precondition(encoded == merged, "The document survives being written and read")
        }

        for case let item as [String: Any] in root["stamps"] as? [Any] ?? [] {
            let representable = Set(item["representable"] as? [String] ?? [])
            let stamped = LearningShare.stamp(try document(undated(item["exported"])), base: try document(item["base"]),
                now: (item["now"] as! NSNumber).int64Value) { section, key in representable.contains(section + ":" + key) }
            let expected = try document(item["expected"])
            precondition(stamped == expected, "Dating: \(item["name"] ?? "")")
        }
        for case let item as [String: Any] in root["metricsSummaries"] as? [Any] ?? [] {
            let entries = try JSONDecoder().decode([String: SharedLearning.MetricsEntry].self,
                from: JSONSerialization.data(withJSONObject: item["metrics"] ?? [:]))
            precondition(SharedLearning.MetricsSummary(entries.values).csv == item["csv"] as! String,
                "Metrics: \(item["name"] ?? "")")
        }
        print("Lo aprendido compartido coincide con Android")
    }
}
