import SwiftData
import SwiftUI

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
    @State private var showingQuickAdd = false
    @State private var recurrenceError: String?

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView(
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
                }
            )
            .safeAreaInset(edge: .bottom, alignment: .trailing, spacing: 0) {
                quickAddButton
            }
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

            BudgetsView()
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

        .animation(
            .easeInOut(duration: 0.18),
            value: selectedTab
        )
        .sheet(isPresented: $showingQuickAdd) {
            TransactionFormView()
        }
        .onAppear(perform: postDueTransfers)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { postDueTransfers() }
        }
        .alert("No se pudo registrar la aportación periódica", isPresented: Binding(
            get: { recurrenceError != nil },
            set: { if !$0 { recurrenceError = nil } }
        )) {
            Button("Aceptar", role: .cancel) { recurrenceError = nil }
        } message: {
            Text(recurrenceError ?? "Error desconocido")
        }
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
                    .background(.tint, in: Circle())
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

    private func postDueTransfers() {
        do {
            try RecurringMovementService.postDueTransfers(in: modelContext)
        } catch {
            recurrenceError = error.localizedDescription
        }
    }
}
