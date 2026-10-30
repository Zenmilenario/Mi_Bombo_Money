import Foundation

@main
struct PersonalBankingPlanCheck {
    static let daily = UUID(), savings = UUID()
    static let day = ISO8601DateFormatter().date(from: "2026-10-15T00:00:00Z")!
    static func row(_ id: String = "expense", amount: Int64 = -1000, text: String = "Compra", other: String? = nil, reference: String? = nil) -> BankingPreview.Movement {
        .init(id: id, bookingDate: "2026-10-15", signedAmountMinor: amount, currency: "EUR", description: text, counterpartyKey: other, transferKey: reference)
    }
    static func feed(_ id: String = "daily", own: String = "own-daily", rows: [BankingPreview.Movement]? = nil) -> BankingAccountFeed {
        let account = ConnectedBankAccount(id: id, name: "Cuenta ficticia", currency: "EUR", lastFour: "1234", ownershipKey: own)
        return .init(connection: .init(id: UUID().uuidString, bank: "Bankinter", validUntil: "2026-11-01", accounts: [account]),
            account: account, balances: [.init(amountMinor: 9000, currency: "EUR", type: "CLBD")], movements: rows ?? [row()])
    }
    static func entry(id: UUID = UUID(), text: String = "Compra", external: String? = nil) -> BankingLedgerEntry {
        .init(id: id, date: day, kind: "expense", amount: 1000, source: daily, destination: nil, text: text, externalID: external)
    }
    static func main() throws {
        let links = ["daily": daily, "savings": savings]
        let first = try PersonalBankingPlan.build(feeds: [feed()], links: links, ledger: [])
        precondition(first.items.count == 1 && first.balances[0].amount == 9000)
        let firstChoices = try first.resolutions([:])
        precondition(firstChoices[first.items[0].id] == .new)
        let local = entry()
        let exact = try PersonalBankingPlan.build(feeds: [feed(rows: [row(text: "  CÓMPRA  ")])], links: links, ledger: [local])
        precondition(exact.items[0].automaticMatch == local.id)
        let exactChoices = try exact.resolutions([:])
        precondition(exactChoices[exact.items[0].id] == .match(local.id))
        let repeated = try PersonalBankingPlan.build(feeds: [feed()], links: links, ledger: [entry(), entry()])
        expectReview { _ = try repeated.resolutions([:]) }
        let similar = try PersonalBankingPlan.build(feeds: [feed()], links: links, ledger: [entry(text: "Suscripción")])
        expectReview { _ = try similar.resolutions([:]) }
        let separateChoices = try similar.resolutions([similar.items[0].id: .new])
        precondition(separateChoices[similar.items[0].id] == .new)
        let competing = try PersonalBankingPlan.build(feeds: [feed(rows: [row("a"), row("b")])], links: links, ledger: [local])
        precondition(competing.items.allSatisfy { $0.automaticMatch == nil })
        expectReview { _ = try competing.resolutions(Dictionary(uniqueKeysWithValues: competing.items.map { ($0.id, .match(local.id)) })) }
        let imported = entry(external: first.items[0].id)
        let renewed = try PersonalBankingPlan.build(feeds: [feed()], links: links, ledger: [imported])
        precondition(renewed.items.isEmpty && renewed.alreadyImported == 1, "Renewal does not depend on consent ID")
        let otherServer = try PersonalBankingPlan.build(feeds: [feed()], links: links, ledger: [imported], namespace: "other")
        precondition(otherServer.items.count == 1)
        let pairedFeeds = [feed(rows: [row("out", amount: -5000, other: "own-savings", reference: "ref")]),
            feed("savings", own: "own-savings", rows: [row("in", amount: 5000, other: "own-daily", reference: "ref")])]
        let transfer = try PersonalBankingPlan.build(feeds: pairedFeeds, links: links, ledger: [])
        precondition(transfer.items.count == 1 && transfer.items[0].kind == "transfer" && transfer.items[0].destination == savings)
        let localTransferID = UUID()
        let localTransfer = BankingLedgerEntry(id: localTransferID, date: day, kind: "transfer", amount: 5000,
            source: daily, destination: savings, text: "Aportación", externalID: nil)
        let oneLeg = try PersonalBankingPlan.build(feeds: [feed(rows: [row("out", amount: -5000, text: "Aportación")])], links: links, ledger: [localTransfer])
        precondition(oneLeg.items[0].automaticMatch == localTransferID, "A bank debit must preserve an existing investment transfer")
        let linkedTransfer = BankingLedgerEntry(id: localTransferID, date: day, kind: "transfer", amount: 5000,
            source: daily, destination: savings, text: "Aportación", externalID: oneLeg.items[0].id)
        let secondBank = try PersonalBankingPlan.build(feeds: pairedFeeds, links: links, ledger: [linkedTransfer])
        precondition(secondBank.items.count == 1 && secondBank.items[0].automaticMatch == localTransferID)
        let bothKeys = try PersonalBankingPlan.encodedKeys(PersonalBankingPlan.keys(linkedTransfer.externalID) + PersonalBankingPlan.keys(secondBank.items[0].id))
        let bothLinked = BankingLedgerEntry(id: localTransferID, date: day, kind: "transfer", amount: 5000,
            source: daily, destination: savings, text: "Aportación", externalID: bothKeys)
        let thirdSync = try PersonalBankingPlan.build(feeds: pairedFeeds, links: links, ledger: [bothLinked])
        precondition(thirdSync.items.isEmpty && thirdSync.alreadyImported == 1)
        let twoUnpairedLegs = try PersonalBankingPlan.build(feeds: [feed(rows: [row("out", amount: -5000, text: "Aportación")]),
            feed("savings", own: "own-savings", rows: [row("in", amount: 5000, text: "Aportación")])], links: links, ledger: [localTransfer])
        let transferDecisions = try twoUnpairedLegs.resolutions([:])
        precondition(transferDecisions.values.allSatisfy { $0 == .match(localTransferID) })
        let noReference = [feed(rows: [row(other: "own-savings")]), feed("savings", own: "own-savings", rows: [])]
        do { _ = try PersonalBankingPlan.build(feeds: noReference, links: links, ledger: []); preconditionFailure("Incomplete own transfer accepted") }
        catch PersonalBankingError.incompleteTransfer { }
        let overlapping = try PersonalBankingPlan.build(feeds: [feed(rows: [row(), row()])], links: links, ledger: [])
        precondition(overlapping.items.count == 1)
        do { _ = try PersonalBankingPlan.build(feeds: [feed(rows: [row(), row(amount: -2000)])], links: links, ledger: []); preconditionFailure("Conflicting IDs accepted") }
        catch PersonalBankingError.invalidData { }
        do { _ = try PersonalBankingPlan.build(feeds: [feed()], links: [:], ledger: []); preconditionFailure("Unlinked account accepted") }
        catch PersonalBankingError.accountNotLinked { }
        print("Personal banking plan passed: reconciliation, ambiguous purchases, renewal, account scoping, own transfers, incomplete data and stable IDs.")
    }
    static func expectReview(_ body: () throws -> Void) {
        do { try body(); preconditionFailure("Review was bypassed") }
        catch PersonalBankingError.needsReview { }
        catch { preconditionFailure("Unexpected error: \(error)") }
    }
}
