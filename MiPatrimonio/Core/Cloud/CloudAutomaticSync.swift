import Foundation

/// Changing these inputs restarts the SwiftUI task with current environment values.
struct CloudAutomaticSyncState: Equatable {
    let ready: Bool
    let foreground: Bool
    let unlocked: Bool
    let authenticated: Bool

    var canRun: Bool { ready && foreground && unlocked && authenticated }
}

enum CloudAutomaticSync {
    @MainActor
    static func run(
        state: CloudAutomaticSyncState,
        interval: Duration = .seconds(15),
        maySynchronize: @MainActor () -> Bool,
        synchronize: @MainActor () async -> Void
    ) async {
        guard state.canRun else { return }
        while !Task.isCancelled {
            // Presentation state is read on every tick, rather than captured when the task starts.
            if maySynchronize() { await synchronize() }
            do { try await Task.sleep(for: interval) }
            catch { return }
        }
    }
}
