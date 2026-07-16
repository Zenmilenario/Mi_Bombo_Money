import SwiftData
import SwiftUI

struct SettingsView: View {
    @AppStorage("hideAmounts") private var hideAmounts = false
    @AppStorage("appLockEnabled") private var appLockEnabled = true
    @AppStorage("appearanceMode") private var appearanceMode = AppAppearance.system.rawValue

    @Query private var accounts: [FinancialAccount]
    @Query private var transactions: [FinancialTransaction]
    @Query private var cards: [PaymentCard]
    @Query private var institutions: [FinancialInstitution]

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
                        Label("Datos guardados en este iPhone", systemImage: "internaldrive")
                    }

                    LabeledContent {
                        Text("Próximamente")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } label: {
                        Label("Importar archivos Excel", systemImage: "tablecells")
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
                        GoalsView()
                    } label: {
                        Label("Objetivos de ahorro", systemImage: "target")
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
                    message: "Usa el botón azul para anotar ingresos, gastos, intereses, comisiones o transferencias."
                )

                HelpStepRow(
                    number: 3,
                    title: "Define presupuestos",
                    message: "Asigna un límite mensual a las categorías que quieras controlar."
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
