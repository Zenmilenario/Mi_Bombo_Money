import SwiftData
import SwiftUI

@main
struct MiPatrimonioApp: App {
    private let modelContainer = PersistenceController.shared
    @StateObject private var lockManager = AppLockManager()

    var body: some Scene {
        WindowGroup {
            LockGateView()
                .environmentObject(lockManager)
        }
        .modelContainer(modelContainer)
    }
}
