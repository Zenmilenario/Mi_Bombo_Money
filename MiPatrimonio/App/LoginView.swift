import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var lockManager: AppLockManager
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum AccessMode { case signIn, device, setup }
    private enum Field: Hashable { case username, password, confirmation }

    @State private var mode: AccessMode = UserAuthService.isConfigured ? .signIn : .device
    @State private var isConfigured = UserAuthService.isConfigured
    @State private var username = UserAuthService.storedUsername ?? ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var passwordVisible = false
    @State private var confirmationVisible = false
    @State private var errorMessage: String?
    @State private var isProcessing = false
    @State private var showingHelp = false
    @State private var biometricType = AppLockManager.biometricType
    @FocusState private var focusedField: Field?
    @AccessibilityFocusState private var errorIsFocused: Bool

    private var accent: Color { Color(hex: colorScheme == .dark ? "#67CDCF" : "#176B87") }
    private var buttonColor: Color { Color(hex: "#176B87") }
    private var isBusy: Bool { isProcessing || lockManager.isAuthenticating }
    private var deviceTitle: String {
        biometricType == .passcode ? "Entrar con el código del dispositivo" : "Entrar con \(biometricType.title)"
    }
    private var title: String {
        switch mode {
        case .signIn: "Iniciar sesión"
        case .device: "Te damos la bienvenida"
        case .setup: "Crea tu acceso"
        }
    }
    private var subtitle: String {
        switch mode {
        case .signIn: "Accede a tu espacio financiero."
        case .device: "Tus cuentas, tus planes y todo lo que quieres tener bajo control."
        case .setup: "Un usuario y una contraseña para entrar en esta app."
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 900 && !dynamicTypeSize.isAccessibilitySize
            ZStack {
                AppDesign.pageBackground.ignoresSafeArea()
                LinearGradient(colors: [accent.opacity(0.07), .clear], startPoint: .topTrailing, endPoint: .center)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)

                ScrollView {
                    Group {
                        if wide {
                            HStack(alignment: .center, spacing: 48) {
                                welcomePanel
                                    .frame(maxWidth: .infinity)
                                accessContent
                                    .frame(maxWidth: 480)
                            }
                            .frame(maxWidth: 1_160)
                        } else {
                            VStack(alignment: .leading, spacing: 32) {
                                brandSignature
                                accessContent
                            }
                            .frame(maxWidth: 520)
                        }
                    }
                    .padding(.horizontal, geometry.size.width < 600 ? 24 : 40)
                    .padding(.vertical, 32)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: geometry.size.height)
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .tint(accent)
        .onAppear {
            biometricType = AppLockManager.biometricType
            isConfigured = UserAuthService.isConfigured
            if username.isEmpty { username = UserAuthService.storedUsername ?? "" }
        }
        .onDisappear {
            password = ""
            confirmPassword = ""
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                password = ""
                confirmPassword = ""
                passwordVisible = false
                confirmationVisible = false
                focusedField = nil
            }
        }
        .onChange(of: errorMessage) { _, message in
            if message != nil { errorIsFocused = true }
        }
        .sheet(isPresented: $showingHelp) { accessHelp }
    }

    private var brandSignature: some View {
        HStack(spacing: 12) {
            Image("LoginBrand")
                .resizable()
                .scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Mi Bombo Money")
                    .font(.headline)
                Text("Finanzas personales")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var welcomePanel: some View {
        VStack(alignment: .leading, spacing: 48) {
            brandSignature
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "square.stack.3d.up")
                    .font(.largeTitle)
                    .foregroundStyle(Color(hex: "#9CE3D9"))
                    .accessibilityHidden(true)
                Text("Tu dinero,\ncon más claridad.")
                    .font(.largeTitle.bold())
                    .fixedSize(horizontal: false, vertical: true)
                Text("Un lugar para tus cuentas, tus movimientos y los planes que vienen.")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Label("A tu ritmo. A tu manera.", systemImage: "leaf")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(36)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .background {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: "#174F60"), Color(hex: "#102F3A")],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        }
    }

    private var accessContent: some View {
        VStack(spacing: 22) {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("TU ESPACIO PERSONAL", systemImage: "lock")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(accent)
                    Text(title)
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)

                if mode == .device {
                    deviceIntroduction
                } else {
                    credentialsFields
                }

                if let message = errorMessage ?? lockManager.lastErrorMessage {
                    Label(message, systemImage: "exclamationmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityFocused($errorIsFocused)
                }

                accessActions
            }
            .padding(dynamicTypeSize.isAccessibilitySize ? 20 : 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppDesign.cardBackground, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            }

            Button("¿Necesitas ayuda para entrar?") { showingHelp = true }
                .font(.subheadline)
                .frame(minHeight: 44)

            Label("El acceso protege tus finanzas en este dispositivo.", systemImage: "iphone.and.arrow.forward")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var deviceIntroduction: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: biometricType.systemImage)
                .font(.largeTitle)
                .foregroundStyle(accent)
                .accessibilityHidden(true)
            Text(biometricType == .passcode
                 ? "Usa el código de tu dispositivo para acceder."
                 : "Usa \(biometricType.title) para entrar. También puedes utilizar el código del dispositivo.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var credentialsFields: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Usuario").font(.subheadline.weight(.medium))
                HStack(spacing: 10) {
                    Image(systemName: "person").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("Nombre de usuario", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .username)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .password }
                        .accessibilityLabel("Usuario")
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 54)
                .background(fieldBackground(focused: focusedField == .username))
            }
            passwordField(title: "Contraseña", text: $password, visible: $passwordVisible, field: .password)
            if mode == .setup {
                Text("Usa al menos 10 caracteres. Puedes utilizar una frase fácil de recordar.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                passwordField(title: "Repite la contraseña", text: $confirmPassword, visible: $confirmationVisible, field: .confirmation)
                Label("Antes de crear el acceso, el dispositivo verificará tu identidad.", systemImage: "person.badge.shield.checkmark")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(isBusy)
    }

    private func passwordField(title: String, text: Binding<String>, visible: Binding<Bool>, field: Field) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.medium))
            HStack(spacing: 10) {
                Image(systemName: "key.horizontal").foregroundStyle(.secondary).accessibilityHidden(true)
                Group {
                    if visible.wrappedValue {
                        TextField(title, text: text)
                    } else {
                        SecureField(title, text: text)
                    }
                }
                .textContentType(mode == .setup ? .newPassword : .password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: field)
                .submitLabel(mode == .setup && field == .password ? .next : .go)
                .onSubmit {
                    if mode == .setup && field == .password { focusedField = .confirmation }
                    else { submitCredentials() }
                }
                .accessibilityLabel(title)
                Button {
                    visible.wrappedValue.toggle()
                    focusedField = field
                } label: {
                    Image(systemName: visible.wrappedValue ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(visible.wrappedValue ? "Ocultar \(title.lowercased())" : "Mostrar \(title.lowercased())")
            }
            .padding(.leading, 14)
            .padding(.trailing, 4)
            .frame(minHeight: 54)
            .background(fieldBackground(focused: focusedField == field))
        }
    }

    private func fieldBackground(focused: Bool) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(AppDesign.pageBackground)
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(focused ? accent : Color.primary.opacity(0.08), lineWidth: focused ? 2 : 1)
            }
    }

    private var accessActions: some View {
        VStack(spacing: 14) {
            Button {
                if mode == .device { triggerDeviceAuthentication() }
                else { submitCredentials() }
            } label: {
                HStack(spacing: 10) {
                    if isBusy {
                        ProgressView().tint(.white)
                        Text("Verificando…")
                    } else {
                        Text(mode == .device ? deviceTitle : mode == .setup ? "Crear acceso y entrar" : "Entrar")
                        Image(systemName: mode == .device ? biometricType.systemImage : "arrow.right")
                    }
                }
                .font(.headline)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 14))
            .tint(buttonColor)
            .disabled(isBusy)

            if mode == .signIn {
                HStack(spacing: 12) {
                    Rectangle().frame(height: 1)
                    Text("o").font(.footnote)
                    Rectangle().frame(height: 1)
                }
                .foregroundStyle(.secondary.opacity(0.4))
                .accessibilityHidden(true)
                Button(action: triggerDeviceAuthentication) {
                    Label(deviceTitle, systemImage: biometricType.systemImage)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: 14))
                .disabled(isBusy)
            } else {
                Button(mode == .setup ? "Volver al acceso con el dispositivo" : isConfigured ? "Usar usuario y contraseña" : "Configurar usuario y contraseña") {
                    changeMode(mode == .setup ? .device : isConfigured ? .signIn : .setup)
                }
                .font(.subheadline)
                .frame(minHeight: 44)
                .disabled(isBusy)
            }
        }
    }

    private var accessHelp: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Label("Tu acceso, paso a paso", systemImage: "key.horizontal")
                        .font(.title2.bold())
                    Text("Puedes entrar con \(biometricType == .passcode ? "el código del dispositivo" : biometricType.title + " o el código del dispositivo"). El sistema realiza la comprobación.")
                    if isConfigured {
                        Text("Si no recuerdas la contraseña de la app, utiliza el acceso del dispositivo. Después puedes gestionar tus credenciales en Ajustes → Acceso por usuario y contraseña.")
                    } else {
                        Text("No necesitas crear un usuario para empezar. Si lo prefieres, puedes configurar un usuario y una contraseña como otra forma de entrar.")
                    }
                    Text("Este acceso corresponde a la app en este dispositivo. No utiliza las claves de tus bancos ni sincroniza tus datos entre dispositivos.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 600, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Ayuda de acceso")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Cerrar") { showingHelp = false } } }
        }
    }

    private func changeMode(_ newMode: AccessMode) {
        focusedField = nil
        password = ""
        confirmPassword = ""
        passwordVisible = false
        confirmationVisible = false
        errorMessage = nil
        lockManager.lastErrorMessage = nil
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { mode = newMode }
    }

    private func submitCredentials() {
        guard !isBusy else { return }
        errorMessage = nil
        lockManager.lastErrorMessage = nil
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Escribe tu nombre de usuario."
            focusedField = .username
            return
        }
        guard !password.isEmpty else {
            errorMessage = "Escribe tu contraseña."
            focusedField = .password
            return
        }
        if mode == .setup {
            guard password.count >= 10 else {
                errorMessage = "La contraseña debe tener al menos 10 caracteres."
                focusedField = .password
                return
            }
            guard password == confirmPassword else {
                errorMessage = "Las contraseñas no coinciden."
                focusedField = .confirmation
                return
            }
            registerAndLogin()
        } else {
            loginWithCredentials()
        }
    }

    private func loginWithCredentials() {
        focusedField = nil
        isProcessing = true
        let enteredUsername = username
        let enteredPassword = password
        Task { @MainActor in
            let valid = await Task.detached(priority: .userInitiated) {
                UserAuthService.verify(username: enteredUsername, password: enteredPassword)
            }.value
            isProcessing = false
            if valid {
                password = ""
                lockManager.unlockWithCredentials()
            } else {
                errorMessage = "Usuario o contraseña incorrectos. Vuelve a intentarlo o utiliza el acceso del dispositivo."
            }
        }
    }

    private func registerAndLogin() {
        focusedField = nil
        isProcessing = true
        let enteredUsername = username
        let enteredPassword = password
        Task { @MainActor in
            defer { isProcessing = false }
            // Creating credentials from the lock screen still requires device-owner verification.
            guard await lockManager.authenticate() else { return }
            do {
                try UserAuthService.register(username: enteredUsername, password: enteredPassword)
                isConfigured = true
                password = ""
                confirmPassword = ""
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func triggerDeviceAuthentication() {
        guard !isBusy else { return }
        focusedField = nil
        errorMessage = nil
        Task { await lockManager.authenticate() }
    }
}
