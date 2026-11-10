import SwiftData
import SwiftUI

struct PersonalBankConnectionsView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var account: CloudAccountManager
    @EnvironmentObject private var banking: PersonalBankingCoordinator
    @EnvironmentObject private var lock: AppLockManager
    @Query(sort: \FinancialAccount.sortOrder) private var accounts: [FinancialAccount]
    @Query private var transactions: [FinancialTransaction]
    @Query private var snapshots: [BalanceSnapshot]
    @State private var server = ""
    @State private var search = ""
    @State private var showBankCatalogue = false
    @State private var busy = false
    @State private var error: String?
    @State private var selection: LinkingSelection?
    @State private var disconnecting: ConnectedBankSession?
    @State private var choices: [String: PersonalBankingPlan.Choice] = [:]
    @State private var manualBalanceText: [UUID: String] = [:]
    @State private var manualBalanceDay: [UUID: Date] = [:]
    @State private var showSuggestions = true
    @State private var showPrepared = true
    @State private var bankToRefreshAfterLink: String?
    @State private var tradeRepublicWarning: ConnectedBank?
    @State private var bankToAuthorizeAfterWarning: ConnectedBank?
    @State private var browser = BankingBrowserAuthorization()
    @State private var operation: Task<Void, Never>?

    private struct LinkingSelection: Identifiable {
        let connection: ConnectedBankSession
        let remote: ConnectedBankAccount
        var id: String { remote.id }
    }
    private var bankQuery: String {
        search.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var body: some View {
        ScrollViewReader { scroll in
            connectionsList(scroll: scroll)
        }
    }
    private func connectionsList(scroll: ScrollViewProxy) -> some View {
        List {
            Section {
                Label("Tus bancos, en tus finanzas", systemImage: "building.columns.circle.fill").font(.headline)
                Text("Recibe saldos y movimientos. La conexión solo consulta información; no permite realizar pagos.")
                    .foregroundStyle(.secondary)
                Text(banking.message).font(.callout)
                if let message = banking.errorMessage { Text(message).foregroundStyle(AppDesign.expense) }
                if banking.pendingPlan != nil {
                    Button("Revisar e incorporar la descarga recibida") {
                        withAnimation { scroll.scrollTo("personal-bank-review", anchor: .top) }
                    }
                    Text("Los movimientos de la primera descarga aparecerán en Movimientos cuando confirmes su incorporación.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Servidor de conexión personal") {
                Button("Comprobar conexión") { run { try await banking.configure(server: server, account: account) } }
                Text("Usa el servidor de producción preparado para tu cuenta cloud. No necesitas introducir una clave del servidor ni contraseñas bancarias aquí.")
                    .font(.caption).foregroundStyle(.secondary)
                if AppEdition.isPersonal {
                    DisclosureGroup("Detalles del servidor") { Text(server).font(.caption).textSelection(.enabled) }
                }
            }
            if !banking.connections.isEmpty {
                Section {
                    Button { run { _ = await banking.synchronize(account: account, context: context, force: true); choices = [:] } } label: {
                        Label("Actualizar movimientos bancarios", systemImage: "arrow.clockwise")
                    }
                    .disabled(banking.pendingPlan != nil)
                    Text("Al abrir la app, se actualiza cada banco cuando le toca. Tras una descarga correcta, se espera al menos seis horas para la siguiente consulta automática.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(banking.connections) { connection in
                Section(connection.bank) {
                    if let status = banking.bankStatus[connection.bank] {
                        Text(status.summary).font(.callout)
                        if let error = status.errorMessage { Text(error).font(.caption).foregroundStyle(AppDesign.expense) }
                        if let retry = status.retryAt, retry > .now {
                            Label("\(status.retryIsAutomatic ? "Próxima consulta automática" : "Próximo intento"): \(retry.formatted(date: .abbreviated, time: .shortened))", systemImage: "clock")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if let next = banking.nextAutomaticRefresh(for: connection.bank), next > .now {
                            Label("Actualización automática a partir de \(next.formatted(date: .abbreviated, time: .shortened))", systemImage: "clock")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if status.deferredTransfers > 0 {
                            Text("\(status.deferredTransfers) apuntes de transferencias propias pendientes de la otra cuenta. No se contabilizan como ingresos ni gastos. Se comprobarán de nuevo en próximas descargas.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(connection.accounts) { remote in
                        let linked = linkedAccount(remote)
                        Button { selection = LinkingSelection(connection: connection, remote: remote) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: linked == nil ? "link.badge.plus" : "checkmark.circle.fill")
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("•••• \(remote.lastFour) · \(remote.currency)")
                                    Text(linked?.name ?? "Asociar con una cuenta de la app").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }.disabled(linked != nil || remote.currency != "EUR")
                    }
                    Text("Permiso válido hasta \(connection.validUntil.prefix(10)).").font(.caption).foregroundStyle(.secondary)
                    ForEach(connection.accounts) { remote in
                        // Diagnostic of what the bank sent: a developer tool, only in the personal edition.
                        if AppEdition.isPersonal, let activity = banking.activity(forAccount: remote.id),
                           let recent = activity.recentMovements {
                            DisclosureGroup {
                                if recent.isEmpty {
                                    Text("El banco no envió apuntes contabilizados en el periodo consultado.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                ForEach(Array(recent.enumerated()), id: \.offset) { _, movement in
                                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                                        Text(PersonalBankingError.displayDate(movement.bookingDate))
                                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                            .frame(width: 78, alignment: .leading)
                                        Text(TransactionPresentation.listTitle(movement.description, isBanking: true))
                                            .font(.caption).lineLimit(1)
                                        Spacer(minLength: 6)
                                        PrivacyAmountText(minorUnits: movement.signedAmountMinor, currencyCode: movement.currency,
                                                          font: .caption, weight: .semibold, signed: true)
                                    }
                                }
                                if let ignored = activity.ignoredStatuses, !ignored.isEmpty {
                                    Label {
                                        Text("El banco también envió " + ignored.sorted { $0.key < $1.key }
                                            .map { "\($0.value) \(Self.statusName($0.key))" }.joined(separator: ", ")
                                            + ". La app no los incorpora porque el banco no los da por contabilizados.")
                                    } icon: { Image(systemName: "exclamationmark.circle") }
                                    .font(.caption).foregroundStyle(AppDesign.warning)
                                }
                                Text("Es lo que envió el banco en la consulta del \(activity.observedAt.formatted(date: .abbreviated, time: .shortened)), contabilizado y sin retenidos. Si un pago de tu banco no aparece aquí, el banco aún no lo ha comunicado.")
                                    .font(.caption2).foregroundStyle(.secondary)
                            } label: {
                                Label("Últimos apuntes recibidos de •••• \(remote.lastFour) (\(activity.receivedCount ?? recent.count))",
                                      systemImage: "tray.and.arrow.down")
                                    .font(.subheadline)
                            }
                        }
                    }
                    Button { run {
                        _ = await banking.synchronize(account: account, context: context, force: true, onlyBank: connection.bank)
                        choices = [:]
                    } } label: {
                        Label("Actualizar solo \(connection.bank)", systemImage: "arrow.clockwise")
                    }
                    .disabled(banking.pendingPlan != nil)
                    Button("Desconectar \(connection.bank)", role: .destructive) { disconnecting = connection }
                }
            }
            if let plan = banking.pendingPlan {
                reviewSection(plan)
            }
            if let message = banking.catalogueErrorMessage {
                Section { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            if !banking.banks.isEmpty {
                Section("Conectar o renovar un banco") {
                    TextField("Buscar por nombre del banco", text: $search)
                        .autocorrectionDisabled()
                    if bankQuery.isEmpty {
                        DisclosureGroup("Ver bancos disponibles (\(banking.banks.count))", isExpanded: $showBankCatalogue) {
                            ForEach(banking.banks) { bank in bankRow(bank) }
                        }
                    } else {
                        let matches = banking.banks.filter { $0.name.localizedStandardContains(bankQuery) }
                        if matches.isEmpty {
                            Label("No hay bancos disponibles con ese nombre.", systemImage: "magnifyingglass")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(matches) { bank in bankRow(bank) }
                    }
                }
            }
            Section {
                Text("Los movimientos nuevos se guardan en esta copia personal y se sincronizan con Supabase al cerrar esta pantalla. Los pagos ya registrados conservan su categoría y el dinero reservado que hayas utilizado.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Mis bancos")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(busy || banking.busy)
        .overlay { if busy || banking.busy { ProgressView().padding().background(.regularMaterial, in: Capsule()) } }
        .task {
            if let owner = account.session?.user.id {
                let saved = banking.savedServer(owner: owner)
                server = saved.isEmpty ? "https://" + BankingConnectionPolicy.personalServerHost : saved
                if !saved.isEmpty { run { try await banking.refresh(account: account) } }
            }
        }
        .onDisappear { operation?.cancel() }
        .onChange(of: banking.pendingPlan != nil) { _, hasPlan in
            if !hasPlan { manualBalanceText = [:]; manualBalanceDay = [:] }
        }
        .sheet(item: $selection, onDismiss: {
            if let bank = bankToRefreshAfterLink {
                bankToRefreshAfterLink = nil
                run { try await banking.connectionCompleted(bank: bank, account: account, context: context) }
            }
        }) { item in
            NavigationStack {
                List {
                    Section {
                        Text("\(item.connection.bank) · •••• \(item.remote.lastFour)").font(.headline)
                        Text("Elige la cuenta que ya utilizas para conservar sus reservas y movimientos. Se incorporará el saldo contable del banco al actualizar.")
                    }
                    Section("Cuentas existentes") {
                        ForEach(accounts.filter { !$0.isArchived && $0.bankIdentityKey == nil && $0.currencyCode == item.remote.currency && !$0.type.isLiability && $0.type != .investment }) { local in
                            Button { link(item, to: local) } label: {
                                Label(local.institution.map { "\($0.name) · \(local.name)" } ?? local.name, systemImage: local.type.systemImage)
                            }
                        }
                    }
                    Section {
                        Button("Crear una cuenta nueva") { link(item, to: nil) }
                        Text("Una cuenta de efectivo de un bróker no incluye el valor de sus acciones o ETF.").font(.caption)
                    }
                }
                .navigationTitle("Asociar cuenta")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { selection = nil } } }
            }
        }
        .sheet(item: $tradeRepublicWarning, onDismiss: {
            if let bank = bankToAuthorizeAfterWarning {
                bankToAuthorizeAfterWarning = nil
                authorize(bank)
            }
        }) { bank in
            ScrollView {
                SectionCard("Conecta Trade Republic con un QR") {
                    Text("Abre la conexión en el iPad y ten a mano el móvil en el que usas Trade Republic.")
                    Label("En la página de Trade Republic, abre el menú superior y elige «Solicitar sitio web de escritorio».",
                          systemImage: "1.circle.fill")
                    Label("Deja abierta esa página y escanea el QR con la cámara del móvil. Confirma en la app de Trade Republic que quieres compartir tu cuenta con Enable Banking.",
                          systemImage: "2.circle.fill")
                    Label("Vuelve a Mis bancos y asocia la cuenta de efectivo con la que ya usas en Doblón.",
                          systemImage: "3.circle.fill")
                    Text("La cámara que necesitas es la del móvil que escanea el QR. Si la verificación se bloquea también allí, contacta con atención al cliente desde Ayuda en Trade Republic.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Continuar con Trade Republic") {
                        bankToAuthorizeAfterWarning = bank
                        tradeRepublicWarning = nil
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Volver a Mis bancos") { tradeRepublicWarning = nil }
                        .buttonStyle(.bordered)
                }
                .padding()
            }
            .background(AppDesign.pageBackground)
            .presentationDetents([.medium, .large])
        }
        .confirmationDialog("¿Desconectar este banco? Se revocará el permiso; tus movimientos guardados se conservan.", isPresented: Binding(isPresent: $disconnecting), titleVisibility: .visible) {
            if let connection = disconnecting {
                Button("Desconectar", role: .destructive) { run(protected: true) {
                    let client = try await banking.client(account: account)
                    try await client.disconnect(connection)
                    banking.disconnected(); try await banking.refresh(account: account)
                } }
            }
        }
        .alert("Conexión bancaria", isPresented: Binding(isPresent: $error)) {
            Button("Aceptar", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }
    private func bankRow(_ bank: ConnectedBank) -> some View {
        Button {
            if bank.name.caseInsensitiveCompare("Trade Republic") == .orderedSame {
                tradeRepublicWarning = bank
            } else {
                authorize(bank)
            }
        } label: {
            HStack {
                Label(bank.name, systemImage: "building.columns.fill")
                Spacer()
                if bank.beta { Text("Beta").font(.caption) }
            }
        }
    }
    private func authorize(_ bank: ConnectedBank) {
        run(protected: true) {
            let client = try await banking.client(account: account)
            let authorization = try await client.start(bank: bank)
            try await browser.authorize(authorization)
            try await banking.connectionCompleted(bank: bank.name, account: account, context: context)
        }
    }
    @ViewBuilder private func reviewSection(_ plan: PersonalBankingPlan) -> some View {
        let unresolved = plan.unresolvedItems(choices)
        let suggested = unresolved.filter { item in
            item.suggestedMatch.map { plan.canMatch(item, to: $0, choices: choices) } == true
        }
        let manual = unresolved.filter { item in !suggested.contains { $0.id == item.id } }
        let now = Date.now
        let enteredBalances = manualBalances(for: plan, at: now)
        let previews = enteredBalances.flatMap { amounts in
            try? PersonalBankingImporter.balanceReviews(plan, choices: choices, manualBalances: amounts,
                accounts: accounts, transactions: transactions, snapshots: snapshots, at: now)
        }
        Section("Revisar descarga bancaria") {
            Text("\(plan.items.count) movimientos recibidos. Todavía no se han guardado los cambios de esta consulta.")
                .font(.callout)
                .id("personal-bank-review")
            LabeledContent("Nuevos", value: "\(plan.items.filter { choices[$0.id] == .new || ($0.candidates.isEmpty && choices[$0.id] == nil) }.count)")
            LabeledContent("Reconocidos automáticamente", value: "\(plan.items.filter { $0.automaticMatch != nil }.count)")
            LabeledContent("Asociaciones preparadas por ti", value: "\(choices.values.filter { if case .match = $0 { return true }; return false }.count)")
            LabeledContent("Propuestas por confirmar", value: "\(suggested.count)")
            LabeledContent("Dudas por resolver", value: "\(manual.count)")
            if plan.alreadyImported > 0 {
                LabeledContent("Ya importados en consultas anteriores", value: "\(plan.alreadyImported)")
            }
            if plan.requiresReferenceReview {
                Text("Trade Republic envía algunos apuntes sin referencia bancaria. Comprueba la fecha y el importe antes de incorporarlos. Los apuntes iguales pueden ser pagos distintos.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Asociar conserva tu movimiento, su categoría, reserva y relación con cargos periódicos. No lo reemplaza ni lo duplica.")
                .font(.caption).foregroundStyle(.secondary)
            if !suggested.isEmpty {
                DisclosureGroup("Comparar \(suggested.count) coincidencias propuestas", isExpanded: $showSuggestions) {
                    Text("Compara los registros antes de aceptar. Las propuestas no se aplican automáticamente.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Aceptar las \(suggested.count) propuestas mostradas") {
                        choices = plan.acceptingSuggestions(choices)
                    }
                    ForEach(suggested) { item in comparisonRow(item, plan: plan) }
                }
            }
            ForEach(manual) { item in comparisonRow(item, plan: plan) }
            DisclosureGroup("Ver nuevos y decisiones preparadas", isExpanded: $showPrepared) {
                ForEach(plan.items.filter { item in !unresolved.contains { $0.id == item.id } }) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        bankMovement(item)
                        if let decision = choices[item.id] ?? item.automaticMatch.map({ .match($0) }),
                           case .match(let id) = decision, let existing = transactions.first(where: { $0.id == id }) {
                            Text(item.automaticMatch == nil ? "Asociación preparada por ti" : "Coincidencia automática de cuenta, importe, día y concepto")
                                .font(.caption).foregroundStyle(.secondary)
                            existingMovement(existing)
                        } else { Text("Se añadirá como nuevo").font(.caption).foregroundStyle(.secondary) }
                        if choices[item.id] != nil {
                            Button("Revisar decisión") { choices.removeValue(forKey: item.id) }
                        }
                    }.padding(.vertical, 8)
                }
            }
            if !unresolved.isEmpty {
                Text("Quedan \(unresolved.count) decisiones. Las coincidencias reconocidas y los movimientos nuevos ya están preparados.")
                    .font(.caption)
            }
            ForEach(plan.balanceGaps) { gap in
                balanceReview(gap, preview: previews?.first { $0.account == gap.id }, now: now)
            }
            Button("Incorporar descarga revisada") {
                guard let enteredBalances, let previews else { return }
                do {
                    try banking.confirm(choices: choices, manualBalances: enteredBalances, reviewedBalances: previews,
                        account: account, context: context)
                    choices = [:]
                }
                catch { self.error = error.localizedDescription }
            }
            .disabled(previews == nil || (try? plan.resolutions(choices)) == nil)
            Button("Descartar esta descarga sin incorporarla") {
                banking.discardPending(); choices = [:]
            }
        }
    }
    private func manualBalances(for plan: PersonalBankingPlan, at date: Date) -> [UUID: PersonalBankingImporter.ManualBalance]? {
        var result: [UUID: PersonalBankingImporter.ManualBalance] = [:]
        for gap in plan.balanceGaps {
            let input = manualBalanceText[gap.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !input.isEmpty else { continue }
            guard let amount = MoneyParser.minorUnits(from: input),
                  (-1_000_000_000_000_000...1_000_000_000_000_000).contains(amount),
                  let interval = Calendar.current.dateInterval(of: .day, for: manualBalanceDay[gap.id] ?? lastClosedDay(at: date)),
                  interval.end <= date else { return nil }
            let cutoff = interval.end.addingTimeInterval(-0.001)
            result[gap.id] = .init(amount: amount, date: cutoff)
        }
        return result
    }

    private func lastClosedDay(at date: Date) -> Date {
        Calendar.current.startOfDay(for: date).addingTimeInterval(-1)
    }

    @ViewBuilder private func balanceReview(_ gap: PersonalBankingPlan.BalanceGap,
                                            preview: PersonalBankingImporter.BalanceReview?, now: Date) -> some View {
        let name = accounts.first { $0.id == gap.id }?.name ?? "Trade Republic"
        let hasSnapshot = snapshots.contains { $0.account?.id == gap.id && $0.date <= now }
        VStack(alignment: .leading, spacing: 8) {
            Text("Saldo de \(name)").font(.headline)
            Text("Trade Republic no ha enviado un saldo contable verificable. Revisa cómo afectarán los movimientos al saldo calculado en la app.")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Tipos de saldo recibidos") {
                Text(gap.diagnostics).font(.caption).foregroundStyle(.secondary)
            }
            if !hasSnapshot {
                Text("La app parte del saldo inicial de la cuenta. Si tienes un saldo más fiable, puedes introducirlo aquí.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Saldo de referencia en euros (opcional)", text: Binding(
                    get: { manualBalanceText[gap.id, default: ""] }, set: { manualBalanceText[gap.id] = $0 }))
                    .keyboardType(.numbersAndPunctuation)
                if !manualBalanceText[gap.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let latestDay = lastClosedDay(at: now)
                    DatePicker("Fecha del saldo", selection: Binding(get: { manualBalanceDay[gap.id] ?? latestDay },
                        set: { manualBalanceDay[gap.id] = $0 }), in: ...latestDay, displayedComponents: .date)
                    Text("Usa el saldo al cierre del día elegido. Los movimientos ya incluidos en ese saldo se guardan en el historial.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let preview {
                LabeledContent("Saldo calculado ahora", value: MoneyFormatter.string(minorUnits: preview.current))
                LabeledContent("Saldo calculado tras importar", value: MoneyFormatter.string(minorUnits: preview.projected))
                Text("Fecha de referencia: \(preview.baseDate.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("El cálculo estará disponible cuando resuelvas las coincidencias y el saldo manual, si lo has introducido, sea válido.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func bankMovement(_ item: PersonalBankingPlan.Item) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Del banco · \(item.kind == "transfer" ? "Transferencia" : item.kind == "expense" ? "Gasto" : "Ingreso")", systemImage: "building.columns")
                .font(.caption).foregroundStyle(.secondary)
            Text(TransactionPresentation.title(item.text, isBanking: true)).font(.headline).fixedSize(horizontal: false, vertical: true)
            if TransactionPresentation.title(item.text, isBanking: true) != item.text {
                DisclosureGroup("Ver concepto del banco") { Text(item.text).font(.caption).textSelection(.enabled) }
            }
            HStack {
                Text(item.date, style: .date)
                Spacer()
                PrivacyAmountText(minorUnits: item.kind == "expense" ? -item.amount : item.amount, currencyCode: "EUR", signed: true)
            }.font(.subheadline)
            if let source = accounts.first(where: { $0.id == item.source }) {
                Text(source.bankAndAccountDisplayName).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func existingMovement(_ candidate: FinancialTransaction) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(candidate.displayDescription).font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(candidate.date, style: .date)
                Spacer()
                PrivacyAmountText(minorUnits: candidate.type == .expense || candidate.type == .fee ? -candidate.amountMinor : candidate.amountMinor,
                                  currencyCode: "EUR", signed: true)
            }.font(.caption)
            Text(candidate.type.title + (candidate.category.map { " · " + $0.name } ?? ""))
                .font(.caption).foregroundStyle(.secondary)
            if candidate.type == .transfer, let destination = candidate.destinationAccount {
                Label("Destino: \(destination.bankAndAccountDisplayName)", systemImage: "arrow.left.arrow.right")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if (candidate.reservedAmountMinor ?? 0) > 0 {
                Label("Pago con dinero reservado · se conserva", systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func comparisonRow(_ item: PersonalBankingPlan.Item, plan: PersonalBankingPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            bankMovement(item)
            if let reason = item.suggestionReason, item.suggestedMatch != nil {
                Label(reason, systemImage: "sparkle").font(.caption).foregroundStyle(.secondary)
            }
            Text("¿Ya lo habías registrado?").font(.subheadline.weight(.semibold))
            ForEach(item.candidates, id: \.self) { id in
                if let candidate = transactions.first(where: { $0.id == id }) {
                    Button { choices[item.id] = .match(id) } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "link")
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.suggestedMatch == id ? "Propuesta · asociar con este registro" : "Asociar con este registro")
                                    .font(.caption.weight(.semibold)).foregroundStyle(.tint)
                                existingMovement(candidate)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!plan.canMatch(item, to: id, choices: choices))
                    if !plan.canMatch(item, to: id, choices: choices) {
                        Text("Este registro ya está asociado a otro movimiento de la descarga.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Button { choices[item.id] = .new } label: {
                Label("Es otro movimiento: añadir como nuevo", systemImage: "plus.circle")
            }.buttonStyle(.borderless)
        }.padding(.vertical, 10)
    }
    private func linkedAccount(_ remote: ConnectedBankAccount) -> FinancialAccount? {
        guard let server = URL(string: server) else { return nil }
        return accounts.first { $0.bankIdentityKey == PersonalBankingImporter.identity(server: server, accountID: remote.id) }
    }
    private func link(_ item: LinkingSelection, to local: FinancialAccount?) {
        do {
            guard let server = URL(string: server) else { throw BankingConnectionError.invalidConfiguration }
            try PersonalBankingImporter.link(item.remote, bank: item.connection.bank, server: server, to: local, in: context)
            bankToRefreshAfterLink = item.connection.bank
            selection = nil
        } catch { self.error = error.localizedDescription; selection = nil }
    }
    /// Readable name of a bank entry status the app does not import.
    static func statusName(_ code: String) -> String {
        switch code {
        case "CNCL": "cancelados"
        case "RJCT": "rechazados"
        case "INFO": "informativos"
        case "SCHD": "programados"
        case "NONE": "sin estado"
        default: "con estado \(code)"
        }
    }

    private func run(protected: Bool = false, _ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        operation = Task { @MainActor in
            defer { busy = false }
            do {
                if protected { try await lock.withProtectedAction(action) }
                else { try await action() }
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}
