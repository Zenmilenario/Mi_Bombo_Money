import Foundation
import SwiftData
import CryptoKit

enum RecurringMovementService {
    @discardableResult
    static func postDueMovements(in context: ModelContext, through date: Date = .now) throws -> Int {
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: date)
        let movements = try context.fetch(FetchDescriptor<RecurringMovement>())
        var existingTransactions = try context.fetch(FetchDescriptor<FinancialTransaction>())
        var postedCount = 0

        for movement in movements where movement.isActive
            && movement.postsAutomatically == true {
            guard let source = movement.sourceAccount,
                  !source.isArchived, movement.amountMinor > 0 else {
                continue
            }
            let destination = movement.type == .transfer ? movement.destinationAccount : nil
            // Linked accounts receive actual postings from the bank; keep the template
            // but do not generate another copy of the same payment.
            if source.bankIdentityKey != nil || destination?.bankIdentityKey != nil { continue }
            if movement.type == .transfer {
                guard let destination, !destination.isArchived, source.id != destination.id else { continue }
            } else {
                guard let category = movement.category,
                      CategoryRuleService.supports(category, for: movement.type) else { continue }
            }
            let firstAccountDate = Swift.max(source.openingDate, destination?.openingDate ?? source.openingDate)

            // A bounded catch-up prevents an old rule from blocking the UI for years of entries.
            var iterations = 0
            while calendar.startOfDay(for: movement.nextDueDate) <= today && iterations < 120 {
                if let endDate = movement.endDate,
                   calendar.startOfDay(for: movement.nextDueDate) > calendar.startOfDay(for: endDate) {
                    movement.isActive = false
                    movement.updatedAt = .now
                    break
                }

                let scheduledDate = movement.nextDueDate
                let firstAccountDay = calendar.startOfDay(for: firstAccountDate)
                if calendar.startOfDay(for: scheduledDate) < firstAccountDay {
                    movement.nextDueDate = nextDate(after: scheduledDate, for: movement)
                    movement.updatedAt = .now
                    iterations += 1
                    continue
                }
                let alreadyPosted = existingTransactions.contains {
                    $0.recurringMovementID == movement.id
                        && calendar.isDate($0.date, inSameDayAs: scheduledDate)
                }
                if alreadyPosted {
                    movement.nextDueDate = nextDate(after: scheduledDate, for: movement)
                    movement.updatedAt = .now
                } else {
                    let postingDate = Swift.max(
                        calendar.startOfDay(for: scheduledDate),
                        firstAccountDate
                    )
                    let transaction = try createTransaction(
                        from: movement,
                        on: postingDate,
                        in: context,
                        saveImmediately: false
                    )
                    existingTransactions.append(transaction)
                    postedCount += 1
                }
                iterations += 1
            }
        }

        if context.hasChanges {
            try save(in: context)
        }

        return postedCount
    }

    @discardableResult
    static func createTransaction(
        from recurring: RecurringMovement,
        on date: Date? = nil,
        in context: ModelContext,
        saveImmediately: Bool = true
    ) throws -> FinancialTransaction {
        let transactionDate = date ?? recurring.nextDueDate
        let destination = recurring.type == .transfer ? recurring.destinationAccount : nil
        let fingerprint = DuplicateDetectionService.fingerprint(
            date: transactionDate,
            sourceAccountID: recurring.sourceAccount?.id,
            destinationAccountID: destination?.id,
            type: recurring.type,
            amountMinor: recurring.amountMinor,
            description: recurring.descriptionText
        )

        let transaction = FinancialTransaction(
            id: occurrenceID(ruleID: recurring.id, scheduledDate: recurring.nextDueDate),
            date: transactionDate,
            type: recurring.type,
            amountMinor: recurring.amountMinor,
            descriptionText: recurring.descriptionText,
            notes: recurring.notes,
            isReconciled: false,
            fingerprint: fingerprint,
            recurringMovementID: recurring.id,
            sourceAccount: recurring.sourceAccount,
            destinationAccount: destination,
            category: recurring.category
        )
        context.insert(transaction)
        recurring.nextDueDate = nextDate(after: recurring.nextDueDate, for: recurring)
        recurring.updatedAt = .now
        if saveImmediately {
            try save(in: context)
        }
        return transaction
    }

    static func occurrenceID(ruleID: UUID, scheduledDate: Date) -> UUID {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let key = "recurring-v1:\(ruleID.uuidString.lowercased()):\(formatter.string(from: scheduledDate))"
        var bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],
                           bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }

    private static func save(in context: ModelContext) throws {
        do {
            try context.save()
        } catch {
            // Keep the movement and its next due date atomic when saving fails.
            context.rollback()
            throw error
        }
    }

    static func nextDate(
        after date: Date,
        for recurring: RecurringMovement,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date {
        let interval = Swift.max(1, recurring.interval)
        switch recurring.frequency {
        case .weekly:
            return calendar.date(byAdding: .weekOfYear, value: interval, to: date) ?? date
        case .monthly:
            return calendar.date(byAdding: .month, value: interval, to: date) ?? date
        case .quarterly:
            return calendar.date(byAdding: .month, value: 3 * interval, to: date) ?? date
        case .yearly:
            return calendar.date(byAdding: .year, value: interval, to: date) ?? date
        }
    }
}
