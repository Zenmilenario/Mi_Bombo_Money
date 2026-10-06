import Foundation

// Acknowledging an alert changes its presentation, not the financial data.
// The revision ties acknowledgement to the actual issue, so new data resurfaces it.
struct DashboardAlertReviewState: Codable {
    private var revisions: [String: String] = [:]

    init(serialized: String = "") {
        if let data = serialized.data(using: .utf8),
           let saved = try? JSONDecoder().decode(Self.self, from: data) {
            self = saved
        }
    }

    func isReviewed(id: String, revision: String) -> Bool {
        revisions[id] == revision
    }

    mutating func markReviewed(id: String, revision: String) {
        revisions[id] = revision
    }

    var serialized: String {
        guard let data = try? JSONEncoder().encode(self),
              let value = String(data: data, encoding: .utf8) else { return "" }
        return value
    }
}
