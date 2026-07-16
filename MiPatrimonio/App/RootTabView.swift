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
    @State private var selectedTab: AppTab = .home
    @State private var showingQuickAdd = false
    @State private var seedError: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                DashboardView()
                    .tag(AppTab.home)
                    .tabItem { Label("Inicio", systemImage: "house") }

                TransactionsView()
                    .tag(AppTab.transactions)
                    .tabItem { Label("Movimientos", systemImage: "list.bullet.rectangle") }

                AccountsView()
                    .tag(AppTab.accounts)
                    .tabItem { Label("Cuentas", systemImage: "building.columns") }

                BudgetsView()
                    .tag(AppTab.budgets)
                    .tabItem { Label("Presupuestos", systemImage: "chart.pie") }

                SettingsView()
                    .tag(AppTab.settings)
                    .tabItem { Label("Ajustes", systemImage: "gearshape") }
            }

            Button {
                showingQuickAdd = true
            } label: {
                Image(systemName: "plus")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .background(.tint, in: Circle())
                    .shadow(radius: 8, y: 4)
                    .accessibilityLabel("Añadir movimiento")
            }
            .offset(y: -54)
        }
        .sheet(isPresented: $showingQuickAdd) {
            TransactionFormView()
        }
        .task {
            do {
                try WorkbookSeedData.seedIfNeeded(in: modelContext)
            } catch {
                seedError = error.localizedDescription
            }
        }
        .alert("No se pudieron cargar los datos iniciales", isPresented: Binding(
            get: { seedError != nil },
            set: { if !$0 { seedError = nil } }
        )) {
            Button("Aceptar", role: .cancel) { seedError = nil }
        } message: {
            Text(seedError ?? "Error desconocido")
        }
    }
}
