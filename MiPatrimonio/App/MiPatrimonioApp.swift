import SwiftData
import SwiftUI

@main
struct MiPatrimonioApp: App {
    private let modelContainer = PersistenceController.shared
    @StateObject private var lockManager = AppLockManager()
    @StateObject private var cloudAccount = CloudAccountManager()

    init() {
        // Balances come from an index rebuilt after each save instead of reading every movement per account.
        BalanceIndexCache.enable()
        _ = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) { _ in
            BalanceIndexCache.invalidate()
        }
    }

    var body: some Scene {
        WindowGroup {
            LockGateView()
                .environmentObject(lockManager)
                .environmentObject(cloudAccount)
                .onOpenURL { url in Task { await cloudAccount.handleLink(url) } }
        }
        .modelContainer(modelContainer)
    }
}
