import SwiftUI

struct RadioLiteSettingsView: View {
    @EnvironmentObject private var session: RadioLiteSession
    @EnvironmentObject private var media: RadioLiteMediaClient
    @EnvironmentObject private var audio: RadioLiteAudioEngine
    @State private var showCreateUser = false
    @State private var showPairingCode = false
    @State private var confirmLogout = false
    @State private var editingRadio: RadioLiteRadioProfile?

    var body: some View {
        List {
            Section("连接") {
                LabeledContent("服务器", value: session.serverAddress)
                LabeledContent("账户", value: session.displayIdentity)
                LabeledContent("权限", value: roleText)
                HStack {
                    RadioLiteStatusPill(
                        text: session.control.state.label,
                        color: session.control.state == .ready ? RadioPalette.accent : RadioPalette.warning,
                        icon: "point.3.connected.trianglepath.dotted"
                    )
                    RadioLiteStatusPill(
                        text: media.state.label,
                        color: media.state == .ready ? RadioPalette.cyan : RadioPalette.warning,
                        icon: "waveform"
                    )
                }
                if session.control.state != .ready || media.state != .ready {
                    Button("立即重连") { session.reconnectNow() }
                }
            }

            Section("当前电台") {
                if session.radios.count > 1 {
                    Picker("电台", selection: Binding(
                        get: { session.selectedRadioId ?? "" },
                        set: { value in Task { await session.selectRadio(value) } }
                    )) {
                        ForEach(session.radios) { Text($0.name).tag($0.id) }
                    }
                }
                if let radio = session.selectedRadio {
                    LabeledContent("名称", value: radio.name)
                    LabeledContent("Hamlib 型号", value: String(radio.hamlibModelId))
                    LabeledContent("本站呼号", value: radio.station.callsign)
                    if let grid = radio.station.grid { LabeledContent("本站网格", value: grid) }
                    LabeledContent("CAT", value: connectionText(radio.connection))
                    LabeledContent("PTT", value: radio.ptt.method.label)
                    LabeledContent("音频输入", value: radio.audioInput.label ?? radio.audioInput.id)
                    LabeledContent("音频输出", value: radio.audioOutput.label ?? radio.audioOutput.id)
                    LabeledContent("硬件发射", value: radio.hardwareTxEnabled || radio.hamlibModelId == 1 ? "允许" : "服务器已禁用")
                    if session.isAdmin {
                        Button {
                            editingRadio = radio
                        } label: {
                            Label("编辑电台、PTT 与音频", systemImage: "slider.horizontal.3")
                        }
                    }
                }
                if session.hasControl {
                    Button("释放控制权", role: .destructive) { Task { await session.releaseControl() } }
                } else {
                    Button(session.isAdmin ? "强制接管控制权" : "取得控制权") {
                        Task {
                            do { try await session.acquireControl(force: session.isAdmin) }
                            catch { session.errorMessage = error.localizedDescription }
                        }
                    }
                }
            }

            Section("低带宽媒体") {
                LabeledContent("策略", value: media.policy?.tier.uppercased() ?? "—")
                LabeledContent("Opus", value: "\((media.policy?.opusBitrate ?? 0) / 1_000) kb/s · 16 kHz mono")
                LabeledContent("频谱", value: "\(media.policy?.spectrumBins ?? 0) 点 × \(media.policy?.spectrumFps ?? 0) fps")
                LabeledContent("往返延迟", value: "\(Int(media.lastRoundTripMs)) ms")
                LabeledContent("下行包", value: String(audio.receivedPackets))
                LabeledContent("上行包", value: String(audio.sentPackets))
                LabeledContent("丢弃包", value: String(audio.droppedPackets))
                if let error = audio.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(RadioPalette.warning)
                }
            }

            Section {
                Picker("处理模式", selection: $audio.microphoneProcessingMode) {
                    ForEach(RadioLiteMicrophoneProcessingMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .disabled(audio.isCapturingMicrophone)

                Picker("数字增益", selection: $audio.microphoneGain) {
                    ForEach(RadioLiteMicrophoneGain.allCases) { gain in
                        Text(gain.label).tag(gain)
                    }
                }
                .disabled(audio.isCapturingMicrophone)

                Text(audio.microphoneProcessingMode.detail)
                    .font(.footnote)
                    .foregroundStyle(RadioPalette.muted)

                if audio.isCapturingMicrophone {
                    Label("PTT 发射中；松开后才能更改麦克风参数", systemImage: "mic.fill")
                        .font(.footnote)
                        .foregroundStyle(RadioPalette.transmit)
                }
            } header: {
                Text("PTT 麦克风")
            } footer: {
                Text("默认使用远距原声与 +12 dB。样本会先增益，再经平滑软限幅后编码，避免硬削波。")
            }

            if session.isAdmin {
                Section {
                    ForEach(session.users) { user in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(user.username).font(.headline)
                                    Text(user.role == .admin ? "管理员" : user.canTransmit ? "操作员 · 可发射" : "操作员 · 禁止发射")
                                        .font(.caption)
                                        .foregroundStyle(RadioPalette.muted)
                                }
                                Spacer()
                                Button("生成配对码") {
                                    Task {
                                        do {
                                            try await session.issuePairingCode(for: user.id)
                                            showPairingCode = true
                                        } catch {
                                            session.errorMessage = error.localizedDescription
                                        }
                                    }
                                }
                                .buttonStyle(RadioActionButtonStyle(tint: RadioPalette.accent))
                                .disabled(!user.enabled)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                } header: {
                    HStack {
                        Text("账户与 6 位配对")
                        Spacer()
                        Button { showCreateUser = true } label: { Image(systemName: "person.badge.plus") }
                    }
                } footer: {
                    Text("配对码仅显示 2 分钟且只能兑换一次；密码不会保存到 iPhone。")
                }
            }

            Section {
                Button("退出登录", role: .destructive) { confirmLogout = true }
            } footer: {
                Text("退出时会立即关闭麦克风、撤销 PTT、释放控制租约并删除钥匙串凭据。")
            }
        }
        .scrollContentBackground(.hidden)
        .background(RadioPalette.background.ignoresSafeArea())
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .task { await session.refreshUsers() }
        .refreshable { await session.refreshUsers() }
        .sheet(isPresented: $showCreateUser) { RadioLiteCreateUserView() }
        .sheet(item: $editingRadio) { radio in
            RadioLiteDeviceConfigurationView(profile: radio)
        }
        .sheet(isPresented: $showPairingCode) {
            if let code = session.issuedPairingCode {
                RadioLitePairingCodeView(code: code)
            }
        }
        .confirmationDialog("确定退出登录？", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("退出并删除凭据", role: .destructive) { Task { await session.logout() } }
            Button("取消", role: .cancel) {}
        }
    }

    private var roleText: String {
        guard let principal = session.principal else { return "—" }
        let role = principal.role == .admin ? "管理员" : "操作员"
        return principal.canTransmit ? "\(role) · 可发射" : "\(role) · 禁止发射"
    }

    private func connectionText(_ value: RadioLiteRigConnection) -> String {
        switch value.kind {
        case "managed-serial": return "\(value.devicePath ?? "串口") @ \(value.baudRate ?? 0)"
        case "network-rigctld": return "\(value.host ?? "主机"):\(value.port ?? 0)"
        case "hamlib-dummy": return "Hamlib Dummy"
        default: return value.kind
        }
    }
}

private struct RadioLiteCreateUserView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: RadioLiteSession
    @State private var username = ""
    @State private var password = ""
    @State private var role: RadioLiteUserRole = .operator
    @State private var canTransmit = true
    @State private var mustChangePassword = true
    @State private var saving = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("登录") {
                    TextField("用户名（3–32 位）", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused)
                    SecureField("密码（不能为空）", text: $password)
                        .focused($focused)
                    Label(
                        "密码仅需非空，可使用任意字符",
                        systemImage: password.isEmpty ? "exclamationmark.circle" : "checkmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(password.isEmpty ? RadioPalette.warning : RadioPalette.accent)
                }
                Section("权限") {
                    Picker("角色", selection: $role) {
                        Text("操作员").tag(RadioLiteUserRole.operator)
                        Text("管理员").tag(RadioLiteUserRole.admin)
                    }
                    Toggle("允许发射", isOn: $canTransmit)
                    Toggle("首次登录必须修改密码", isOn: $mustChangePassword)
                }
                Section {
                    Text("密码仅要求非空，可使用任意字符；服务端仍使用 Argon2id 保存密码摘要，不保存明文密码。")
                        .font(.footnote)
                        .foregroundStyle(RadioPalette.muted)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("创建账户")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "创建中" : "创建") { Task { await save() } }
                        .disabled(!valid || saving)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { focused = false }
                }
            }
        }
    }

    private var valid: Bool {
        let name = username.lowercased()
        return name.range(of: "^[a-z0-9][a-z0-9_.-]{2,31}$", options: .regularExpression) != nil
            && !password.isEmpty
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await session.createUser(
                username: username,
                password: password,
                role: role,
                canTransmit: canTransmit,
                mustChangePassword: mustChangePassword
            )
            dismiss()
        } catch {
            session.errorMessage = error.localizedDescription
        }
    }
}

