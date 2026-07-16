import Foundation
import SwiftData

enum RecurringMovementService {
    @discardableResult
    static func createTransaction(
        from recurring: RecurringMovement,
        on date: Date? = nil,
        in context: ModelContext
    ) throws -> FinancialTransaction {
        let transactionDate = date ?? recurring.nextDueDate
        let fingerprint = DuplicateDetectionService.fingerprint(
            date: transactionDate,
            sourceAccountID: recurring.sourceAccount?.id,
            destinationAccountID: recurring.destinationAccount?.id,
            type: recurring.type,
            amountMinor: recurring.amountMinor,
            description: recurring.descriptionText
        )

        let transaction = FinancialTransaction(
            date: transactionDate,
            type: recurring.type,
            amountMinor: recurring.amountMinor,
            descriptionText: recurring.descriptionText,
            notes: recurring.notes,
            isReconciled: false,
            fingerprint: fingerprint,
            recurringMovementID: recurring.id,
            sourceAccount: recurring.sourceAccount,
            destinationAccount: recurring.destinationAccount,
            category: recurring.category
        )
        context.insert(transaction)
        recurring.nextDueDate = nextDate(after: recurring.nextDueDate, for: recurring)
        recurring.updatedAt = .now
        try context.save()
        return transaction
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
