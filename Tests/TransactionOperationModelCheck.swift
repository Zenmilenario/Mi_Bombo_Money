import Foundation

@main
struct TransactionOperationModelCheck {
    static func main() throws {
        typealias Input = TransactionOperationModel.Input
        typealias Example = TransactionOperationModel.Example
        func input(_ text: String = "Movimiento bancario", amount: Int64 = 347, day: Int = 2,
                   month: String = "2026-04", account: String = "account-a") -> Input {
            Input(text: text, amountMinor: amount, isCredit: false, day: day, weekday: 2, month: month, accountKey: account)
        }
        let initial = TransactionOperationModel.train([])!
        let descriptions: [(String, TransactionOperationKind)] = [
            ("Round up inversión tarjeta completada", .roundUp),
            ("Saveback recompensa tarjeta completada", .saveback),
            ("Plan de inversión ejecutado compra ETF", .investment)
        ]
        for (text, expected) in descriptions {
            precondition(initial.predict(input(text))?.kind == expected, "Unseen descriptive benefit text: \(text)")
        }
        precondition(initial.predict(input()) == nil, "A small amount and a monthly execution day are not a label")
        precondition(initial.predict(input("771932")) == nil)
        precondition(initial.predict(input("Supermercado compra tarjeta")) == nil)
        precondition(initial.predict(input(amount: 0)) == nil)
        precondition(initial.predict(input(amount: Int64.max)) == nil)

        // Invented histories spanning several periods: amount distinguishes these examples,
        // while deliberately overlapping the day of ordinary debits and investments.
        var examples: [Example] = []
        for month in 1...3 {
            for day in [2, 9, 16, 23] {
                examples.append(.init(input: input(amount: Int64(100 + day), day: day, month: "2026-\(month)"), kind: .roundUp, confirmed: true))
                examples.append(.init(input: input(amount: Int64(25_000 + day), day: day, month: "2026-\(month)"), kind: .ordinary, confirmed: true))
            }
        }
        let contextual = TransactionOperationModel.train(examples)!
        let suggestion = contextual.predict(input(amount: 130, day: 9))
        precondition(suggestion?.kind == .roundUp && suggestion?.usesContext == true,
                     "Confirmed context should enable an unseen anonymous proposal")
        precondition(contextual.predict(input(amount: 130, day: 9, account: "another-account")) == nil,
                     "An account without its own labels must abstain")
        let unconfirmed = examples.map { Example(input: $0.input, kind: $0.kind, confirmed: false) }
        precondition(TransactionOperationModel.train(unconfirmed)!.predict(input(amount: 130, day: 9)) == nil,
                     "Predictions must not become training labels")
        let onePeriod = examples.map { row in
            Example(input: input(amount: row.input.amountMinor, day: row.input.day, month: "2026-01"), kind: row.kind, confirmed: true)
        }
        precondition(TransactionOperationModel.train(onePeriod)!.predict(input(amount: 130, day: 9)) == nil)
        let duplicated = Array(repeating: examples[0], count: 30) + Array(repeating: examples[1], count: 30)
        precondition(TransactionOperationModel.train(duplicated)!.predict(input(amount: 130, day: 9)) == nil,
                     "Repeating a confirmation must not manufacture independent evidence")
        let corrected = examples.map { row in
            Example(input: row.input, kind: row.kind == .roundUp ? .saveback : row.kind, confirmed: true)
        }
        precondition(TransactionOperationModel.train(corrected)!.predict(input(amount: 130, day: 9))?.kind == .saveback,
                     "Replacing labels must change learned context, not follow a hardcoded date/amount rule")
        let restored = try JSONDecoder().decode(Input.self, from: JSONEncoder().encode(input()))
        precondition(restored == input())
        let terms = TransactionOperationModel.CardTerms(savebackPercent: 1, roundUpMultiplier: 1, validFrom: .now)
        precondition(terms.valid)
        precondition(!TransactionOperationModel.CardTerms(savebackPercent: .nan, roundUpMultiplier: 1, validFrom: .now).valid)
        precondition(!TransactionOperationModel.CardTerms(savebackPercent: 1, roundUpMultiplier: 4, validFrom: .now).valid)
        print("Operation recognition passed: unseen text, contextual learning, correction, account isolation, missing evidence, and Codable input.")
    }
}
