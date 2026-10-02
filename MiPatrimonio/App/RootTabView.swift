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
    @Query private var accounts: [FinancialAccount]
    @State private var selectedTab: AppTab = .home
    @State private var showingQuickAdd = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
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
                .tag(AppTab.home)
                .tabItem {
                    Label("Inicio", systemImage: "house")
                }

                TransactionsView()
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

            if accounts.contains(where: { !$0.isArchived })
                && (selectedTab == .home || selectedTab == .transactions) {
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
                .padding(.bottom, 76)
                .transition(
                    .scale.combined(with: .opacity)
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
    }
}
