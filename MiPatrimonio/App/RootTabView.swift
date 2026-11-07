import Combine
import SwiftData
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

private enum AppTab: Hashable {
    case home
    case transactions
    case accounts
    case budgets
    case settings
}

struct RootTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query private var accounts: [FinancialAccount]
    @State private var selectedTab: AppTab = .home
    @State private var selectedMonth = Date.now.startOfMonth()
    @State private var showingQuickAdd = false
    @State private var recurrenceError: String?
    @State private var correctionError: String?

    private let mayApplyLearning: @MainActor () -> Bool

    init(mayApplyLearning: @escaping @MainActor () -> Bool = { true }) {
        self.mayApplyLearning = mayApplyLearning
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView(
                selectedMonth: $selectedMonth,
                onOpenTransactions: {
                    selectedTab = .transactions
                },
                onOpenAccounts: {
                    selectedTab = .accounts
                },
                onOpenBudgets: {
                    selectedTab = .budgets
                },
                onOpenSettings: {
                    selectedTab = .settings
                },
                onAddMovement: {
                    showingQuickAdd = true
                }
            )
            .tag(AppTab.home)
            .tabItem {
                Label("Inicio", systemImage: "house")
            }

            TransactionsView()
                .safeAreaInset(edge: .bottom, alignment: .trailing, spacing: 0) {
                    quickAddButton
                }
                .tag(AppTab.transactions)
                .tabItem {
                    Label(
                        "Movimientos",
                        systemImage: "list.bullet.rectangle"
                    )
                }

            AccountsView()
                .tag(AppTab.accounts)
                .tabItem {
                    Label(
                        "Cuentas",
                        systemImage: "building.columns"
                    )
                }

            BudgetsView(selectedMonth: $selectedMonth)
                .tag(AppTab.budgets)
                .tabItem {
                    Label(
                        "Presupuestos",
                        systemImage: "chart.pie"
                    )
                }

            SettingsView()
                .tag(AppTab.settings)
                .tabItem {
                    Label(
                        "Ajustes",
                        systemImage: "gearshape"
                    )
                }
        }
        .modifier(AdaptiveTabNavigationStyle())
        .accentColor(AppDesign.accent)
        .animation(
            .easeInOut(duration: 0.18),
            value: selectedTab
        )
        .sheet(isPresented: $showingQuickAdd) {
            TransactionFormView()
        }
        .task { _ = await TransactionLearning.models(in: modelContext) }
        .task(id: "\(modelContext.container.configurations.first?.url.absoluteString ?? "")|\(scenePhase == .active)") {
            await listenForCorrectionEvents()
        }
        .onAppear(perform: postDueMovements)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { postDueMovements() }
        }
        .alert("No se pudo registrar un movimiento periódico", isPresented: Binding(
            get: { recurrenceError != nil },
            set: { if !$0 { recurrenceError = nil } }
        )) {
            Button("Aceptar", role: .cancel) { recurrenceError = nil }
        } message: {
            Text(recurrenceError ?? "Error desconocido")
        }
        .alert("Correcciones aprendidas", isPresented: Binding(
            get: { correctionError != nil }, set: { if !$0 { correctionError = nil } }
        )) { Button("Aceptar", role: .cancel) { correctionError = nil } }
        message: { Text(correctionError ?? "") }
    }

    @ViewBuilder
    private var quickAddButton: some View {
        if accounts.contains(where: { !$0.isArchived }) {
            Button {
                showingQuickAdd = true
            } label: {
                Image(systemName: "plus")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(AppDesign.actionFill, in: Circle())
                    .shadow(
                        color: .black.opacity(0.18),
                        radius: 9,
                        y: 5
                    )
            }
            .accessibilityLabel("Añadir movimiento")
            .padding(.trailing, 18)
            .padding(.bottom, 12)
            .transition(
                .scale.combined(with: .opacity)
            )
        }
    }

    private func postDueMovements() {
        do {
            try RecurringMovementService.postDueMovements(in: modelContext)
        } catch {
            recurrenceError = error.localizedDescription
        }
    }

    @MainActor
    private var canApplyCorrections: Bool {
        scenePhase == .active && !showingQuickAdd && !hasPresentedWindow && !modelContext.hasChanges && mayApplyLearning()
    }

    @MainActor
    private func listenForCorrectionEvents() async {
        guard scenePhase == .active, let configuration = modelContext.container.configurations.first,
              ["LocalFinance", "CloudFinance"].contains(configuration.name) else { return }
        let storeURL = configuration.url
        // A nil selection checks outstanding candidates after reopening or new human feedback.
        let (events, queue) = AsyncStream<Set<UUID>?>.makeStream()
        let imports = NotificationCenter.default.publisher(for: BankingMovementCommit.notification).sink { notification in
            guard let commit = notification.object as? BankingMovementCommit, commit.storeURL == storeURL else { return }
            queue.yield(commit.transactionIDs)
        }
        let feedback = NotificationCenter.default.publisher(for: TransactionOperationLearning.didChange).sink { notification in
            guard notification.object as? URL == storeURL else { return }
            queue.yield(nil)
        }
        defer {
            imports.cancel()
            feedback.cancel()
            queue.finish()
        }
        queue.yield(nil)

        for await transactionIDs in events {
            do {
                while !Task.isCancelled {
                    if canApplyCorrections && !TransactionOperationLearning.isApplyingCorrections(in: modelContext) {
                        _ = try await TransactionOperationLearning.applyLearnedCorrections(in: modelContext, transactionIDs: transactionIDs) {
                            canApplyCorrections
                        }
                        if canApplyCorrections { break }
                    }
                    // Only pending work waits for a form or a save to finish.
                    try await Task.sleep(for: .seconds(1))
                }
            } catch is CancellationError { return }
            catch {
                if !Task.isCancelled { correctionError = "No se pudo aplicar una corrección aprendida. Puedes revisar los movimientos manualmente." }
            }
        }
    }

    private var hasPresentedWindow: Bool {
        #if canImport(UIKit)
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) where scene.activationState == .foregroundActive {
            for window in scene.windows where window.isKeyWindow {
                if let presented = window.rootViewController?.presentedViewController,
                   presented.isViewLoaded, presented.view.window != nil, !presented.isBeingDismissed { return true }
            }
        }
        #endif
        return false
    }
}

private struct AdaptiveTabNavigationStyle: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.tabViewStyle(.sidebarAdaptable)
        } else {
            content
        }
    }
}
