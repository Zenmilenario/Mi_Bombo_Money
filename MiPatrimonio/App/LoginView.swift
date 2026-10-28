import LocalAuthentication
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct LoginView: View {
    @EnvironmentObject private var lockManager: AppLockManager
    @Environment(\.colorScheme) private var colorScheme

    private enum LoginTab: String, CaseIterable, Identifiable {
        case credentials = "password"
        case biometrics = "biometrics"

        var id: String { rawValue }
    }

    @State private var selectedTab: LoginTab = UserAuthService.isConfigured ? .credentials : .biometrics
    @State private var isConfigured = UserAuthService.isConfigured

    // Form inputs
    @State private var username = UserAuthService.storedUsername ?? ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var isPasswordVisible = false
    @State private var isConfirmPasswordVisible = false

    // State & Feedback
    @State private var errorMessage: String?
    @State private var isProcessing = false
    @State private var biometricType = AppLockManager.biometricType

    private var accentColor: Color {
        Color(hex: "#176B87")
    }

    var body: some View {
        ZStack {
            // Ambient background
            AppDesign.pageBackground
                .ignoresSafeArea()

            ambientGlowLayer

            ScrollView {
                VStack(spacing: 28) {
                    headerSection
                        .padding(.top, 24)

                    methodSelector
                        .padding(.horizontal, 24)

                    VStack(spacing: 20) {
                        if selectedTab == .credentials {
                            credentialsCard
                        } else {
                            biometricsCard
                        }
                    }
                    .padding(.horizontal, 20)
                    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: selectedTab)
                    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isConfigured)

                    footerPrivacyBadge
                        .padding(.top, 8)
                        .padding(.bottom, 24)
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .onAppear {
            biometricType = AppLockManager.biometricType
            isConfigured = UserAuthService.isConfigured
            if username.isEmpty, let stored = UserAuthService.storedUsername {
                username = stored
            }
        }
    }

    // MARK: - Subviews

    private var ambientGlowLayer: some View {
        VStack {
            Circle()
                .fill(accentColor.opacity(colorScheme == .dark ? 0.18 : 0.08))
                .frame(width: 320, height: 320)
                .blur(radius: 70)
                .offset(y: -80)
            Spacer()
        }
        .ignoresSafeArea()
    }

    private var headerSection: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [accentColor, Color(hex: "#0F2C3A")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 82, height: 82)
                    .shadow(color: accentColor.opacity(0.35), radius: 16, y: 8)

                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(spacing: 6) {
                Text("Mi Bombo Money")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)

                Text("Control financiero privado y seguro")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var methodSelector: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    selectedTab = .credentials
                    errorMessage = nil
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle")
                    Text("Usuario")
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    selectedTab == .credentials
                        ? accentColor
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .foregroundStyle(selectedTab == .credentials ? .white : .secondary)
            }
            .buttonStyle(.plain)

            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    selectedTab = .biometrics
                    errorMessage = nil
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: biometricType.systemImage)
                    Text(biometricType.title)
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    selectedTab == .biometrics
                        ? accentColor
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .foregroundStyle(selectedTab == .biometrics ? .white : .secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(4)
        .background(
            Color(uiColor: .tertiarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }

    // MARK: - Credentials Card

    private var credentialsCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !isConfigured {
                setupBanner
            } else {
                Text("Inicia sesión con tus credenciales")
                    .font(.headline)
                    .foregroundStyle(.primary)
            }

            // Username input
            VStack(alignment: .leading, spacing: 6) {
                Text("Usuario")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Image(systemName: "person.fill")
                        .foregroundStyle(accentColor)
                        .frame(width: 22)

                    TextField("Tu nombre o usuario", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    Color(uiColor: .tertiarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
            }

            // Password input
            VStack(alignment: .leading, spacing: 6) {
                Text("Contraseña")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(accentColor)
                        .frame(width: 22)

                    if isPasswordVisible {
                        TextField("Contraseña", text: $password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                    } else {
                        SecureField("Contraseña", text: $password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                    }

                    Button {
                        isPasswordVisible.toggle()
                    } label: {
                        Image(systemName: isPasswordVisible ? "eye.slash.fill" : "eye.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    Color(uiColor: .tertiarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
            }

            // Confirm Password (Only during first-time setup)
            if !isConfigured {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Confirmar contraseña")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundStyle(accentColor)
                            .frame(width: 22)

                        if isConfirmPasswordVisible {
                            TextField("Repite tu contraseña", text: $confirmPassword)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                        } else {
                            SecureField("Repite tu contraseña", text: $confirmPassword)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                        }

                        Button {
                            isConfirmPasswordVisible.toggle()
                        } label: {
                            Image(systemName: isConfirmPasswordVisible ? "eye.slash.fill" : "eye.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        Color(uiColor: .tertiarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                }
            }

            if let error = errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }

            // Action button
            Button {
                if isConfigured {
                    loginWithCredentials()
                } else {
                    registerAndLogin()
                }
            } label: {
                HStack(spacing: 8) {
                    if isProcessing {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text(isConfigured ? "Iniciar sesión" : "Crear acceso y entrar")
                            .fontWeight(.semibold)
                        Image(systemName: "arrow.right")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(accentColor)
            .disabled(isProcessing || username.isEmpty || password.isEmpty)

            // Alternate shortcut
            Button {
                withAnimation { selectedTab = .biometrics }
                triggerBiometrics()
            } label: {
                HStack {
                    Image(systemName: biometricType.systemImage)
                    Text("O entrar con \(biometricType.title)")
                }
                .font(.subheadline)
                .foregroundStyle(accentColor)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: AppDesign.cardRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppDesign.cardRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.3 : 0.05), radius: 12, y: 4)
    }

    private var setupBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(accentColor)
                Text("Bienvenido")
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            Text("Establece un nombre de usuario y contraseña para acceder de forma segura a tus finanzas.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Biometrics Card

    private var biometricsCard: some View {
        VStack(spacing: 24) {
            // Pulse circle
            ZStack {
                Circle()
                    .fill(accentColor.opacity(0.09))
                    .frame(width: 120, height: 120)

                Circle()
                    .fill(accentColor.opacity(0.16))
                    .frame(width: 90, height: 90)

                Image(systemName: biometricType.systemImage)
                    .font(.system(size: 46, weight: .regular))
                    .foregroundStyle(accentColor)
            }
            .padding(.top, 8)

            VStack(spacing: 8) {
                Text("Acceso rápido con \(biometricType.title)")
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text("Verifica tu identidad en un instante sin tener que introducir tu contraseña.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }

            if let error = errorMessage ?? lockManager.lastErrorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }

            Button {
                triggerBiometrics()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: biometricType.systemImage)
                        .font(.title3)
                    Text("Desbloquear con \(biometricType.title)")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(accentColor)
            .disabled(lockManager.isAuthenticating)

            Button {
                withAnimation { selectedTab = .credentials }
            } label: {
                HStack {
                    Image(systemName: "keyboard")
                    Text("Acceder con usuario y contraseña")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
        }
        .padding(24)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: AppDesign.cardRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppDesign.cardRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.3 : 0.05), radius: 12, y: 4)
    }

    private var footerPrivacyBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(Color(hex: "#2F7D66"))
            Text("Tus datos permanecen exclusivamente en tu dispositivo")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func loginWithCredentials() {
        errorMessage = nil
        isProcessing = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let isValid = UserAuthService.verify(username: username, password: password)
            isProcessing = false

            if isValid {
                #if canImport(UIKit)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                #endif
                lockManager.unlockWithCredentials()
            } else {
                #if canImport(UIKit)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                #endif
                errorMessage = "Usuario o contraseña incorrectos."
            }
        }
    }

    private func registerAndLogin() {
        errorMessage = nil
        guard password == confirmPassword else {
            errorMessage = "Las contraseñas no coinciden."
            return
        }
        isProcessing = true
        Task { @MainActor in
            defer { isProcessing = false }
            // Creating credentials from the lock screen must first prove device ownership.
            guard await lockManager.authenticate() else { return }
            do {
                try UserAuthService.register(username: username, password: password)
                isConfigured = true; password = ""; confirmPassword = ""
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func triggerBiometrics() {
        errorMessage = nil
        Task {
            let success = await lockManager.authenticate()
            if success {
                #if canImport(UIKit)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                #endif
            }
        }
    }
}
