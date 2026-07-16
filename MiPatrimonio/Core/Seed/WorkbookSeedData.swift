import Foundation
import SwiftData

enum WorkbookSeedData {
    private static let didSeedKey = "didSeedWorkbookDataV1"

    @MainActor
    static func seedIfNeeded(in context: ModelContext) throws {
        guard !UserDefaults.standard.bool(forKey: didSeedKey) else { return }

        var descriptor = FetchDescriptor<FinancialAccount>()
        descriptor.fetchLimit = 1
        guard try context.fetch(descriptor).isEmpty else {
            UserDefaults.standard.set(true, forKey: didSeedKey)
            return
        }

        let bankinter = FinancialInstitution(name: "Bankinter", colorHex: "#D46A1F")
        let tradeRepublic = FinancialInstitution(name: "Trade Republic", colorHex: "#202124")
        let bbva = FinancialInstitution(name: "BBVA", colorHex: "#1464A5")
        [bankinter, tradeRepublic, bbva].forEach(context.insert)

        let july15 = makeDate(year: 2026, month: 7, day: 15)
        let july1 = makeDate(year: 2026, month: 7, day: 1)

        let bankinterAccount = FinancialAccount(
            name: "Bankinter - Nómina",
            type: .checking,
            openingBalanceMinor: 0,
            openingDate: july1,
            annualInterestRate: 0.025,
            targetBalanceMinor: 250_000,
            sortOrder: 0,
            notes: "Cuenta principal / nómina",
            lastUpdatedAt: july15,
            institution: bankinter
        )
        let tradeAccount = FinancialAccount(
            name: "Trade Republic - Ahorro",
            type: .savings,
            openingBalanceMinor: 0,
            openingDate: july1,
            annualInterestRate: 0.03,
            targetBalanceMinor: 100_000,
            sortOrder: 1,
            notes: "Ahorro remunerado",
            lastUpdatedAt: july15,
            institution: tradeRepublic
        )
        let bbvaAccount = FinancialAccount(
            name: "BBVA - Cuenta joven",
            type: .checking,
            openingBalanceMinor: 204_066,
            openingDate: july1,
            annualInterestRate: 0,
            targetBalanceMinor: 50_000,
            sortOrder: 2,
            notes: "Cuenta secundaria / respaldo",
            lastUpdatedAt: july15,
            institution: bbva
        )
        [bankinterAccount, tradeAccount, bbvaAccount].forEach(context.insert)

        let categories = makeCategories()
        categories.forEach(context.insert)
        let categoryByName = Dictionary(uniqueKeysWithValues: categories.map { ($0.name, $0) })

        let transferCategory = categoryByName["Transferencia entre cuentas"]
        let transferOne = FinancialTransaction(
            date: july15,
            type: .transfer,
            amountMinor: 85_000,
            descriptionText: "Transferencia inicial para activar Bankinter",
            isReconciled: true,
            sourceAccount: bbvaAccount,
            destinationAccount: bankinterAccount,
            category: transferCategory
        )
        transferOne.fingerprint = DuplicateDetectionService.fingerprint(
            date: transferOne.date,
            sourceAccountID: bbvaAccount.id,
            destinationAccountID: bankinterAccount.id,
            type: .transfer,
            amountMinor: transferOne.amountMinor,
            description: transferOne.descriptionText
        )

        let transferTwo = FinancialTransaction(
            date: july15,
            type: .transfer,
            amountMinor: 65_000,
            descriptionText: "Ingreso para activar Trade Republic",
            isReconciled: true,
            sourceAccount: bbvaAccount,
            destinationAccount: tradeAccount,
            category: transferCategory
        )
        transferTwo.fingerprint = DuplicateDetectionService.fingerprint(
            date: transferTwo.date,
            sourceAccountID: bbvaAccount.id,
            destinationAccountID: tradeAccount.id,
            type: .transfer,
            amountMinor: transferTwo.amountMinor,
            description: transferTwo.descriptionText
        )
        context.insert(transferOne)
        context.insert(transferTwo)

        let budgetValues: [(String, Int64)] = [
            ("Restaurantes", 20_000),
            ("Combustible", 15_000),
            ("Ocio", 30_000),
            ("Gimnasio y salud", 5_000),
            ("Ropa y compras", 10_000),
            ("Otros", 10_000),
        ]
        for (categoryName, limit) in budgetValues {
            guard let category = categoryByName[categoryName] else { continue }
            context.insert(MonthlyBudget(monthStart: july1, limitMinor: limit, category: category))
        }

        context.insert(SavingsGoal(
            name: "Fondo de emergencia",
            targetAmountMinor: 100_000,
            currentAmountMinor: 65_000,
            targetDate: makeDate(year: 2026, month: 12, day: 31),
            notes: "Objetivo inicial inspirado en la cuenta de ahorro del Excel.",
            linkedAccount: tradeAccount
        ))

        try context.save()
        UserDefaults.standard.set(true, forKey: didSeedKey)
    }

    private static func makeCategories() -> [FinanceCategory] {
        let definitions: [(String, CategoryKind, String)] = [
            ("Nómina", .income, "briefcase"),
            ("Bonificación bancaria", .income, "gift"),
            ("Intereses", .income, "percent"),
            ("Reembolso", .income, "arrow.uturn.backward"),
            ("Vivienda", .expense, "house"),
            ("Supermercado", .expense, "cart"),
            ("Restaurantes", .expense, "fork.knife"),
            ("Transporte", .expense, "bus"),
            ("Combustible", .expense, "fuelpump"),
            ("Ocio", .expense, "ticket"),
            ("Gimnasio y salud", .expense, "heart"),
            ("Suscripciones", .expense, "repeat"),
            ("Tecnología", .expense, "desktopcomputer"),
            ("Ropa y compras", .expense, "bag"),
            ("Viajes", .expense, "airplane"),
            ("Formación", .expense, "graduationcap"),
            ("Seguros", .expense, "shield"),
            ("Impuestos y comisiones", .expense, "doc.text"),
            ("Transferencia entre cuentas", .transfer, "arrow.left.arrow.right"),
            ("Otros", .both, "ellipsis.circle"),
            ("Sin categoría", .both, "questionmark.circle"),
        ]

        return definitions.enumerated().map { index, definition in
            FinanceCategory(
                name: definition.0,
                kind: definition.1,
                systemImage: definition.2,
                colorHex: palette[index % palette.count],
                isSystem: definition.0 == "Transferencia entre cuentas" || definition.0 == "Sin categoría",
                sortOrder: index
            )
        }
    }

    private static let palette = [
        "#1F6B7A", "#2F7D66", "#8A6D3B", "#6E5A8A", "#A04E4E",
        "#2E6E9E", "#7D5A50", "#4D7C8A", "#916B4C", "#5E7A4D",
    ]

    private static func makeDate(year: Int, month: Int, day: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(
            timeZone: .autoupdatingCurrent,
            year: year,
            month: month,
            day: day,
            hour: 12
        )) ?? .now
    }
}
