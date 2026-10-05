import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage("hideAmounts") private var hideAmounts = false
    @AppStorage("appLockEnabled") private var appLockEnabled = true
    @AppStorage("appearanceMode") private var appearanceMode = AppAppearance.system.rawValue

    @Query private var accounts: [FinancialAccount]
    @Query private var transactions: [FinancialTransaction]
    @Query private var cards: [PaymentCard]
    @Query private var institutions: [FinancialInstitution]
    @State private var showingResetConfirmation = false
    @State private var resetError: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(isOn: $appLockEnabled) {
                        Label("Face ID o código", systemImage: "faceid")
                    }

                    Toggle(isOn: $hideAmounts) {
                        Label("Ocultar importes", systemImage: "eye.slash")
                    }
                } header: {
                    Text("Seguridad")
                } footer: {
                    Text("La aplicación puede bloquearse al salir y ocultar todas las cantidades en listas y gráficos.")
                }

                Section("Apariencia") {
                    Picker(selection: $appearanceMode) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Text(appearance.title).tag(appearance.rawValue)
                        }
                    } label: {
                        Label("Tema", systemImage: "circle.lefthalf.filled")
                    }

                    LabeledContent {
                        Text("Euro (EUR)")
                            .foregroundStyle(.secondary)
                    } label: {
                        Label("Moneda principal", systemImage: "eurosign.circle")
                    }
                }

                Section("Datos") {
                    NavigationLink {
                        BackupView()
                    } label: {
                        Label("Copia de seguridad", systemImage: "externaldrive")
                    }

                    NavigationLink {
                        CSVImportView()
                    } label: {
                        Label("Importar movimientos", systemImage: "square.and.arrow.down")
                    }

                    NavigationLink {
                        LocalDataSummaryView(
                            accountCount: accounts.count,
                            transactionCount: transactions.count,
                            cardCount: cards.count,
                            institutionCount: institutions.count
                        )
                    } label: {
                        Label("Datos guardados en este dispositivo", systemImage: "internaldrive")
                    }

                    LabeledContent {
                        Text("Próximamente")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } label: {
                        Label("Importar archivos Excel", systemImage: "tablecells")
                    }

                    Button(role: .destructive) {
                        showingResetConfirmation = true
                    } label: {
                        Label("Empezar desde cero", systemImage: "trash")
                    }
                }

                Section("Organización") {
                    NavigationLink {
                        InstitutionsView()
                    } label: {
                        Label("Bancos y entidades", systemImage: "building.columns")
                    }

                    NavigationLink {
                        CategoriesView()
                    } label: {
                        Label("Categorías", systemImage: "tag")
                    }

                    NavigationLink {
                        CategoryRulesView()
                    } label: {
                        Label("Reglas de categorías", systemImage: "text.magnifyingglass")
                    }

                    NavigationLink {
                        GoalsView()
                    } label: {
                        Label("Objetivos de ahorro", systemImage: "target")
                    }

                    NavigationLink {
                        ReservedFundsView()
                    } label: {
                        Label("Dinero reservado", systemImage: "lock.circle")
                    }

                    NavigationLink {
                        RecurringMovementsView()
                    } label: {
                        Label("Movimientos recurrentes", systemImage: "repeat.circle")
                    }
                }

                Section("Información") {
                    NavigationLink {
                        PrivacyInformationView()
                    } label: {
                        Label("Privacidad y protección de datos", systemImage: "hand.raised")
                    }

                    NavigationLink {
                        AppHelpView()
                    } label: {
                        Label("Ayuda", systemImage: "questionmark.circle")
                    }

                    LabeledContent {
                        Text(appVersion)
                            .foregroundStyle(.secondary)
                    } label: {
                        Label("Versión", systemImage: "info.circle")
                    }
                }
            }
            .navigationTitle("Ajustes")
        }
        .confirmationDialog(
            "Empezar desde cero",
            isPresented: $showingResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Eliminar mis datos", role: .destructive) {
                clearAllData()
            }
        } message: {
            Text("Se eliminarán cuentas, movimientos, categorías personalizadas, presupuestos y demás datos locales. Las categorías comunes volverán a aparecer. Esta acción no se puede deshacer.")
        }
        .alert("No se pudieron eliminar los datos", isPresented: Binding(
            get: { resetError != nil },
            set: { if !$0 { resetError = nil } }
        )) {
            Button("Aceptar", role: .cancel) { resetError = nil }
        } message: {
            Text(resetError ?? "Error desconocido")
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
            CategoryDefaultsService.insertDefaults(in: modelContext)
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
        return version ?? build ?? "0.2"
    }
}

private struct LocalDataSummaryView: View {
    let accountCount: Int
    let transactionCount: Int
    let cardCount: Int
    let institutionCount: Int

    var body: some View {
        List {
            Section("Contenido") {
                LabeledContent("Cuentas", value: "\(accountCount)")
                LabeledContent("Movimientos", value: "\(transactionCount)")
                LabeledContent("Tarjetas", value: "\(cardCount)")
                LabeledContent("Bancos y entidades", value: "\(institutionCount)")
            }

            Section {
                Label("Los datos se guardan localmente en este iPhone.", systemImage: "iphone")
                Label("No se almacenan contraseñas bancarias.", systemImage: "key.slash")
                Label("Los archivos quedan protegidos cuando el dispositivo está bloqueado.", systemImage: "lock.shield")
            } header: {
                Text("Protección")
            } footer: {
                Text("Al eliminar la aplicación también se eliminan sus datos locales. Las copias de seguridad cifradas se incorporarán en una versión posterior.")
            }
        }
        .navigationTitle("Datos locales")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PrivacyInformationView: View {
    var body: some View {
        List {
            Section {
                PrivacyInfoRow(
                    title: "Funciona sin conexión",
                    message: "Puedes consultar y registrar tu información sin depender de un servidor externo.",
                    systemImage: "wifi.slash"
                )

                PrivacyInfoRow(
                    title: "Sin credenciales bancarias",
                    message: "La aplicación no solicita ni almacena usuarios, contraseñas, PIN o CVV.",
                    systemImage: "key.slash"
                )

                PrivacyInfoRow(
                    title: "Acceso protegido",
                    message: "Puedes exigir Face ID, Touch ID o el código del dispositivo para abrir la aplicación.",
                    systemImage: "faceid"
                )

                PrivacyInfoRow(
                    title: "Importes ocultables",
                    message: "El botón del ojo oculta cantidades y gráficos cuando necesitas más privacidad.",
                    systemImage: "eye.slash"
                )
            }

            Section {
                Text("Las futuras conexiones bancarias utilizarán APIs oficiales y autorización segura. Nunca se incorporarán campos para guardar contraseñas bancarias.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Conexiones bancarias futuras")
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
                    message: "Usa el botón azul para anotar movimientos. Puedes recordar una categoría para descripciones habituales."
                )

                HelpStepRow(
                    number: 3,
                    title: "Define presupuestos",
                    message: "Asigna límites mensuales y decide si se repiten y qué hacer con el sobrante."
                )

                HelpStepRow(
                    number: 4,
                    title: "Revisa tus objetivos",
                    message: "Crea metas de ahorro y consulta su progreso desde Ajustes."
                )
            }

            Section("Conceptos importantes") {
                LabeledContent("Transferencias propias") {
                    Text("No cuentan como ingreso ni gasto")
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Saldo de una cuenta") {
                    Text("Saldo inicial + movimientos + valoraciones")
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
                .background(Color.accentColor, in: Circle())

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
