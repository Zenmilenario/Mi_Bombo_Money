import Combine
import SwiftData
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

private enum AppTab: Hashable, CaseIterable {
    case home
    case transactions
    case accounts
    case budgets
    case settings

    var title: String {
        switch self {
        case .home: "Inicio"
        case .transactions: "Movimientos"
        case .accounts: "Cuentas"
        case .budgets: "Presupuestos"
        case .settings: "Ajustes"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .transactions: "list.bullet.rectangle"
        case .accounts: "building.columns"
        case .budgets: "chart.pie"
        case .settings: "gearshape"
        }
    }
}

struct RootTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
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
        navigation
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

    /// iPad and wide windows: a slim rail that never covers the content. iPhone: the usual tab bar.
    @ViewBuilder
    private var navigation: some View {
        if horizontalSizeClass == .regular {
            HStack(spacing: 0) {
                NavigationRail(selection: $selectedTab, canAdd: accounts.contains(where: { !$0.isArchived })) {
                    showingQuickAdd = true
                }
                ZStack {
                    // All five stay alive, as in a TabView, so each keeps its scroll position and navigation.
                    ForEach(AppTab.allCases, id: \.self) { tab in
                        screen(tab)
                            .opacity(selectedTab == tab ? 1 : 0)
                            .allowsHitTesting(selectedTab == tab)
                            .accessibilityHidden(selectedTab != tab)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(AppDesign.pageBackground)
            .overlay(alignment: .bottomTrailing) {
                CompanionView(currentTab: selectedTab, bottomInset: 20) { selectedTab = $0 }
            }
        } else {
            TabView(selection: $selectedTab) {
                ForEach(AppTab.allCases, id: \.self) { tab in
                    screen(tab)
                        .safeAreaInset(edge: .bottom, alignment: .trailing, spacing: 0) {
                            if tab == .transactions { quickAddButton }
                        }
                        .tag(tab)
                        .tabItem { Label(tab.title, systemImage: tab.systemImage) }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                CompanionView(currentTab: selectedTab, bottomInset: selectedTab == .transactions ? 140 : 64) { selectedTab = $0 }
            }
        }
    }

    @ViewBuilder
    private func screen(_ tab: AppTab) -> some View {
        switch tab {
        case .home:
            DashboardView(
                selectedMonth: $selectedMonth,
                onOpenTransactions: { selectedTab = .transactions },
                onOpenAccounts: { selectedTab = .accounts },
                onOpenBudgets: { selectedTab = .budgets },
                onOpenSettings: { selectedTab = .settings },
                onAddMovement: { showingQuickAdd = true }
            )
        case .transactions: TransactionsView()
        case .accounts: AccountsView()
        case .budgets: BudgetsView(selectedMonth: $selectedMonth)
        case .settings: SettingsView()
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


/// iPad navigation: logo, the five sections and the add button, in a narrow column beside the content.
private struct NavigationRail: View {
    @Binding var selection: AppTab
    let canAdd: Bool
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Text("D")
                .font(.system(size: 18, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(AppDesign.actionFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.bottom, 14)
                .accessibilityLabel("Doblón")
            ForEach(AppTab.allCases, id: \.self) { tab in
                let isSelected = selection == tab
                Button { selection = tab } label: {
                    VStack(spacing: 5) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 19, weight: .medium))
                        Text(tab.title)
                            .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .foregroundStyle(isSelected ? AppDesign.accent : Color.secondary)
                    .frame(width: 70, height: 58)
                    .background(isSelected ? AppDesign.accent.opacity(0.13) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
            Spacer(minLength: 12)
            if canAdd {
                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                        .frame(width: 50, height: 50)
                        .background(AppDesign.actionFill, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Añadir movimiento")
            }
        }
        .padding(.vertical, 18)
        .frame(width: 86)
        .frame(maxHeight: .infinity)
        .background(AppDesign.railBackground.ignoresSafeArea())
        .overlay(alignment: .trailing) {
            Rectangle().fill(AppDesign.cardOutline).frame(width: 1).ignoresSafeArea()
        }
    }
}

// MARK: - Don Bigotes, the companion

/// Something Don Bigotes noticed in the person's own data. Facts about the data, never advice.
private struct CompanionNote: Identifiable {
    let id: String
    let kind: String
    let title: String
    let detail: String
    let systemImage: String
    let tab: AppTab
}

/// Lives in a corner. Asleep and tucked into the edge when it has nothing to say; awake with a
/// «Púlsame» when it does. It never interrupts: nothing happens until the person taps it.
private struct CompanionView: View {
    @Environment(\.bankAccountActivity) private var bankActivity
    @Query private var transactions: [FinancialTransaction]
    @Query private var accounts: [FinancialAccount]
    @Query(sort: \RecurringMovement.nextDueDate) private var recurring: [RecurringMovement]
    @AppStorage("companionEnabled") private var enabled = true
    @AppStorage("companionLevel") private var level = "discreto"
    @AppStorage("companionMemoryV1") private var memoryJSON = ""
    @State private var showingNotes = false

    let currentTab: AppTab
    let bottomInset: CGFloat
    let open: (AppTab) -> Void

    private var allNotes: [CompanionNote] {
        var notes: [CompanionNote] = []
        let holds = BankHold.all(accounts: accounts, activity: bankActivity).filter { $0.movement.signedAmountMinor < 0 }
        if !holds.isEmpty {
            let total = holds.reduce(Int64.zero) { $0 + $1.movement.signedAmountMinor }
            notes.append(CompanionNote(id: "holds:" + holds.map(\.id).sorted().joined(separator: ","), kind: "holds",
                title: holds.count == 1 ? "1 cargo en camino" : "\(holds.count) cargos en camino",
                detail: "Retenidos por el banco · \(MoneyFormatter.string(minorUnits: total))",
                systemImage: "hourglass", tab: .transactions))
        }
        let review = transactions.filter { !TransactionReviewService.issues(for: $0).isEmpty }
        if !review.isEmpty {
            notes.append(CompanionNote(id: "review:\(review.count):" + (review.map(\.id.uuidString).max() ?? ""), kind: "review",
                title: review.count == 1 ? "1 movimiento por revisar" : "\(review.count) movimientos por revisar",
                detail: "Posibles duplicados o sin categoría",
                systemImage: "checklist", tab: .transactions))
        }
        let soon = Date.now.addingTimeInterval(3 * 86_400)
        if let next = recurring.first(where: { $0.isActive && $0.nextDueDate >= Calendar.current.startOfDay(for: .now) && $0.nextDueDate <= soon }) {
            notes.append(CompanionNote(id: "recurring:\(next.id.uuidString):\(next.nextDueDate.timeIntervalSince1970)", kind: "recurring",
                title: "Cargo previsto: \(next.name)",
                detail: "\(next.nextDueDate.formatted(.dateTime.weekday(.wide).day())) · \(MoneyFormatter.string(minorUnits: next.amountMinor))",
                systemImage: "calendar", tab: .settings))
        }
        let limit = Date.now.addingTimeInterval(-30 * 86_400)
        let stale = accounts.filter { !$0.isArchived && $0.bankIdentityKey == nil && $0.lastUpdatedAt < limit }
        if !stale.isEmpty {
            notes.append(CompanionNote(id: "stale:" + stale.map(\.id.uuidString).sorted().joined(separator: ","), kind: "stale",
                title: stale.count == 1 ? "1 cuenta sin actualizar" : "\(stale.count) cuentas sin actualizar",
                detail: "Más de 30 días con el mismo saldo",
                systemImage: "clock", tab: .accounts))
        }
        return notes
    }

    private var notes: [CompanionNote] {
        let memory = CompanionMemory(serialized: memoryJSON)
        return allNotes.filter { memory.shows(id: $0.id, kind: $0.kind) }
    }

    var body: some View {
        if enabled {
            let current = notes
            let awake = !current.isEmpty
            HStack(spacing: 8) {
                if awake && level != "callado" {
                    Button { showingNotes = true } label: {
                        HStack(spacing: 7) {
                            Circle().fill(AppDesign.warning).frame(width: 8, height: 8)
                            Text(teaser(current)).lineLimit(1)
                        }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AppDesign.pageBackground)
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .background(Color.primary, in: UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18,
                                                                                bottomTrailingRadius: 4, topTrailingRadius: 18))
                        .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
                    }
                    .buttonStyle(.plain)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                Button { showingNotes = true } label: {
                    DonBigotesMark(awake: awake, size: awake ? 40 : 34)
                        .frame(width: 54, height: 54)
                        .background(awake ? AppDesign.cardBackground : AppDesign.tertiaryBackground, in: Circle())
                        .overlay(alignment: .topTrailing) {
                            if awake && level == "callado" {
                                Text("\(current.count)")
                                    .font(.caption2.weight(.heavy))
                                    .foregroundStyle(.black)
                                    .frame(minWidth: 18, minHeight: 18)
                                    .background(AppDesign.warning, in: Capsule())
                            }
                        }
                        .shadow(color: .black.opacity(awake ? 0.2 : 0), radius: 9, y: 5)
                        .rotationEffect(.degrees(awake ? 0 : -12))
                        .opacity(awake ? 1 : 0.6)
                        .offset(x: awake ? 0 : 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(awake ? "Don Bigotes tiene \(current.count == 1 ? "algo" : "\(current.count) cosas") que contarte" : "Don Bigotes, sin novedades")
            }
            .padding(.trailing, awake ? 16 : 0)
            .padding(.bottom, bottomInset)
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: awake)
            .sheet(isPresented: $showingNotes) {
                CompanionNotesSheet(notes: current) { note in
                    showingNotes = false
                    open(note.tab)
                } dismiss: { note in
                    var memory = CompanionMemory(serialized: memoryJSON)
                    memory.dismiss(id: note.id, kind: note.kind)
                    memory.forget(except: Set(allNotes.map(\.id)))
                    memoryJSON = memory.serialized
                }
                .presentationDetents([.medium, .large])
            }
        }
    }

    private func teaser(_ notes: [CompanionNote]) -> String {
        if level == "hablador", let first = notes.first { return first.title }
        return notes.count == 1 ? "Púlsame: tengo un aviso" : "Púlsame: tengo \(notes.count) cosas"
    }
}

private struct CompanionNotesSheet: View {
    let notes: [CompanionNote]
    let go: (CompanionNote) -> Void
    let dismiss: (CompanionNote) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        DonBigotesMark(awake: !notes.isEmpty, size: 52)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(notes.isEmpty ? "Todo en orden" : "Lo que he visto").font(.title3.bold())
                            Text(notes.isEmpty ? "No hay nada pendiente. Vuelvo a mi esquina." : "Solo cosas tuyas, nada urgente.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.bottom, 4)
                    ForEach(notes) { note in
                        HStack(spacing: 12) {
                            RowGlyph(systemImage: note.systemImage, tint: note.kind == "holds" ? AppDesign.warning : AppDesign.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(note.title).font(.subheadline.weight(.semibold))
                                Text(note.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Button("Ahora no") { withAnimation { dismiss(note) } }
                                .font(.caption.weight(.semibold))
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                            Button("Ver") { go(note) }
                                .font(.caption.weight(.bold))
                                .buttonStyle(.borderedProminent)
                                .tint(AppDesign.actionFill)
                        }
                        .padding(12)
                        .financeCardSurface()
                    }
                    if notes.isEmpty { DailyQuoteCard() }
                    Text("Puedes elegir cuánto habla, o apagarlo, en Ajustes › A tu gusto.")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
                .padding(20)
            }
            .background(AppDesign.pageBackground)
            .navigationTitle("Don Bigotes")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
