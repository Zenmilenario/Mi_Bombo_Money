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
        precondition(similar.items[0].automaticMatch == nil && similar.items[0].suggestedMatch != nil,
                     "A unique same-day amount is a proposal, never an automatic match")
        let accepted = similar.acceptingSuggestions([:])
        precondition(similar.unresolvedItems(accepted).isEmpty)
        _ = try similar.resolutions(accepted)
        precondition(similar.acceptingSuggestions(separateChoices) == separateChoices, "Bulk acceptance must preserve manual decisions")
        let prefixed = try PersonalBankingPlan.build(feeds: [feed(rows: [row(text: "/TXT/D|  CÓMPRA * ")])], links: links, ledger: [local])
        precondition(prefixed.items[0].automaticMatch == local.id, "Technical bank prefixes and punctuation must not force manual review")
        precondition(repeated.items[0].suggestedMatch == nil && repeated.unresolvedItems([:]).count == 1,
                     "Repeated identical local purchases remain ambiguous")
        let nearby = BankingLedgerEntry(id: UUID(), date: day.addingTimeInterval(-86400), kind: "expense", amount: 1000,
            source: daily, destination: nil, text: "Compra supermercado", externalID: nil)
        let shifted = try PersonalBankingPlan.build(feeds: [feed(rows: [row(text: "/TXT/D|SUPERMERCADO CENTRAL")])], links: links, ledger: [nearby])
        precondition(shifted.items[0].automaticMatch == nil && shifted.items[0].suggestedMatch == nearby.id)
        expectReview { _ = try shifted.resolutions([:]) }
        let unrelated = try PersonalBankingPlan.build(feeds: [feed(rows: [row(text: "Restaurante")])], links: links, ledger: [nearby])
        precondition(unrelated.items[0].suggestedMatch == nil, "Amount alone on different days is not a proposal")
        let cafe = entry(text: "Cafetería del parque")
        let ranked = try PersonalBankingPlan.build(feeds: [feed(rows: [row(text: "/TXT/D|Cafeteria del parque")])], links: links,
            ledger: [local, cafe])
        precondition(ranked.items[0].automaticMatch == nil && ranked.items[0].suggestedMatch == cafe.id && ranked.items[0].candidates.first == cafe.id)
        let wrongAccount = BankingLedgerEntry(id: UUID(), date: day, kind: "expense", amount: 1000,
            source: savings, destination: nil, text: "Compra", externalID: nil)
        let scoped = try PersonalBankingPlan.build(feeds: [feed()], links: links, ledger: [wrongAccount])
        precondition(scoped.items[0].candidates.isEmpty && scoped.unresolvedItems([:]).isEmpty)
        let bulkLedger = (1...67).map { index in
            BankingLedgerEntry(id: UUID(), date: day, kind: "expense", amount: Int64(index * 100),
                source: daily, destination: nil, text: "Mi anotación \(index)", externalID: nil)
        }
        let bulkRows = (1...67).map { row("batch-\($0)", amount: -Int64($0 * 100), text: "Concepto bancario \($0)") }
        let bulk = try PersonalBankingPlan.build(feeds: [feed(rows: bulkRows)], links: links, ledger: bulkLedger)
        precondition(bulk.unresolvedItems([:]).count == 67 && bulk.items.allSatisfy { $0.automaticMatch == nil && $0.suggestedMatch != nil })
        let bulkDecisions = bulk.acceptingSuggestions([:])
        precondition(bulkDecisions.count == 67 && bulk.unresolvedItems(bulkDecisions).isEmpty)
        let bulkResolved = try bulk.resolutions(bulkDecisions)
        precondition(bulkResolved.values.allSatisfy { if case .match = $0 { return true }; return false })
        let noContent = try PersonalBankingPlan.build(feeds: [feed(rows: [row(text: "/TXT/D|***")])], links: links, ledger: [entry(text: "---")])
        precondition(noContent.items[0].automaticMatch == nil, "Empty cleaned text is not a safe automatic match")
        let competing = try PersonalBankingPlan.build(feeds: [feed(rows: [row("a"), row("b")])], links: links, ledger: [local])
        precondition(competing.items.allSatisfy { $0.automaticMatch == nil })
        expectReview { _ = try competing.resolutions(Dictionary(uniqueKeysWithValues: competing.items.map { ($0.id, .match(local.id)) })) }
        let competingSuggestions = try PersonalBankingPlan.build(feeds: [feed(rows: [row("a"), row("b")])], links: links, ledger: [entry(text: "Otro concepto")])
        precondition(competingSuggestions.items.allSatisfy { $0.suggestedMatch == nil }, "Two bank purchases cannot propose consuming one record")
        let prepared = [competing.items[0].id: PersonalBankingPlan.Choice.match(local.id)]
        precondition(!competing.canMatch(competing.items[1], to: local.id, choices: prepared))
        precondition(competing.canMatch(competing.items[0], to: local.id, choices: prepared))
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
        print("Personal banking plan passed: technical prefixes, explicit bulk proposals, repeated purchases, candidate conflicts, renewal, account scoping, transfers and stable IDs.")
    }
    static func expectReview(_ body: () throws -> Void) {
        do { try body(); preconditionFailure("Review was bypassed") }
        catch PersonalBankingError.needsReview { }
        catch { preconditionFailure("Unexpected error: \(error)") }
    }
}
