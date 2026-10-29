import SwiftData
import SwiftUI

@main
struct MiPatrimonioApp: App {
    private let modelContainer = PersistenceController.shared
    @StateObject private var lockManager = AppLockManager()
    @StateObject private var cloudAccount = CloudAccountManager()

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
