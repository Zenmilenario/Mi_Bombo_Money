import AppIntents
import Combine
import SwiftData
import SwiftUI

private enum SettingsRoute: CaseIterable, Equatable {
    case cloud, banks, cardPayments, categories, rules, recurring, institutions, goals, reserves
    case backup, csv, credentials, sandbox, privacy, help

    private var details: (String, String, String) {
        switch self {
        case .cloud: ("Mi nube", "Cuenta y sincronización", "cloud")
        case .banks: ("Mis bancos", "Conectar, actualizar y revisar movimientos", "building.columns.circle")
        case .cardPayments: ("Pagos con Apple Pay", "Apunta cada pago al momento con Atajos", "creditcard")
        case .categories: ("Categorías", "", "tag")
        case .rules: ("Categorización automática", "Reglas para reconocer conceptos habituales", "text.magnifyingglass")
        case .recurring: ("Cargos y aportaciones periódicas", "Suscripciones, ingresos y transferencias", "repeat.circle")
        case .institutions: ("Bancos y entidades de la app", "Nombres, colores y tarjetas", "building.columns")
        case .goals: ("Objetivos de ahorro", "", "target")
        case .reserves: ("Dinero reservado", "También disponible desde Cuentas", "lock.circle")
        case .backup: ("Exportar o restaurar copia", "Guarda todos tus datos o recupera una copia", "externaldrive")
        case .csv: ("Importar movimientos CSV", "Añade un extracto desde Archivos", "square.and.arrow.down")
        case .credentials: ("Usuario y contraseña local", "Desbloqueo en este dispositivo", "person.badge.key")
        case .sandbox: ("Laboratorio bancario", "Sandbox y demostración con datos de prueba", "testtube.2")
        case .privacy: ("Privacidad y protección de datos", "", "hand.raised")
        case .help: ("Cómo usar la app", "", "questionmark.circle")
        }
    }
    var title: String { details.0 }
    var subtitle: String { details.1 }
    var systemImage: String { details.2 }
    var searchTerms: String {
        let aliases: String
        switch self {
        case .cloud: aliases = "cloud correo sesión sincronizar conexión activar nube"
        case .banks: aliases = "enable banking conectar banco permisos conciliación cuentas movimientos automáticos"
        case .cardPayments: aliases = "atajos shortcuts siri wallet tarjeta transacción automatización pendiente trade republic"
        case .rules: aliases = "reglas categorías categorizar"
        case .recurring: aliases = "movimientos recurrentes mensual recibos suscripción"
        case .backup: aliases = "copia seguridad JSON cifrada contraseña recuperar respaldo"
        case .csv: aliases = "importación fichero archivo extracto"
        case .credentials: aliases = "seguridad acceso contraseña usuario local"
        case .sandbox: aliases = "pruebas probar demo desarrollo sandbox"
        case .goals: aliases = "metas ahorro"
        case .reserves: aliases = "reservas apartar fondos"
        case .institutions: aliases = "colores color tarjetas"
        case .help: aliases = "ayuda primeros pasos versión información soporte"
        default: aliases = ""
        }
        return title + " " + subtitle + " " + aliases
    }
}

