import SwiftUI

private enum LoginMethod: String, CaseIterable, Identifiable {
    case account = "账户"
    case pairing = "配对码"
    case token = "令牌"
    var id: String { rawValue }
}

struct LoginView: View {
    @EnvironmentObject private var session: TX5DRSession
    @State private var method: LoginMethod = .account
    @State private var username = ""
    @State private var password = ""
    @State private var pairingCode = ""
    @State private var token = ""

    var body: some View {
        ZStack {
            RadioPalette.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 28) {
                    header
                    RadioPanel {
                        VStack(spacing: 18) {
                            serverField
                            Picker("登录方式", selection: $method) {
                                ForEach(availableMethods) { item in
                                    Text(item.rawValue).tag(item)
                                }
                            }
                            .pickerStyle(.segmented)

                            fields

                            Button(action: submit) {
                                HStack {
                                    if session.isWorking { ProgressView().tint(.black) }
                                    Text(session.isWorking ? "正在连接" : "连接电台")
                                    Image(systemName: "arrow.right")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(RadioActionButtonStyle(tint: RadioPalette.accent, prominent: true))
                            .disabled(session.isWorking || !canSubmit)
                        }
                    }
                    .frame(maxWidth: 520)

                    Label("仅支持管理员与操作员账户，不提供观察员入口", systemImage: "lock.shield")
                        .font(.footnote)
                        .foregroundStyle(RadioPalette.muted)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 44)
                .frame(maxWidth: .infinity)
            }
        }
        .task(id: session.serverAddress) {
            try? await Task.sleep(for: .milliseconds(550))
            guard !Task.isCancelled else { return }
            await session.probeLoginCapabilities()
            if method == .pairing && !session.pairingAvailable {
                method = .account
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
            Text("TX-5DR Remote")
                .font(.largeTitle.bold())
            Text("原生远程电台控制台")
                .foregroundStyle(RadioPalette.muted)
        }
    }

    private var serverField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("服务器")
                .font(.caption.weight(.semibold))
                .foregroundStyle(RadioPalette.muted)
            TextField("https://radio.example.com", text: $session.serverAddress)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textFieldStyle(.plain)
                .padding(14)
                .background(RadioPalette.panelRaised, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            HStack(spacing: 6) {
                Circle()
                    .fill(session.loginServerReachable ? RadioPalette.accent : RadioPalette.muted)
                    .frame(width: 7, height: 7)
                Text(session.loginServerReachable ? "已识别 TX-5DR" : "输入地址后自动检测")
                if session.pairingAvailable {
                    Text("· 支持 6 位配对")
                }
            }
            .font(.caption)
            .foregroundStyle(RadioPalette.muted)
        }
    }

    private var availableMethods: [LoginMethod] {
        session.pairingAvailable ? [.account, .pairing, .token] : [.account, .token]
    }

    @ViewBuilder
    private var fields: some View {
        switch method {
        case .account:
            VStack(spacing: 12) {
                loginField("用户名", text: $username, secure: false)
                loginField("密码", text: $password, secure: true)
            }
        case .pairing:
            VStack(spacing: 10) {
                TextField("000000", text: $pairingCode)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 34, weight: .semibold, design: .monospaced))
                    .tracking(8)
                    .padding(14)
                    .background(RadioPalette.panelRaised, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .onChange(of: pairingCode) { _, value in
                        pairingCode = String(value.filter(\.isNumber).prefix(6))
                    }
                Text("在已登录的管理员设备上生成，有效期 2 分钟且只能使用一次")
                    .font(.footnote)
                    .foregroundStyle(RadioPalette.muted)
            }
        case .token:
            loginField("永久访问令牌", text: $token, secure: true)
        }
    }

    private func loginField(_ title: String, text: Binding<String>, secure: Bool) -> some View {
        Group {
            if secure {
                SecureField(title, text: text)
            } else {
                TextField(title, text: text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }
        .textFieldStyle(.plain)
        .padding(14)
        .background(RadioPalette.panelRaised, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private var canSubmit: Bool {
        guard !session.serverAddress.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch method {
        case .account: return !username.isEmpty && !password.isEmpty
        case .pairing: return pairingCode.count == 6
        case .token: return !token.isEmpty
        }
    }

    private func submit() {
        Task {
            switch method {
            case .account: await session.login(username: username, password: password)
            case .pairing: await session.login(pairingCode: pairingCode)
            case .token: await session.login(permanentToken: token)
            }
        }
    }
}
