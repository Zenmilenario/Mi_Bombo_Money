import Foundation

@main
struct PersonalBankingPlanCheck {
    static let daily = UUID(), savings = UUID()
    static let day = ISO8601DateFormatter().date(from: "2026-10-15T00:00:00Z")!
    static func row(_ id: String? = "expense", amount: Int64 = -1000, text: String = "Compra", other: String? = nil, reference: String? = nil) -> BankingPreview.Movement {
        .init(id: id, bookingDate: "2026-10-15", signedAmountMinor: amount, currency: "EUR", description: text, counterpartyKey: other, transferKey: reference)
    }
    static func feed(_ id: String = "daily", own: String = "own-daily", rows: [BankingPreview.Movement]? = nil, bank: String = "Bankinter") -> BankingAccountFeed {
        let account = ConnectedBankAccount(id: id, name: "Cuenta ficticia", currency: "EUR", lastFour: "1234", ownershipKey: own)
        return .init(connection: .init(id: UUID().uuidString, bank: bank, validUntil: "2026-11-01", accounts: [account]),
            account: account, balances: [.init(amountMinor: 9000, currency: "EUR", type: "CLBD")], movements: rows ?? [row()])
    }
    static func entry(id: UUID = UUID(), text: String = "Compra", external: String? = nil) -> BankingLedgerEntry {
        .init(id: id, date: day, kind: "expense", amount: 1000, source: daily, destination: nil, text: text, externalID: external)
    }
    @MainActor static func main() async throws {
        let links = ["daily": daily, "savings": savings]
        let first = try PersonalBankingPlan.build(feeds: [feed()], links: links, ledger: [])
        precondition(first.items.count == 1 && first.balances[0].amount == 9000)
        let mixed = try JSONDecoder().decode(BankingPreview.self, from: Data("""
        {"balances":[{"amountMinor":9000,"currency":"EUR","type":"CLBD"},
                     {"amountMinor":8500,"currency":"EUR","type":"ITAV"}],
         "transactions":[],
         "pendingTransactions":[
            {"id":"expense","date":null,"signedAmountMinor":-1000,"currency":"EUR","description":"Ya confirmado","status":"PDNG"},
            {"id":null,"date":"2026-10-15","signedAmountMinor":-500,"currency":"EUR","description":"Retención ficticia","status":"HOLD"}]}
        """.utf8))
        let existingFeed = feed()
        let mixedFeed = BankingAccountFeed(connection: existingFeed.connection, account: existingFeed.account,
            balances: mixed.balances, movements: existingFeed.movements, pendingMovements: mixed.pendingTransactions)
        let activity = BankingAccountActivity(feed: mixedFeed, observedAt: day)
        precondition(activity.availableBalance == 8500 && activity.bookedBalance == 9000)
        precondition(activity.pendingMovements?.map(\.signedAmountMinor) == [-500], "A booked reference supersedes its pending entry")
        let mixedPlan = try PersonalBankingPlan.build(feeds: [mixedFeed], links: links, ledger: [])
        precondition(mixedPlan.items.count == 1 && mixedPlan.balances[0].amount == 9000,
                     "Bank holds and available balances cannot enter accounting")
        let legacy = try JSONDecoder().decode(BankingPreview.self, from: Data(#"{"balances":[],"transactions":[]}"#.utf8))
        precondition(legacy.pendingTransactions == nil, "Support the previous worker response")
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
        try checkTradeRepublicWithoutReferences(links: links)
        checkContributionCombinations()
        try await checkIndependentDownloads()
        print("Personal banking plan passed: technical prefixes, explicit bulk proposals, repeated purchases, candidate conflicts, renewal, account scoping, transfers and stable IDs.")
    }
    private static func checkContributionCombinations() {
        let a = UUID(), b = UUID(), c = UUID()
        let split: [ContributionRecognition.Posting] = [.init(id: a, amount: 20000), .init(id: b, amount: 20000)]
        precondition(ContributionRecognition.match(split, remaining: 40000) == .unique([a, b]))
        precondition(ContributionRecognition.match(Array(split.reversed()), remaining: 40000) == .unique([a, b]))
        precondition(ContributionRecognition.match(split, remaining: 20000) == .ambiguous)
        precondition(ContributionRecognition.match(split, remaining: 50000) == .none)
        let uneven: [ContributionRecognition.Posting] = [.init(id: a, amount: 12000), .init(id: b, amount: 23000)]
        precondition(ContributionRecognition.match(uneven, remaining: 35000) == .unique([a, b]))
        precondition(ContributionRecognition.match(split + [.init(id: c, amount: 40000)], remaining: 40000) == .ambiguous)
        precondition(ContributionRecognition.match([.init(id: a, amount: Int64.max)], remaining: 40000) == .none)
        precondition(ContributionRecognition.match(split, remaining: 0) == .none)
        let many = (0..<61).map { _ in ContributionRecognition.Posting(id: UUID(), amount: 100) }
        precondition(ContributionRecognition.match(many, remaining: 40000) == .requiresSelection)
    }
    private static func checkTradeRepublicWithoutReferences(links: [String: UUID]) throws {
        let debit = row(nil, text: "Movimiento bancario")
        let credit = row(nil, amount: 1000, text: "Movimiento bancario")
        let manual = entry(text: debit.description)
        let single = try PersonalBankingPlan.build(feeds: [feed(rows: [debit], bank: "Trade Republic")], links: links, ledger: [manual])
        precondition(single.items[0].suggestedMatch == manual.id && single.items[0].automaticMatch == nil)
        let first = try PersonalBankingPlan.build(feeds: [feed(rows: [debit, credit, debit], bank: "Trade Republic")], links: links, ledger: [manual])
        precondition(first.items.count == 3 && Set(first.items.map(\.id)).count == 3 && first.requiresReferenceReview)
        precondition(first.items.allSatisfy { $0.automaticMatch == nil }, "Local references must not automatically claim a manual record")
        let imported = first.items.map { item in
            BankingLedgerEntry(id: UUID(), date: item.date, kind: item.kind, amount: item.amount, source: item.source,
                               destination: item.destination, text: item.text, externalID: item.id)
        }
        let same = try PersonalBankingPlan.build(feeds: [feed(rows: [debit, debit, credit], bank: "Trade Republic")], links: links, ledger: imported)
        precondition(same.items.isEmpty && same.alreadyImported == 3 && !same.requiresReferenceReview)
        let extra = try PersonalBankingPlan.build(feeds: [feed(rows: [credit, debit, debit, debit], bank: "Trade Republic")], links: links, ledger: imported)
        precondition(extra.items.count == 1 && extra.items[0].kind == "expense" && extra.requiresReferenceReview)

        do {
            _ = try PersonalBankingPlan.build(feeds: [feed(rows: [debit])], links: links, ledger: [])
            preconditionFailure("Reference fallback leaked to other banks")
        } catch PersonalBankingError.missingMovementReference(_) { }
        let received = feed(rows: [debit], bank: "Trade Republic")
        let withoutBookedBalance = BankingAccountFeed(connection: received.connection, account: received.account,
            balances: [.init(amountMinor: 9000, currency: "EUR", type: "CLAV")], movements: received.movements)
        let review = try PersonalBankingPlan.build(feeds: [withoutBookedBalance], links: links, ledger: [])
        precondition(review.items.count == 1 && review.balances.isEmpty && review.requiresBalanceReview)
        precondition(review.balanceGaps.first?.diagnostics == "CLAV · EUR × 1")
        let decisions = try review.resolutions([:])
        precondition(review.newBalanceEffects(for: daily, after: day, through: day, decisions: decisions) == 0)
        precondition(review.newBalanceEffects(for: daily, after: day.addingTimeInterval(-1), through: day, decisions: decisions) == -1000)
        let alreadyEntered = try PersonalBankingPlan.build(feeds: [withoutBookedBalance], links: links, ledger: [manual])
        let matched = try alreadyEntered.resolutions([alreadyEntered.items[0].id: .match(manual.id)])
        precondition(alreadyEntered.newBalanceEffects(for: daily, after: day.addingTimeInterval(-1), through: day, decisions: matched) == 0)

        let balance = BankingPreview.Balance(amountMinor: 9000, currency: "EUR", type: "CLBD")
        let repeatedBalance = BankingAccountFeed(connection: received.connection, account: received.account,
            balances: [balance, balance], movements: [debit])
        let verified = try PersonalBankingPlan.build(feeds: [repeatedBalance], links: links, ledger: [])
        precondition(verified.balances.first?.amount == 9000 && verified.balanceGaps.isEmpty)
        let conflicting = BankingAccountFeed(connection: received.connection, account: received.account,
            balances: [balance, .init(amountMinor: 10000, currency: "EUR", type: "CLBD")], movements: [debit])
        let conflictReview = try PersonalBankingPlan.build(feeds: [conflicting], links: links, ledger: [])
        precondition(conflictReview.balances.isEmpty && conflictReview.requiresBalanceReview)
        let otherBank = BankingAccountFeed(connection: feed().connection, account: received.account,
            balances: withoutBookedBalance.balances, movements: [row()])
        do {
            _ = try PersonalBankingPlan.build(feeds: [otherBank], links: links, ledger: [])
            preconditionFailure("Trade Republic's balance policy leaked to other banks")
        } catch PersonalBankingError.unavailableBookedBalance(_) { }
    }
    @MainActor private static func checkIndependentDownloads() async throws {
        enum FixtureFailure: Error { case unavailable }
        let bbva = feed("savings", own: "own-savings", rows: [row("bbva-charge", amount: -750)], bank: "BBVA")
        let bankinter = feed()
        var attempted: [String] = []
        let outcomes = try await PersonalBankingDownloadBatch.load([bankinter.connection, bbva.connection]) { group in
            attempted.append(group[0].bank)
            if group[0].bank == "Bankinter" { throw FixtureFailure.unavailable }
            return [bbva]
        }
        precondition(Set(attempted) == ["BBVA", "Bankinter"] && outcomes.count == 2)
        var good: [BankingAccountFeed] = []
        var failed: [String] = []
        for outcome in outcomes {
            switch outcome {
            case .downloaded(_, let feeds): good += feeds
            case .failed(let bank, _): failed.append(bank)
            }
        }
        let known = [bbva.account, bankinter.account]
        let independent = try PersonalBankingDownloadSelection.prepare(good, knownAccounts: known)
        let plan = try PersonalBankingPlan.build(feeds: independent.feeds, links: ["daily": daily, "savings": savings], ledger: [])
        precondition(failed == ["Bankinter"] && plan.items.count == 1 && plan.items[0].source == savings)
        precondition(plan.items[0].amount == 750, "A failed bank must not discard an unrelated bank charge")

        let incoming = feed("savings", own: "own-savings", rows: [row("own-in", amount: 5000, other: "own-daily", reference: "pair"), row("bbva-charge", amount: -750)], bank: "BBVA")
        let partial = try PersonalBankingDownloadSelection.prepare([incoming], knownAccounts: known)
        precondition(partial.deferredByBank["BBVA"] == 1 && partial.feeds[0].movements.count == 1)
        let partialPlan = try PersonalBankingPlan.build(feeds: partial.feeds, links: ["savings": savings], ledger: [])
        precondition(partialPlan.items.count == 1 && partialPlan.items[0].kind == "expense")
        precondition(partialPlan.balances.count == 1, "Keep the bank's actual booked balance; never invent a balance excluding transfers")

        let outgoing = feed(rows: [row("own-out", amount: -5000, other: "own-savings", reference: "pair")])
        let complete = try PersonalBankingDownloadSelection.prepare([incoming, outgoing], knownAccounts: known)
        let completePlan = try PersonalBankingPlan.build(feeds: complete.feeds, links: ["daily": daily, "savings": savings], ledger: [])
        precondition(complete.deferredByBank.isEmpty && completePlan.items.filter { $0.kind == "transfer" }.count == 1)
        let existingCharge = BankingLedgerEntry(id: UUID(), date: day, kind: "expense", amount: 750,
            source: savings, destination: nil, text: "Compra", externalID: partialPlan.items[0].id)
        let restored = try PersonalBankingPlan.build(feeds: complete.feeds, links: ["daily": daily, "savings": savings], ledger: [existingCharge])
        precondition(restored.alreadyImported == 1 && restored.items.count == 1 && restored.items[0].kind == "transfer")

        let ambiguous = feed(rows: outgoing.movements + outgoing.movements)
        let deferred = try PersonalBankingDownloadSelection.prepare([incoming, ambiguous], knownAccounts: known)
        precondition(deferred.feeds.allSatisfy { $0.movements.allSatisfy { $0.counterpartyKey == nil } },
            "Ambiguous transfers must defer both sides without blocking independent purchases")
        let unknown = feed("savings", own: "own-savings", rows: [row(other: "unknown-party")], bank: "BBVA")
        let ordinary = try PersonalBankingDownloadSelection.prepare([unknown], knownAccounts: known)
        precondition(ordinary.deferredByBank.isEmpty)

        do {
            _ = try await PersonalBankingDownloadBatch.load([bankinter.connection, bbva.connection]) { _ in throw CancellationError() }
            preconditionFailure("Cancellation must not become a partial successful download")
        } catch is CancellationError { }
        let reversed = try await PersonalBankingDownloadBatch.load([bankinter.connection, bbva.connection]) { group in
            if group[0].bank == "BBVA" { throw FixtureFailure.unavailable }
            return [bankinter]
        }
        precondition(reversed.contains { if case .downloaded("Bankinter", _) = $0 { return true }; return false })
    }
    static func expectReview(_ body: () throws -> Void) {
        do { try body(); preconditionFailure("Review was bypassed") }
        catch PersonalBankingError.needsReview { }
        catch { preconditionFailure("Unexpected error: \(error)") }
    }
}
