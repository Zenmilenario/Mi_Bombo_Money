import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct SecurityCredentialsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var lockManager: AppLockManager

    @State private var isConfigured = UserAuthService.isConfigured
    @State private var currentUsername = UserAuthService.storedUsername ?? ""
    @State private var lastLoginDate: Date?

    // Setup fields
    @State private var newUsername = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var isPasswordVisible = false

    // Change password fields
    @State private var currentPasswordInput = ""
    @State private var updatedPasswordInput = ""
    @State private var confirmUpdatedPasswordInput = ""
    @State private var isCurrentPasswordVisible = false
    @State private var isUpdatedPasswordVisible = false

    // Feedback
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var showingDeleteConfirmation = false

    private var accentColor: Color {
        Color(hex: "#176B87")
    }

    var body: some View {
        Form {
            if isConfigured {
                currentAccountSection
                changePasswordSection
                dangerZoneSection
            } else {
                setupSection
            }

            infoSection
        }
        .navigationTitle("Acceso por usuario")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            refreshProfile()
        }
        .confirmationDialog(
            "Eliminar credenciales",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Eliminar usuario y contraseña", role: .destructive) {
                deleteCredentials()
            }
        } message: {
            Text("Ya no podrás iniciar sesión con usuario y contraseña. El acceso se realizará mediante Face ID, Touch ID o el código de tu iPhone.")
        }
    }

    // MARK: - Sections

    private var currentAccountSection: some View {
        Section("Cuenta actual") {
            LabeledContent {
                Text(currentUsername)
                    .fontWeight(.medium)
            } label: {
                Label("Usuario", systemImage: "person.circle.fill")
            }

            if let lastLoginDate {
                LabeledContent {
                    Text(lastLoginDate, style: .date)
                } label: {
                    Label("Último acceso", systemImage: "clock")
                }
            }
        }
    }

    private var changePasswordSection: some View {
        Section("Cambiar contraseña") {
            HStack {
                if isCurrentPasswordVisible {
                    TextField("Contraseña actual", text: $currentPasswordInput)
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                } else {
                    SecureField("Contraseña actual", text: $currentPasswordInput)
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                }

                Button {
                    isCurrentPasswordVisible.toggle()
                } label: {
                    Image(systemName: isCurrentPasswordVisible ? "eye.slash.fill" : "eye.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            HStack {
                if isUpdatedPasswordVisible {
                    TextField("Nueva contraseña (mínimo 10 caracteres)", text: $updatedPasswordInput)
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                } else {
                    SecureField("Nueva contraseña (mínimo 10 caracteres)", text: $updatedPasswordInput)
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                }

                Button {
                    isUpdatedPasswordVisible.toggle()
                } label: {
                    Image(systemName: isUpdatedPasswordVisible ? "eye.slash.fill" : "eye.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            SecureField("Confirmar nueva contraseña", text: $confirmUpdatedPasswordInput)
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(.never)

            if let error = errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            if let message = statusMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.green)
            }

            Button {
                savePasswordChange()
            } label: {
                HStack {
                    Spacer()
                    Text("Actualizar contraseña")
                        .fontWeight(.semibold)
                    Spacer()
                }
            }
            .disabled(currentPasswordInput.isEmpty || updatedPasswordInput.isEmpty || confirmUpdatedPasswordInput.isEmpty)
        }
    }

    private var setupSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Crea un usuario y contraseña para acceder a tus finanzas como método alternativo o principal a Face ID / Touch ID.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)

            TextField("Nombre de usuario", text: $newUsername)
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(.never)

            HStack {
                if isPasswordVisible {
                    TextField("Contraseña (mínimo 10 caracteres)", text: $newPassword)
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                } else {
                    SecureField("Contraseña (mínimo 10 caracteres)", text: $newPassword)
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                }

                Button {
                    isPasswordVisible.toggle()
                } label: {
                    Image(systemName: isPasswordVisible ? "eye.slash.fill" : "eye.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            SecureField("Confirmar contraseña", text: $confirmPassword)
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(.never)

            if let error = errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Button {
                registerCredentials()
            } label: {
                HStack {
                    Spacer()
                    Text("Configurar credenciales")
                        .fontWeight(.semibold)
                    Spacer()
                }
            }
            .disabled(newUsername.trimmingCharacters(in: .whitespaces).isEmpty || newPassword.count < 10)
        } header: {
            Text("Configurar usuario y contraseña")
        }
    }

    private var dangerZoneSection: some View {
        Section {
            Button(role: .destructive) {
                showingDeleteConfirmation = true
            } label: {
                Label("Eliminar usuario y contraseña", systemImage: "trash")
            }
        } footer: {
            Text("Al eliminar las credenciales, la app solicitará únicamente biometría o el código del iPhone para desbloquear.")
        }
    }

    private var infoSection: some View {
        Section {
            Label("Las credenciales se guardan de forma local en el Llavero seguro (Keychain) de este iPhone.", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
            Label("Nunca se transmiten por internet ni se almacenan en servidores externos.", systemImage: "icloud.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Seguridad y Privacidad")
        }
    }

    // MARK: - Actions

    private func refreshProfile() {
        isConfigured = UserAuthService.isConfigured
        if let profile = try? UserAuthService.profile() {
            currentUsername = profile.username
            lastLoginDate = profile.lastLoginAt
        }
    }

    private func registerCredentials() {
        errorMessage = nil
        statusMessage = nil

        guard newPassword == confirmPassword else {
            errorMessage = "Las contraseñas no coinciden."
            return
        }

        do {
            try UserAuthService.register(username: newUsername, password: newPassword)
            #if canImport(UIKit)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            #endif
            refreshProfile()
            newPassword = ""
            confirmPassword = ""
        } catch {
            #if canImport(UIKit)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            #endif
            errorMessage = error.localizedDescription
        }
    }

    private func savePasswordChange() {
        errorMessage = nil
        statusMessage = nil

        guard updatedPasswordInput == confirmUpdatedPasswordInput else {
            errorMessage = "Las nuevas contraseñas no coinciden."
            return
        }

        do {
            try UserAuthService.changePassword(
                oldPassword: currentPasswordInput,
                newPassword: updatedPasswordInput
            )
            #if canImport(UIKit)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            #endif
            statusMessage = "Contraseña actualizada correctamente."
            currentPasswordInput = ""
            updatedPasswordInput = ""
            confirmUpdatedPasswordInput = ""
        } catch {
            #if canImport(UIKit)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            #endif
            errorMessage = error.localizedDescription
        }
    }

    private func deleteCredentials() {
        Task { @MainActor in
            guard await lockManager.authenticate() else { return }
            do {
                try UserAuthService.removeCredentials()
                refreshProfile()
            } catch { errorMessage = error.localizedDescription }
        }
    }
}
