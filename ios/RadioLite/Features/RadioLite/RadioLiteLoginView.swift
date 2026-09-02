import SwiftUI

private enum RadioLiteLoginMethod: String, CaseIterable, Identifiable {
    case account = "账户"
    case pairing = "6 位配对"
    var id: String { rawValue }
}

struct RadioLiteLoginView: View {
    @EnvironmentObject private var session: RadioLiteSession
    @State private var method: RadioLiteLoginMethod = .account
    @State private var username = ""
    @State private var password = ""
    @State private var pairingCode = ""
    @State private var setupCode = ""
    @FocusState private var focused: Field?

    private enum Field { case server, username, password, pairing, setup }

    var body: some View {
        ZStack {
            RadioPalette.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 26) {
                    header
                    RadioPanel {
                        VStack(spacing: 17) {
                            serverField
                            if session.setupRequired {
                                setupFields
                            } else {
                                loginFields
                            }
                            submitButton
                        }
                    }
                    .frame(maxWidth: 520)

                    Label("支持 HTTP / HTTPS 与 Tailscale，弱网连接最长等待 5 分钟", systemImage: "network.badge.shield.half.filled")
                        .font(.footnote)
                        .foregroundStyle(RadioPalette.muted)
                        .multilineTextAlignment(.center)
                    Text("Radio Lite 原生客户端 · 不提供观察员账户")
                        .font(.caption2.monospaced())
                        .foregroundStyle(RadioPalette.muted.opacity(0.75))
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 40)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .task(id: session.serverAddress) {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await session.probeServer()
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { focused = nil }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(RadioPalette.accent.opacity(0.12))
                    .frame(width: 82, height: 82)
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(RadioPalette.accent)
            }
            Text("Radio Lite")
                .font(.largeTitle.bold())
            Text("低带宽原生远程电台")
                .foregroundStyle(RadioPalette.muted)
        }
    }

    private var serverField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("服务器")
                .font(.caption.weight(.semibold))
                .foregroundStyle(RadioPalette.muted)
            TextField("http://100.x.x.x:8787", text: $session.serverAddress)
                .focused($focused, equals: .server)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .radioLiteInputStyle()
            HStack(spacing: 7) {
                Circle()
                    .fill(session.loginServerReachable ? RadioPalette.accent : RadioPalette.muted)
                    .frame(width: 7, height: 7)
                Text(session.loginServerReachable ? "已识别 Radio Lite v1" : "输入地址后自动检测")
                if session.setupRequired { Text("· 需要首次初始化") }
            }
            .font(.caption)
            .foregroundStyle(RadioPalette.muted)
        }
    }

    private var loginFields: some View {
        VStack(spacing: 15) {
            Picker("登录方式", selection: $method) {
                ForEach(RadioLiteLoginMethod.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            if method == .account {
                TextField("用户名", text: $username)
                    .focused($focused, equals: .username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .radioLiteInputStyle()
                SecureField("密码", text: $password)
                    .focused($focused, equals: .password)
                    .radioLiteInputStyle()
                Text("账户会话适合首次登录；长期使用建议由管理员生成 6 位配对码。")
                    .font(.footnote)
                    .foregroundStyle(RadioPalette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("000000", text: $pairingCode)
                    .focused($focused, equals: .pairing)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 34, weight: .semibold, design: .monospaced))
                    .tracking(8)
                    .radioLiteInputStyle()
                    .onChange(of: pairingCode) { _, value in
                        pairingCode = String(value.filter(\.isNumber).prefix(6))
                    }
                Text("配对码有效期 2 分钟、只能使用一次；App 只在钥匙串保存设备凭据。")
                    .font(.footnote)
                    .foregroundStyle(RadioPalette.muted)
            }
        }
    }

    private var setupFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("首次初始化", systemImage: "person.badge.key.fill")
                .font(.headline)
            TextField("服务器终端显示的初始化码", text: $setupCode)
                .focused($focused, equals: .setup)
                .keyboardType(.numberPad)
                .radioLiteInputStyle()
                .onChange(of: setupCode) { _, value in setupCode = String(value.filter(\.isNumber).prefix(6)) }
            setupRequirement(setupValidation.setupCodeHint, satisfied: setupValidation.setupCodeIsValid)
            TextField("管理员用户名", text: $username)
                .focused($focused, equals: .username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .radioLiteInputStyle()
            setupRequirement(setupValidation.usernameHint, satisfied: setupValidation.usernameIsValid)
            SecureField("管理员密码", text: $password)
                .focused($focused, equals: .password)
                .radioLiteInputStyle()
            setupRequirement(setupValidation.passwordHint, satisfied: setupValidation.passwordIsValid)
        }
    }

    private func setupRequirement(_ text: String, satisfied: Bool) -> some View {
        Label(text, systemImage: satisfied ? "checkmark.circle.fill" : "exclamationmark.circle")
            .font(.caption)
            .foregroundStyle(satisfied ? RadioPalette.accent : RadioPalette.warning)
            .animation(.easeOut(duration: 0.15), value: satisfied)
    }

    private var submitButton: some View {
        Button {
            focused = nil
            Task {
                if session.setupRequired {
                    await session.initializeServer(setupCode: setupCode, username: username, password: password)
                } else if method == .account {
                    await session.login(username: username, password: password)
                } else {
                    await session.login(pairingCode: pairingCode)
                }
            }
        } label: {
            HStack(spacing: 9) {
                if session.isWorking || session.phase == .authenticating { ProgressView().tint(.black) }
                Text(session.phase == .authenticating ? "正在连接（最长 5 分钟）" : session.setupRequired ? "初始化并登录" : "连接电台")
                Image(systemName: "arrow.right")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(RadioActionButtonStyle(tint: RadioPalette.accent, prominent: true))
        .disabled(!canSubmit || session.phase == .authenticating)
    }

    private var canSubmit: Bool {
        guard !session.serverAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if session.setupRequired { return setupValidation.isValid }
        switch method {
        case .account: return !username.isEmpty && !password.isEmpty
        case .pairing: return pairingCode.count == 6
        }
    }

    private var setupValidation: RadioLiteSetupValidation {
        RadioLiteSetupValidation(setupCode: setupCode, username: username, password: password)
    }
}

extension View {
    func radioLiteInputStyle() -> some View {
        self
            .textFieldStyle(.plain)
            .padding(14)
            .background(RadioPalette.panelRaised, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.06))
            }
    }
}
