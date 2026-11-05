import Foundation

@main
struct TransactionCorrectionModelCheck {
    static func main() {
        typealias Model = TransactionCorrectionModel
        let destination = UUID(), category = UUID()
        let transfer = Model.Action(type: "transfer", destinationID: destination, categoryID: category)
        let expense = Model.Action(type: "expense", destinationID: nil, categoryID: UUID())
        func input(month: Int, day: Int, amount: Int64, account: String = "bank-a", text: String = "Movimiento bancario") -> TransactionOperationModel.Input {
            .init(text: text, amountMinor: amount, isCredit: false, day: day, weekday: 2, month: "2019-\(month)", accountKey: account)
        }
        var examples: [Model.Example] = []
        for month in 1...6 {
            for index in 0..<3 {
                examples.append(.init(input: input(month: month, day: 2 + index, amount: Int64(230 + index * 3)), action: transfer))
                examples.append(.init(input: input(month: month, day: 15 + index, amount: Int64(9000 + index * 100)), action: expense))
            }
        }
        let model = Model.train(examples)!
        let unseen = input(month: 7, day: 3, amount: 234)
        let decision = model.automaticDecision(unseen)
        precondition(decision?.action == transfer && decision!.validatedPredictions >= 3)
        precondition(model.automaticDecision(input(month: 7, day: 15, amount: 9100))?.action == expense)
        precondition(model.automaticDecision(input(month: 7, day: 3, amount: 234, account: "bank-b")) == nil)
        precondition(model.automaticDecision(input(month: 7, day: 3, amount: 234, text: "Comercio nuevo desconocido")) == nil)
        precondition(model.automaticDecision(input(month: 1, day: 3, amount: 234)) == nil, "Do not rewrite earlier periods")
        let oneMonth = Array(examples.prefix(6))
        precondition(Model.train(oneMonth) == nil)
        let repeated = Array(repeating: examples[0], count: 30) + Array(repeating: examples[1], count: 30)
        precondition(Model.train(repeated) == nil, "Repeating a sample is not independent evidence")
        let positives = examples.filter { $0.action == transfer }
        precondition(Model.train(positives)?.automaticDecision(unseen) == nil, "Require competing examples")
        var ambiguous = examples
        for month in 1...6 {
            ambiguous.append(.init(input: input(month: month, day: 3, amount: 234), action: expense))
        }
        precondition(Model.train(ambiguous)?.automaticDecision(unseen) == nil, "Conflicting observations must block automation")
        let replacement = Model.Action(type: "transfer", destinationID: UUID(), categoryID: UUID())
        let corrected = examples.map { Model.Example(input: $0.input, action: $0.action == transfer ? replacement : $0.action) }
        precondition(Model.train(corrected)?.automaticDecision(unseen)?.action == replacement,
                     "Learn the corrected category and destination, without hardcoded bank rules")
        print("Correction model passed: temporal holdouts, learned actions, ambiguity, negatives, account isolation and correction.")
    }
}
