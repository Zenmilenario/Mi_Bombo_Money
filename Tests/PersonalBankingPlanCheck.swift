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
        precondition(activity.pendingTotal == -500 && activity.heldTotal == -500)
        // Diagnostic in Mis bancos: what the bank actually sent, newest first.
        precondition(activity.receivedCount == 1 && activity.recentMovements?.map(\.signedAmountMinor) == [-1000])
        let several = BankingAccountActivity(feed: BankingAccountFeed(connection: existingFeed.connection, account: existingFeed.account,
            balances: [], movements: (1...12).map { day in
                BankingPreview.Movement(id: "m\(day)", bookingDate: String(format: "2026-10-%02d", day), signedAmountMinor: -Int64(day),
                    currency: "EUR", description: "Compra ficticia", counterpartyKey: nil, transferKey: nil)
            }), observedAt: day)
        precondition(several.receivedCount == 12 && several.recentMovements?.count == 8
            && several.recentMovements?.first?.bookingDate == "2026-10-12", "Only the newest postings are kept")
        let withIgnored = BankingAccountActivity(feed: BankingAccountFeed(connection: existingFeed.connection, account: existingFeed.account,
            balances: [], movements: [], pendingMovements: [], ignoredStatuses: ["CNCL": 2, "NONE": 1]), observedAt: day)
        precondition(withIgnored.ignoredStatuses == ["CNCL": 2, "NONE": 1] && withIgnored.recentMovements == [],
            "Entries the bank sent with other statuses are reported, never imported")
        let decodedPreview = try JSONDecoder().decode(BankingPreview.self, from: Data(
            #"{"balances":[],"transactions":[],"ignoredStatuses":{"OTHR":3},"continuation":null}"#.utf8))
        precondition(decodedPreview.ignoredStatuses == ["OTHR": 3])
        let legacyActivity = try JSONDecoder().decode(BankingAccountActivity.self, from: Data(
            #"{"observedAt":0,"currency":"EUR","bookedBalance":null,"availableBalance":null,"pendingMovements":null}"#.utf8))
        precondition(legacyActivity.recentMovements == nil, "Activity saved by 0.7.3 still loads")
        let roundTrip = try JSONDecoder().decode(BankingAccountActivity.self, from: JSONEncoder().encode(activity))
        precondition(roundTrip.pendingMovements?.first?.description == "Retención ficticia" && roundTrip.observedAt == activity.observedAt,
                     "Holds survive being saved on the device")
        let credit = try JSONDecoder().decode(BankingPreview.self, from: Data("""
        {"balances":[],"transactions":[],"pendingTransactions":[
            {"id":"in","date":"2026-10-15","signedAmountMinor":700,"currency":"EUR","description":"Abono ficticio","status":"PDNG"},
            {"id":"out","date":"2026-10-15","signedAmountMinor":-300,"currency":"EUR","description":"Cargo ficticio","status":"HOLD"}]}
        """.utf8))
        let creditActivity = BankingAccountActivity(feed: BankingAccountFeed(connection: existingFeed.connection,
            account: existingFeed.account, balances: [], movements: [], pendingMovements: credit.pendingTransactions), observedAt: day)
        precondition(creditActivity.pendingTotal == 400 && creditActivity.heldTotal == -300,
                     "A pending credit is not money available yet; only held charges reduce the available amount")
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

        let previousDebit = imported.first { $0.kind == "expense" }!
        let edited = BankingLedgerEntry(id: previousDebit.id, date: day, kind: "transfer", amount: 1200,
            source: daily, destination: savings, text: "Aportación corregida", externalID: previousDebit.externalID)
        let newDebit = row(nil, amount: -2500, text: "Movimiento bancario")
        let afterEdit = try PersonalBankingPlan.build(feeds: [feed(rows: [debit, newDebit], bank: "Trade Republic")],
            links: links, ledger: [edited])
        precondition(afterEdit.alreadyImported == 1 && afterEdit.items.map(\.amount) == [2500] && afterEdit.requiresReferenceReview)

        let stableFeed = feed(bank: "Trade Republic")
        let stable = try PersonalBankingPlan.build(feeds: [stableFeed], links: links, ledger: [])
        let changed = BankingLedgerEntry(id: UUID(), date: day, kind: "expense", amount: 1200,
            source: daily, destination: nil, text: "Compra", externalID: stable.items[0].id)
        // A posting the user edited after importing it keeps the user's version and no longer blocks the bank.
        let keptEdit = try PersonalBankingPlan.build(feeds: [stableFeed], links: links, ledger: [changed])
        precondition(keptEdit.items.isEmpty && keptEdit.alreadyImported == 1)
        precondition(keptEdit.keptEdits == [.init(bank: "Trade Republic", bookingDate: stableFeed.movements[0].bookingDate)])
        precondition(keptEdit.keptEditsSummary()["Trade Republic"]?.contains("15/10/2026") == true)
        precondition(stable.keptEdits.isEmpty && stable.keptEditsSummary().isEmpty)
        // Trade Republic moved a posting to the next day: its generated key changed. The stored record is
        // proposed under the new key, never matched automatically.
        let original = try PersonalBankingPlan.build(feeds: [feed(rows: [debit], bank: "Trade Republic")], links: links, ledger: [])
        let stored = BankingLedgerEntry(id: UUID(), date: day, kind: "transfer", amount: 1000, source: daily,
            destination: savings, text: "Aportación ficticia", externalID: original.items[0].id)
        let shifted = BankingPreview.Movement(id: nil, bookingDate: "2026-10-16", signedAmountMinor: -1000, currency: "EUR",
            description: "Movimiento bancario", counterpartyKey: nil, transferKey: nil)
        let moved = try PersonalBankingPlan.build(feeds: [feed(rows: [shifted], bank: "Trade Republic")], links: links, ledger: [stored])
        precondition(moved.items.count == 1 && moved.items[0].rekeyCandidates == [stored.id])
        precondition(moved.items[0].suggestedMatch == stored.id && moved.items[0].automaticMatch == nil)
        _ = try moved.resolutions(moved.acceptingSuggestions([:]))
        // Two real postings of the same amount on consecutive days: the stored key is still sent, so no rekey.
        let both = try PersonalBankingPlan.build(feeds: [feed(rows: [debit, shifted], bank: "Trade Republic")], links: links, ledger: [stored])
        precondition(both.alreadyImported == 1 && both.items.count == 1 && both.items[0].rekeyCandidates.isEmpty)
        precondition(PersonalBankingError.changed.bank == nil && PersonalBankingError.incompleteTransfer.bank == nil,
            "Errors that are not tied to one bank's feed must still stop the whole download")
        // Trade Republic names no counterparty: a credit pointing to it would wait forever for a referenced peer.
        let trAccount = ConnectedBankAccount(id: "tr", name: "Trade Republic ficticia", currency: "EUR", lastFour: "0000", ownershipKey: "own-tr")
        let trFeed = BankingAccountFeed(connection: .init(id: UUID().uuidString, bank: "Trade Republic", validUntil: "2026-11-01", accounts: [trAccount]),
            account: trAccount, balances: [.init(amountMinor: 1000, currency: "EUR", type: "CLBD")],
            movements: [row(nil, amount: -5000, text: "Movimiento bancario")])
        let inbound = feed("savings", own: "own-savings", rows: [row("from-tr", amount: 5000, text: "Ingreso", other: "own-tr", reference: "ref-tr")])
        let waiting = try PersonalBankingDownloadSelection.prepare([trFeed, inbound], knownAccounts: [trAccount, inbound.account])
        precondition(waiting.deferredByBank["Bankinter"] == 1 && waiting.feeds[1].movements.isEmpty)
        let released = try PersonalBankingDownloadSelection.prepare([trFeed, inbound], knownAccounts: [trAccount, inbound.account],
            referenceLessAccounts: ["tr"])
        precondition(released.deferredByBank.isEmpty && released.feeds[1].movements.count == 1)
        precondition(released.feeds[1].movements[0].counterpartyKey == nil && released.feeds[1].movements[0].transferKey == nil)
        precondition(released.ownTransferHints == ["savings": ["from-tr"]], "The bank's own-account hint is kept for pairing")
        let releasedPlan = try PersonalBankingPlan.build(feeds: released.feeds, links: ["tr": daily, "savings": savings], ledger: [])
        precondition(releasedPlan.items.map(\.kind).sorted() == ["expense", "income"], "Both legs import; pairing joins them afterwards")
        // A CSV or form record at Spanish midnight is the previous UTC day, but the same booking day.
        let madrid = TimeZone(identifier: "Europe/Madrid")!
        var madridCalendar = Calendar(identifier: .gregorian); madridCalendar.timeZone = madrid
        let localMidnight = madridCalendar.date(from: DateComponents(year: 2026, month: 10, day: 15))!
        let csvEntry = BankingLedgerEntry(id: UUID(), date: localMidnight, kind: "expense", amount: 4321, source: daily,
            destination: nil, text: "Librería Ficticia", externalID: nil)
        let csvFeed = feed(rows: [row("csv-match", amount: -4321, text: "Librería Ficticia")])
        let madridPlan = try PersonalBankingPlan.build(feeds: [csvFeed], links: links, ledger: [csvEntry], timeZone: madrid)
        precondition(madridPlan.items[0].automaticMatch == csvEntry.id, "A local-midnight record matches its own booking day")
        let nextDay = BankingLedgerEntry(id: UUID(), date: localMidnight.addingTimeInterval(86400), kind: "expense", amount: 4321,
            source: daily, destination: nil, text: "Librería Ficticia", externalID: nil)
        let laterPlan = try PersonalBankingPlan.build(feeds: [csvFeed], links: links, ledger: [nextDay], timeZone: madrid)
        precondition(laterPlan.items[0].automaticMatch == nil && laterPlan.items[0].candidates == [nextDay.id],
            "Another day is still only a candidate for review")

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
