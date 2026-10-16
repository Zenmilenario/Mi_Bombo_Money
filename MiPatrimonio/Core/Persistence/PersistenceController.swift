import Foundation
import SwiftData

enum PersistenceController {
    static let schema = Schema([
        FinancialInstitution.self,
        FinancialAccount.self,
        ReservedFund.self,
        PaymentCard.self,
        FinanceCategory.self,
        CategoryRule.self,
        FinancialTransaction.self,
        MonthlyBudget.self,
        RecurringBudget.self,
        SavingsGoal.self,
        RecurringMovement.self,
        BalanceSnapshot.self,
        ImportBatch.self,
    ])
    static let shared: ModelContainer = {
        do {
            let directory = try protectedApplicationSupportDirectory()
            let storeURL = directory.appendingPathComponent("MiPatrimonio.store")
            let configuration = ModelConfiguration(
                "LocalFinance",
                schema: schema,
                url: storeURL,
                allowsSave: true,
                cloudKitDatabase: .none
            )
            let container = try ModelContainer(for: schema, configurations: configuration)
            try CategoryDefaultsService.installIfNeeded(in: ModelContext(container))
            applyCompleteFileProtection(to: directory)
            return container
        } catch {
            fatalError("No se ha podido crear el almacenamiento local: \(error.localizedDescription)")
        }
    }()

    // The testing workspace never uses MiPatrimonio.store or an in-memory fallback
    // to the real container. A failure leaves the user's real store untouched.
    @MainActor static func makeBankingTestContainer() throws -> ModelContainer {
        let directory = try protectedApplicationSupportDirectory()
        let configuration = ModelConfiguration("BankingTests", schema: schema,
            url: directory.appendingPathComponent("MiPatrimonioBankingTests.store"),
            allowsSave: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: configuration)
        try CategoryDefaultsService.restoreMissing(in: container.mainContext)
        applyCompleteFileProtection(to: directory)
        return container
    }

    private static func protectedApplicationSupportDirectory() throws -> URL {
        let fileManager = FileManager.default
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = baseURL.appendingPathComponent("MiPatrimonio", isDirectory: true)

        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
        }
        return directory
    }

    private static func applyCompleteFileProtection(to directory: URL) {
        let fileManager = FileManager.default
        do {
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: directory.path
            )

            let files = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            for file in files {
                try? fileManager.setAttributes(
                    [.protectionKey: FileProtectionType.complete],
                    ofItemAtPath: file.path
                )
            }
        } catch {
            assertionFailure("No se pudo aplicar protección completa a los archivos: \(error)")
        }
    }
}
