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
    @State private var correctionRevision = 0
    @State private var correctionError: String?

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
        .onReceive(NotificationCenter.default.publisher(for: TransactionOperationLearning.didChange)) { _ in
            correctionRevision += 1
        }
        .task(id: "\(modelContext.container.configurations.first?.url.absoluteString ?? "")|\(scenePhase == .active)|\(correctionRevision)") {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                do {
                    _ = try await TransactionOperationLearning.applyLearnedCorrections(in: modelContext) {
                        scenePhase == .active && !showingQuickAdd && !hasPresentedWindow
                    }
                } catch {
                    if !Task.isCancelled { correctionError = "No se pudo aplicar una corrección aprendida. Puedes revisar los movimientos manualmente." }
                    return
                }
                do { try await Task.sleep(for: .seconds(20)) }
                catch { return }
            }
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