private struct SettingsRouteLabel: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .foregroundStyle(AppDesign.accent)
                .frame(width: 32, height: 32)
                .background(AppDesign.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).foregroundStyle(.primary)
                if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            .fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 3)
    }
}

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.isBankingTestWorkspace) private var isBankingTestWorkspace
    @Environment(\.isCloudWorkspace) private var isCloudWorkspace
    @AppStorage("cloudAccountModeEnabled") private var cloudMode = false
    @AppStorage("hideAmounts") private var hideAmounts = false
    @AppStorage("companionEnabled") private var companionEnabled = true
    @AppStorage("companionLevel") private var companionLevel = "discreto"
    @AppStorage("companionMemoryV1") private var companionMemory = ""
    @AppStorage("appLockEnabled") private var appLockEnabled = true
    @AppStorage("autoPromptBiometrics") private var autoPromptBiometrics = false
    @AppStorage("appearanceMode") private var appearanceMode = AppAppearance.system.rawValue
    @AppStorage("companionFocus") private var companionFocus = ""
    @State private var showingCardPayments = false

    @Query private var accounts: [FinancialAccount]
    @Query private var transactions: [FinancialTransaction]
    @Query private var cards: [PaymentCard]
    @Query private var institutions: [FinancialInstitution]
    @State private var showingResetConfirmation = false
    @State private var resetError: String?

    @State private var searchText = ""
    @State private var moreToolsExpanded = false
    @State private var securityExpanded = false
    @State private var advancedExpanded = false
    @State private var helpExpanded = false

    private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var availableRoutes: [SettingsRoute] {
        SettingsRoute.allCases.filter { route in
            if isBankingTestWorkspace && [.cloud, .banks, .cardPayments, .backup, .csv, .sandbox].contains(route) { return false }
            return true
        }
    }
    private func matches(_ words: String) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let text = words.folding(options: options, locale: .current)
        let query = searchText.folding(options: options, locale: .current).split(whereSeparator: \.isWhitespace)
        return query.allSatisfy { text.contains($0) }
    }
    private func shows(_ route: SettingsRoute) -> Bool {
        availableRoutes.contains(route) && matches(route.searchTerms)
    }
    private func showsAny(_ routes: [SettingsRoute]) -> Bool { routes.contains(where: shows) }
    private var showsPreferences: Bool {
        matches("apariencia tema claro oscuro automático") || matches("privacidad ocultar importes cantidades")
            || matches(Self.companionKeywords)
    }
    private static let companionKeywords = "don bigotes gato compañero avisos asistente"
    private var showsSecurity: Bool { matches("seguridad bloqueo desbloqueo biometría Face ID Touch ID huella") || shows(.credentials) }
    private var showsStorage: Bool { matches("almacenamiento datos guardados dispositivo cuentas movimientos tarjetas entidades") }
    private var showsReset: Bool { matches("eliminar borrar restablecer empezar desde cero datos") }
    private var hasResults: Bool {
        availableRoutes.contains(where: shows) || showsPreferences || showsSecurity || showsStorage || showsReset
    }
    private func expansion(_ stored: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { isSearching || stored.wrappedValue }, set: { stored.wrappedValue = $0 })
    }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        container
        .confirmationDialog(
            isBankingTestWorkspace ? "Eliminar datos de prueba" : "Eliminar todos los datos financieros",
            isPresented: $showingResetConfirmation,
            titleVisibility: .visible
        ) {
            Button(isBankingTestWorkspace ? "Eliminar datos de prueba" : "Eliminar mis datos", role: .destructive) {
                clearAllData()
            }
            Button("Cancelar", role: .cancel) { }
        } message: {
            Text(isBankingTestWorkspace
                ? "Se eliminarán los datos de este espacio de pruebas. Tus finanzas personales no se modifican."
                : isCloudWorkspace
                ? "Se eliminarán los datos de esta cuenta cloud al sincronizar, también en tus otros dispositivos. Las categorías comunes volverán a aparecer. Exporta una copia antes de continuar."
                : "Se eliminarán cuentas, movimientos, categorías personalizadas, presupuestos y demás datos locales. Las categorías comunes volverán a aparecer. Esta acción no se puede deshacer.")
        }
        .alert("No se pudieron eliminar los datos", isPresented: Binding(isPresent: $resetError)) {
            Button("Aceptar", role: .cancel) { resetError = nil }
        } message: { Text(resetError ?? "Error desconocido") }
    }

    /// iPad: the sections on the left and the chosen one on the right. iPhone: a single stack.
    @ViewBuilder private var container: some View {
        if horizontalSizeClass == .regular {
            NavigationSplitView {
                settingsList
                    .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 440)
            } detail: {
                VStack(spacing: 14) {
                    DonBigotesMark(awake: false, size: 64)
                    Text("Elige un ajuste").font(.title3.weight(.semibold))
                    Text("Aquí verás su detalle.").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppDesign.pageBackground)
            }
            .navigationSplitViewStyle(.balanced)
        } else {
            NavigationStack { settingsList }
        }
    }

    private var settingsList: some View {
            List {
                if !hasResults {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    // Every row, including pickers, toggles and disclosure groups, uses the card colour:
                    // without it those rows keep the system grey and the dark theme looks patchy.
                    Group {
                        connectionSection
                        organizationSection
                        preferencesSection
                        dataSection
                        advancedSection
                        helpSection
                    }
                    .listRowBackground(AppDesign.cardBackground)
                }
            }
            .listStyle(.insetGrouped)
            .cloudSyncToolbar()
            .scrollContentBackground(.hidden)
            .background(AppDesign.pageBackground)
            .navigationTitle("Ajustes")
            .searchable(text: $searchText, prompt: "Buscar en ajustes")
            .navigationDestination(isPresented: $showingCardPayments) { CardPaymentSettingsView() }
            .onAppear(perform: followCompanion)
            .onChange(of: companionFocus) { _, _ in followCompanion() }
    }

    /// Don Bigotes opens «Pagos con Apple Pay» when a payment is waiting for its account.
    private func followCompanion() {
        guard CompanionFocus.parse(companionFocus) == .cardPayments, !isBankingTestWorkspace else { return }
        companionFocus = ""
        showingCardPayments = true
    }

    @ViewBuilder private var connectionSection: some View {
        if isBankingTestWorkspace && !isSearching {
            Section {
                Label("Espacio de pruebas", systemImage: "testtube.2")
                Text("Estos datos están separados de tus finanzas. Usa Volver a mis finanzas para salir.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if showsAny([.cloud, .banks, .cardPayments]) {
            Section("Cuenta y bancos") {
                routeRow(.cloud)
                routeRow(.banks)
                routeRow(.cardPayments)
            }
        }
    }

    @ViewBuilder private var organizationSection: some View {
        if showsAny([.categories, .rules, .recurring, .institutions, .goals, .reserves]) {
            Section("Organiza tus finanzas") {
                routeRow(.categories)
                routeRow(.rules)
                routeRow(.recurring)
                if showsAny([.institutions, .goals, .reserves]) {
                    DisclosureGroup("Más herramientas", isExpanded: expansion($moreToolsExpanded)) {
                        routeRow(.institutions)
                        routeRow(.goals)
                        routeRow(.reserves)
                    }
                }
            }
        }
    }

    @ViewBuilder private var preferencesSection: some View {
        if showsPreferences || showsSecurity {
            Section("A tu gusto") {
                if matches("apariencia tema claro oscuro automático") {
                    Picker(selection: $appearanceMode) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Text(appearance.title).tag(appearance.rawValue)
                        }
                    } label: { Label("Tema", systemImage: "circle.lefthalf.filled") }
                }
                if matches("privacidad ocultar importes cantidades") {
                    Toggle(isOn: $hideAmounts) { Label("Ocultar importes", systemImage: "eye.slash") }
                }
                if matches(Self.companionKeywords) {
                    Toggle(isOn: $companionEnabled) {
                        HStack(spacing: 10) {
                            DonBigotesMark(awake: companionEnabled, size: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Don Bigotes")
                                Text("Te señala cosas tuyas sin interrumpir").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if companionEnabled {
                        Picker("Cuánto habla", selection: $companionLevel) {
                            Text("Callado").tag("callado")
                            Text("Discreto").tag("discreto")
                            Text("Más hablador").tag("hablador")
                        }
                        if !companionMemory.isEmpty {
                            Button("Volver a mostrar los avisos descartados") { companionMemory = "" }
                        }
                    }
                }
                if showsSecurity {
                    DisclosureGroup(isExpanded: expansion($securityExpanded)) {
                        if matches("seguridad bloqueo desbloqueo biometría Face ID Touch ID huella") {
                            Toggle("Bloquear la app al salir", isOn: $appLockEnabled)
                            if appLockEnabled {
                                Toggle("Solicitar Face ID o Touch ID al abrir", isOn: $autoPromptBiometrics)
                            }
                        }
                        routeRow(.credentials)
                        Text("El acceso local desbloquea esta app en el dispositivo. Tu cuenta de la nube se gestiona en Mi nube.")
                            .font(.caption).foregroundStyle(.secondary)
                    } label: { Label("Seguridad y desbloqueo", systemImage: "lock.shield") }
                }
            }
        }
    }

    @ViewBuilder private var dataSection: some View {
        if showsAny([.backup, .csv]) {
            Section("Copias e importación") {
                routeRow(.backup)
                routeRow(.csv)
            }
        }
    }

    @ViewBuilder private var advancedSection: some View {
        if showsStorage || showsReset || shows(.sandbox) {
            Section {
                DisclosureGroup("Opciones avanzadas", isExpanded: expansion($advancedExpanded)) {
                    if showsStorage {
                        LabeledContent("Cuentas", value: "\(accounts.count)")
                        LabeledContent("Movimientos", value: "\(transactions.count)")
                        LabeledContent("Tarjetas", value: "\(cards.count)")
                        LabeledContent("Entidades", value: "\(institutions.count)")
                        Text(isBankingTestWorkspace ? "Este espacio de pruebas está separado de tus finanzas personales."
                            : isCloudWorkspace ? "Esta copia del dispositivo se sincroniza con tu cuenta." : "Estos datos pertenecen al espacio abierto en este dispositivo.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    routeRow(.sandbox)
                    NavigationLink { HitchListView() } label: {
                        SettingsRouteLabel(title: "Fluidez de la app", subtitle: "Pausas recientes al usar la app", systemImage: "speedometer")
                    }
                    if showsReset {
                        Button(role: .destructive) { showingResetConfirmation = true } label: {
                            Label(isBankingTestWorkspace ? "Eliminar datos de prueba" : "Eliminar todos los datos financieros", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var helpSection: some View {
        if showsAny([.help, .privacy]) || !isSearching {
            Section {
                if showsAny([.help, .privacy]) {
                    DisclosureGroup("Ayuda y privacidad", isExpanded: expansion($helpExpanded)) {
                        routeRow(.help)
                        routeRow(.privacy)
                    }
                }
                if !isSearching || matches("acerca de doblón don bigotes versión gato") {
                    NavigationLink { AboutDoblonView(version: appVersion) } label: {
                        SettingsRouteLabel(title: "Acerca de Doblón", subtitle: "Versión \(appVersion) · conoce a Don Bigotes", systemImage: "info.circle")
                    }
                }
            } footer: {
                HStack(spacing: 10) {
                    DonBigotesMark(awake: true, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Doblón · \(appVersion)").font(.footnote.weight(.semibold))
                        Text("Con Don Bigotes, que vigila tus cuentas con traje y sin prisas.").font(.caption)
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    @ViewBuilder private func routeRow(_ route: SettingsRoute) -> some View {
        if shows(route) {
            Group {
                if route == .cloud && !isCloudWorkspace {
                    Button { cloudMode = true } label: {
                        SettingsRouteLabel(title: "Activar mi nube", subtitle: "Accede a tus datos desde tus dispositivos", systemImage: route.systemImage)
                    }
                } else {
                    NavigationLink { destination(route) } label: {
                        SettingsRouteLabel(title: route.title, subtitle: route.subtitle, systemImage: route.systemImage)
                    }
                }
            }
            .listRowBackground(AppDesign.cardBackground)
        }
    }

    @ViewBuilder private func destination(_ route: SettingsRoute) -> some View {
        switch route {
        case .cloud: CloudAccountSettingsView()
        case .banks: BankConnectionsView()
        case .cardPayments: CardPaymentSettingsView()
        case .categories: CategoriesView()
        case .rules: CategoryRulesView()
        case .recurring: RecurringMovementsView()
        case .institutions: InstitutionsView()
        case .goals: GoalsView()
        case .reserves: ReservedFundsView()
        case .backup: BackupView()
        case .csv: CSVImportView()
        case .credentials: SecurityCredentialsView()
        case .sandbox: BankConnectionsView(testOnly: true)
        case .privacy: PrivacyInformationView()
        case .help: AppHelpView()
        }
    }

    private func clearAllData() {
        do {
            try modelContext.delete(model: FinancialTransaction.self)
            try modelContext.delete(model: RecurringMovement.self)
            try modelContext.delete(model: MonthlyBudget.self)
            try modelContext.delete(model: RecurringBudget.self)
            try modelContext.delete(model: CategoryRule.self)
            try modelContext.delete(model: SavingsGoal.self)
            try modelContext.delete(model: ReservedFund.self)
            try modelContext.delete(model: BalanceSnapshot.self)
            try modelContext.delete(model: PaymentCard.self)
            try modelContext.delete(model: ImportBatch.self)
            try modelContext.delete(model: FinancialAccount.self)
            try modelContext.delete(model: FinanceCategory.self)
            try modelContext.delete(model: FinancialInstitution.self)
            CategoryDefaultsService.insertDefaults(in: modelContext, stableIDs: isCloudWorkspace)
            try modelContext.save()
        } catch {
            modelContext.rollback()
            resetError = error.localizedDescription
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String

        if let version, let build, version != build {
            return "\(version) (\(build))"
        }
        return version ?? build ?? "Versión no disponible"
    }
}

private struct PrivacyInformationView: View {
    @Environment(\.isCloudWorkspace) private var isCloudWorkspace
    @Environment(\.isBankingTestWorkspace) private var isBankingTestWorkspace
    var body: some View {
        List {
            Section {
                PrivacyInfoRow(
                    title: "Funciona sin conexión",
                    message: "Puedes consultar y registrar cambios sin conexión. La sincronización con la nube y las consultas al banco necesitan internet.",
                    systemImage: "wifi.slash"
                )

                PrivacyInfoRow(
                    title: "Sin credenciales bancarias",
                    message: "La app no solicita ni almacena contraseñas, PIN o CVV de tus bancos. El acceso cloud usa una cuenta independiente.",
                    systemImage: "key.slash"
                )

                PrivacyInfoRow(
                    title: "Acceso protegido",
                    message: "Puedes bloquear la app al salir y desbloquearla con la autenticación del dispositivo o con tu usuario local.",
                    systemImage: "faceid"
                )

                PrivacyInfoRow(
                    title: isBankingTestWorkspace ? "Datos de prueba separados" : isCloudWorkspace ? "Sincronización activada" : "Almacenamiento local",
                    message: isBankingTestWorkspace
                        ? "Este espacio guarda datos de prueba aparte. No se envían a tu cuenta personal ni se mezclan con sus copias."
                        : isCloudWorkspace
                        ? "Tus datos se envían mediante HTTPS a tu cuenta de Supabase y se conservan también en este dispositivo. Cada usuario tiene su espacio y los cambios sin conexión quedan pendientes."
                        : "Los datos de este modo se guardan en el dispositivo. Puedes conectar una cuenta cloud y elegir explícitamente si quieres copiarlos.",
                    systemImage: "cloud"
                )

                PrivacyInfoRow(
                    title: "Importes ocultables",
                    message: "El botón del ojo oculta cantidades y gráficos cuando necesitas más privacidad.",
                    systemImage: "eye.slash"
                )
            }

            Section {
                Text("Al conectar tus bancos con Enable Banking, autorizas la consulta de cuentas y movimientos desde el flujo del proveedor y del banco. La app no inicia pagos. Los permisos y sesiones se gestionan en el servidor personal; los movimientos que incorporas se guardan en tus finanzas y, en modo cloud, se sincronizan con tu cuenta. Puedes desconectar el banco desde Mis bancos.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("El Laboratorio bancario usa datos de demostración o sandbox y un espacio separado. Sus datos no se incorporan a tus finanzas personales ni a sus copias.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Conexión con tus bancos")
            }
        }
        .navigationTitle("Privacidad")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PrivacyInfoRow: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.headline)
                .foregroundStyle(.tint)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.11), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct AppHelpView: View {
    var body: some View {
        List {
            Section("Primeros pasos") {
                HelpStepRow(
                    number: 1,
                    title: "Añade tus cuentas",
                    message: "Registra cada banco, cuenta, tarjeta, efectivo o inversión desde Cuentas."
                )

                HelpStepRow(
                    number: 2,
                    title: "Registra movimientos",
                    message: "Pulsa Añadir movimiento o el botón +. Si conectas tu banco, revisa la primera descarga desde Mis bancos. Las reglas de categorización reconocen conceptos habituales."
                )

                HelpStepRow(
                    number: 3,
                    title: "Define presupuestos",
                    message: "Asigna límites mensuales y decide si se repiten y qué hacer con el sobrante."
                )

                HelpStepRow(
                    number: 4,
                    title: "Revisa tus objetivos",
                    message: "En Ajustes, despliega Más herramientas para ver objetivos y dinero reservado. También puedes buscar la opción por su nombre."
                )
            }

            Section("Conceptos importantes") {
                LabeledContent("Transferencias propias") {
                    Text("No cuentan como ingreso ni gasto")
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Saldo de una cuenta") {
                    Text("Saldo de referencia y movimientos posteriores")
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Tasa de ahorro") {
                    Text("Ahorro neto dividido entre ingresos")
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Ayuda")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct HelpStepRow: View {
    let number: Int
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(AppDesign.actionFill, in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// About screen: the version, Don Bigotes and the picture that inspired him.
private struct AboutDoblonView: View {
    let version: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Image("DonBigotesFoto")
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 320)
                    .clipShape(RoundedRectangle(cornerRadius: AppDesign.heroRadius, style: .continuous))
                    .accessibilityLabel("Un gato con traje y corbata señalando, el meme que inspiró a Don Bigotes")
                HStack(spacing: 14) {
                    DonBigotesMark(awake: true, size: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Don Bigotes").font(.title2.bold())
                        Text("Vigila tus cuentas con traje y sin prisas.").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Text("Se esconde cuando no tiene nada que contar y despierta cuando ve algo tuyo: un cargo retenido, un movimiento por revisar o un recibo que se acerca. Nunca te dice qué hacer con tu dinero; solo te señala dónde mirar.")
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                DailyQuoteCard()
                LabeledContent("Versión", value: version)
                    .padding(14)
                    .financeCardSurface()
            }
            .padding(20)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(AppDesign.pageBackground)
        .navigationTitle("Acerca de Doblón")
        .navigationBarTitleDisplayMode(.inline)
    }
}


/// Apple Pay payments recorded through the Shortcuts «Transacción» automation: the account of each card
/// and the steps to create the automation.
struct CardPaymentSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FinancialAccount.name) private var accounts: [FinancialAccount]
    @AppStorage(CardPaymentInbox.defaultAccountKey) private var defaultAccount = ""
    @AppStorage(CardPaymentInbox.cardAccountsKey) private var cardAccountsJSON = ""
    @State private var waiting: [CardPayment] = []
    @State private var cards: [String] = []

    private var activeAccounts: [FinancialAccount] {
        accounts.filter { !$0.isArchived && !$0.type.isLiability }
    }

    var body: some View {
        List {
            Section {
                Text("Cada vez que pagas con Apple Pay, Atajos puede apuntar el pago en Doblón al momento. Aparece en Movimientos como «Pendiente del banco» y ya cuenta en tu saldo. Cuando el banco envía ese apunte, Doblón los une solo, sin duplicarlo.")
                    .font(.subheadline)
            }
            Section {
                Picker("Cuenta por defecto", selection: $defaultAccount) {
                    Text("Sin elegir").tag("")
                    ForEach(activeAccounts) { account in
                        Text(account.bankAndAccountDisplayName).tag(account.id.uuidString)
                    }
                }
                ForEach(cards, id: \.self) { card in
                    Picker(card, selection: cardBinding(card)) {
                        Text("La cuenta por defecto").tag("")
                        ForEach(activeAccounts) { account in
                            Text(account.bankAndAccountDisplayName).tag(account.id.uuidString)
                        }
                    }
                }
            } header: {
                Text("Cuenta de cada tarjeta")
            } footer: {
                Text(cards.isEmpty
                     ? "Las tarjetas aparecerán aquí tras su primer pago, para que elijas su cuenta."
                     : "Elige la cuenta de la que sale el dinero de cada tarjeta, por ejemplo la de Trade Republic.")
            }
            if !waiting.isEmpty {
                Section {
                    ForEach(waiting) { payment in
                        LabeledContent {
                            PrivacyAmountText(minorUnits: -payment.amountMinor, currencyCode: "EUR", signed: true)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(payment.merchant.isEmpty ? "Pago con tarjeta" : payment.merchant)
                                Text([payment.card, payment.date.formatted(date: .abbreviated, time: .shortened)]
                                    .filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button("Apuntar ahora", action: fileNow)
                } header: {
                    Text("En espera")
                } footer: {
                    Text("Se apuntan cuando su tarjeta tiene cuenta, la suya propia o la cuenta por defecto.")
                }
            }
            Section {
                step(1, "Abre Atajos › Automatización › Nueva automatización y elige «Transacción».")
                step(2, "Marca las tarjetas que quieras, por ejemplo la de Trade Republic, y elige «Ejecutar inmediatamente».")
                step(3, "Añade la acción «Apuntar pago con tarjeta» de Doblón.")
                step(4, "En Importe, Comercio y Tarjeta elige las variables Importe, Comercio y Tarjeta de la transacción.")
                step(5, "Guarda la automatización. Tras tu próximo pago con Apple Pay, el pago aparecerá en Doblón.")
                ShortcutsLink()
                    .shortcutsLinkStyle(.automaticOutline)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            } header: {
                Text("Crear la automatización")
            } footer: {
                Text("Solo los pagos con Apple Pay o Wallet activan la automatización. Un pago escribiendo los datos de la tarjeta en una web no la activa; puedes apuntarlo diciendo a Siri «Apuntar un pago en Doblón». El pago se guarda solo en este dispositivo hasta que Doblón lo apunta.")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(AppDesign.pageBackground)
        .navigationTitle("Pagos con Apple Pay")
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: CardPaymentInbox.didChange).receive(on: RunLoop.main)) { _ in reload() }
        .onChange(of: defaultAccount) { _, _ in fileNow() }
        .onChange(of: cardAccountsJSON) { _, _ in fileNow() }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)").font(.subheadline.weight(.bold)).foregroundStyle(AppDesign.accent)
            Text(text).font(.subheadline)
        }
    }

    private func cardBinding(_ card: String) -> Binding<String> {
        Binding {
            CardPaymentInbox.decodeRules(cardAccountsJSON)[CardPaymentInbox.normalizedCard(card)]?.uuidString ?? ""
        } set: { value in
            var rules = CardPaymentInbox.decodeRules(cardAccountsJSON)
            rules[CardPaymentInbox.normalizedCard(card)] = UUID(uuidString: value)
            cardAccountsJSON = CardPaymentInbox.encodeRules(rules)
        }
    }

    private func reload() {
        waiting = CardPaymentInbox.load().sorted { $0.date > $1.date }
        var unique: [String] = []
        for card in CardPaymentInbox.seenCards() + waiting.map(\.card) where !card.isEmpty
            && !unique.contains(where: { CardPaymentInbox.normalizedCard($0) == CardPaymentInbox.normalizedCard(card) }) {
            unique.append(card)
        }
        cards = unique
    }

    /// Files what is waiting once a card has an account. Not while another form holds unsaved changes.
    private func fileNow() {
        guard !modelContext.hasChanges else { return }
        CardPaymentFiler.file(into: modelContext)
        reload()
        NotificationCenter.default.post(name: CardPaymentInbox.didChange, object: nil)
    }
}