private struct RadioLitePairingCodeView: View {
    @Environment(\.dismiss) private var dismiss
    let code: RadioLiteIssuedCode

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Image(systemName: "iphone.and.arrow.forward")
                    .font(.system(size: 50))
                    .foregroundStyle(RadioPalette.accent)
                Text(code.code)
                    .font(.system(size: 48, weight: .bold, design: .monospaced))
                    .tracking(10)
                    .textSelection(.enabled)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = max(0, Int(Date(timeIntervalSince1970: Double(code.expiresAtMs) / 1_000).timeIntervalSince(context.date)))
                    Label(remaining > 0 ? "\(remaining) 秒后过期" : "配对码已过期", systemImage: "timer")
                        .foregroundStyle(remaining > 0 ? RadioPalette.warning : RadioPalette.transmit)
                }
                Text("在另一台 iPhone 的登录页选择“6 位配对”，输入此验证码。成功兑换后本验证码立即失效。")
                    .font(.subheadline)
                    .foregroundStyle(RadioPalette.muted)
                    .multilineTextAlignment(.center)
                Button("完成") { dismiss() }
                    .buttonStyle(RadioActionButtonStyle(tint: RadioPalette.accent, prominent: true))
            }
            .padding(28)
            .navigationTitle("设备配对")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }
}
