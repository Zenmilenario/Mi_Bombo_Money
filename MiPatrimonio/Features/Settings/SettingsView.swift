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
                Section("Privacidad y seguridad") {
                    Toggle(isOn: $appLockEnabled) {
                        Label("Face ID o código", systemImage: "faceid")
                    }
                    Toggle(isOn: $hideAmounts) {
                        Label("Ocultar importes", systemImage: "eye.slash")
                    }
                    Picker(selection: $appearanceMode) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Text(appearance.title).tag(appearance.rawValue)
                        }
                    } label: {
                        Label("Apariencia", systemImage: "circle.lefthalf.filled")
                    }
                    LabeledContent {
                        Text("Solo local")
                            .foregroundStyle(.secondary)
                    } label: {
                        Label("Almacenamiento", systemImage: "iphone")
                    }
                    LabeledContent {
                        Text("Completa")
                            .foregroundStyle(.secondary)
                    } label: {
                        Label("Protección de archivos", systemImage: "lock.shield")
                    }
                } footer: {
                    Text("El MVP desactiva CloudKit, protege el almacén cuando el iPhone está bloqueado e incluye cifrado AES-GCM con claves en Keychain para secretos o exportaciones. No almacena contraseñas bancarias.")
                }

                Section("Datos") {
                    NavigationLink {
                        CSVImportView()
                    } label: {
                        Label("Importar CSV bancario", systemImage: "square.and.arrow.down")
                    }

                    HStack {
                        Label("Importación Excel", systemImage: "tablecells")
                        Spacer()
                        Text("Fase 2")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    LabeledContent("Cuentas", value: "\(accounts.count)")
                    LabeledContent("Movimientos", value: "\(transactions.count)")
                    LabeledContent("Tarjetas", value: "\(cards.count)")
                    LabeledContent("Entidades", value: "\(institutions.count)")
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
                        Label("Periódicos y suscripciones", systemImage: "repeat.circle")
                    }
                }

                Section("Acerca del MVP") {
                    LabeledContent("Persistencia", value: "SwiftData")
                    LabeledContent("Interfaz", value: "SwiftUI")
                    LabeledContent("Gráficos", value: "Swift Charts")
                    LabeledContent("Versión", value: "0.1")
                }
            }
            .navigationTitle("Ajustes")
        }
    }
}
