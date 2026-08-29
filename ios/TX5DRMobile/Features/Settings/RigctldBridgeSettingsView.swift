import SwiftUI

private enum RigctldBindMode: String, CaseIterable, Identifiable {
    case all
    case loopback
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "所有网卡（0.0.0.0）"
        case .loopback: "仅本机（127.0.0.1）"
        case .custom: "自定义地址"
        }
    }
}

struct RigctldBridgeSettingsView: View {
    @EnvironmentObject private var session: TX5DRSession
    @EnvironmentObject private var radio: RadioWebSocket

    @State private var enabled = false
    @State private var bindMode: RigctldBindMode = .all
    @State private var bindAddress = "0.0.0.0"
    @State private var portText = "4532"
    @State private var readOnly = true
    @State private var originalConfig: RigctldBridgeConfig?
    @State private var showWriteControlConfirmation = false

    var body: some View {
        Form {
            if let status = session.rigctldStatus {
                listenerSection(status)
                configurationSection
                clientSection(status.clients)
                setupSection(status)
            } else {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("正在读取 Rigctld 桥状态…")
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(RadioPalette.background.ignoresSafeArea())
        .navigationTitle("Rigctld 桥")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    Task { await session.loadRigctldStatus() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(session.isWorking)

                if session.canManageRigctld {
                    Button("保存") { requestSave() }
                        .disabled(!canSave || session.isWorking)
                }
            }
        }
        .refreshable { await session.loadRigctldStatus() }
        .task {
            await session.loadRigctldStatus()
            if let status = session.rigctldStatus {
                apply(status.config, force: originalConfig == nil)
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                await session.loadRigctldStatus(reportErrors: false)
            }
        }
        .onChange(of: radio.rigctldStatus) { _, status in
            guard let status else { return }
            session.applyRigctldSnapshot(status)
        }
        .onChange(of: session.rigctldStatus) { _, status in
            guard let status else { return }
            apply(status.config)
        }
        .confirmationDialog(
            "允许外部软件控制电台？",
            isPresented: $showWriteControlConfirmation,
            titleVisibility: .visible
        ) {
            Button("允许写控制并保存", role: .destructive) {
                performSave()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("关闭只读保护后，N1MM、WSJT-X 等 Rigctld 客户端可以改频率、模式、分离和 PTT。暴露到所有网卡时请只在可信网络使用。")
        }
    }

    private func listenerSection(_ status: RigctldStatus) -> some View {
        Section("监听状态") {
            LabeledContent("服务") {
                Label(
                    status.running ? "运行中" : "已停止",
                    systemImage: status.running ? "checkmark.circle.fill" : "stop.circle"
                )
                .foregroundStyle(status.running ? RadioPalette.accent : RadioPalette.muted)
            }
            LabeledContent("监听地址", value: listeningAddress(status))
            LabeledContent("连接客户端", value: "\(status.clients.count)")

            if let error = status.error, !error.isEmpty {
                Label(error, systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(RadioPalette.transmit)
                    .textSelection(.enabled)
            }
        }
    }

    private var configurationSection: some View {
        Section {
            Toggle(isOn: $enabled) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("启用 Rigctld TCP 桥")
                    Text("让 N1MM、WSJT-X、JTDX 或 Fldigi 连接当前 TX-5DR 电台")
                        .font(.caption)
                        .foregroundStyle(RadioPalette.muted)
                }
            }
            .disabled(!session.canManageRigctld)

            Picker("绑定地址", selection: $bindMode) {
                ForEach(RigctldBindMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .disabled(!session.canManageRigctld)
            .onChange(of: bindMode) { _, mode in
                switch mode {
                case .all: bindAddress = "0.0.0.0"
                case .loopback: bindAddress = "127.0.0.1"
                case .custom:
                    if bindAddress == "0.0.0.0" || bindAddress == "127.0.0.1" {
                        bindAddress = ""
                    }
                }
            }

            if bindMode == .custom {
                TextField("IPv4 / IPv6 监听地址", text: $bindAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.numbersAndPunctuation)
                    .disabled(!session.canManageRigctld)
            }

            TextField("TCP 端口", text: $portText)
                .keyboardType(.numberPad)
                .disabled(!session.canManageRigctld)

            if port == nil {
                Label("端口必须是 1 到 65535 的整数。", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(RadioPalette.transmit)
            }
            if enabled && bindAddress == "0.0.0.0" {
                Label(
                    "此端口会暴露给服务器全部网卡。Rigctld 协议本身不提供登录认证。",
                    systemImage: "network.badge.shield.half.filled"
                )
                .font(.caption)
                .foregroundStyle(RadioPalette.warning)
            }

            Toggle(isOn: $readOnly) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("只读保护")
                    Text(readOnly
                        ? "客户端可读取频率和状态，但不能调谐或触发 PTT"
                        : "客户端可以控制频率、模式、分离与 PTT")
                        .font(.caption)
                        .foregroundStyle(readOnly ? RadioPalette.muted : RadioPalette.transmit)
                }
            }
            .tint(readOnly ? RadioPalette.accent : RadioPalette.transmit)
            .disabled(!session.canManageRigctld)

            if enabled && !readOnly {
                Label(
                    "写控制已开启。外部客户端能够发射，请确认电台和天线处于安全状态。",
                    systemImage: "exclamationmark.octagon.fill"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(RadioPalette.transmit)
            }

            if !session.canManageRigctld {
                Label("当前账户可查看状态，但没有 rigctld:bridge 管理权限。", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(RadioPalette.muted)
            }
        } header: {
            Text("桥接配置")
        } footer: {
            Text("默认端口为 4532，默认启用只读保护。配置由 TX-5DR 服务端持久化。")
        }
    }

    private func clientSection(_ clients: [RigctldClientSnapshot]) -> some View {
        Section("客户端（\(clients.count)）") {
            if clients.isEmpty {
                Text("当前没有外部 Rigctld 客户端连接。")
                    .foregroundStyle(RadioPalette.muted)
            } else {
                ForEach(clients) { client in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(client.peer)
                                .font(.subheadline.monospaced().weight(.semibold))
                            Spacer()
                            Text(connectedDuration(client.connectedAt))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(RadioPalette.muted)
                        }
                        if let command = client.lastCommand, !command.isEmpty {
                            Text("最后命令：\(command)")
                                .font(.caption.monospaced())
                                .foregroundStyle(RadioPalette.muted)
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }
                        if let timestamp = client.lastCommandAt {
                            Text("命令时间：\(formattedTime(timestamp))")
                                .font(.caption2)
                                .foregroundStyle(RadioPalette.muted)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func setupSection(_ status: RigctldStatus) -> some View {
        Section("客户端设置") {
            LabeledContent("Rig 类型", value: "Hamlib NET rigctl")
            LabeledContent("端口", value: "\(status.address?.port ?? status.config.port)")
            Text("N1MM、WSJT-X、JTDX 和 Fldigi 中填写 TX-5DR 服务器的实际 LAN / Tailscale 地址；不要把 0.0.0.0 当作客户端主机名。")
                .font(.caption)
                .foregroundStyle(RadioPalette.muted)
        }
    }

    private var port: Int? {
        guard let value = Int(portText), (1...65_535).contains(value) else { return nil }
        return value
    }

    private var draftConfig: RigctldBridgeConfig? {
        guard let port else { return nil }
        let address = bindAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return nil }
        return RigctldBridgeConfig(
            enabled: enabled,
            bindAddress: address,
            port: port,
            readOnly: readOnly
        )
    }

    private var hasChanges: Bool {
        guard let originalConfig else { return false }
        guard let draftConfig else { return true }
        return draftConfig != originalConfig
    }

    private var canSave: Bool {
        session.canManageRigctld && hasChanges && draftConfig != nil
    }

    private func listeningAddress(_ status: RigctldStatus) -> String {
        guard status.running else { return "未监听" }
        guard let address = status.address else { return "正在启动" }
        return "\(address.host):\(address.port)"
    }

    private func connectedDuration(_ timestamp: Double) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince1970 - timestamp / 1_000))
        if seconds < 60 { return "\(seconds) 秒" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) 分钟" }
        return "\(minutes / 60) 小时"
    }

    private func formattedTime(_ timestamp: Double) -> String {
        Date(timeIntervalSince1970: timestamp / 1_000).formatted(date: .omitted, time: .standard)
    }

    private func apply(_ config: RigctldBridgeConfig, force: Bool = false) {
        if !force, originalConfig != nil, hasChanges { return }
        enabled = config.enabled
        bindAddress = config.bindAddress
        bindMode = config.bindAddress == "0.0.0.0"
            ? .all
            : (config.bindAddress == "127.0.0.1" ? .loopback : .custom)
        portText = String(config.port)
        readOnly = config.readOnly
        originalConfig = config
    }

    private func requestSave() {
        guard let config = draftConfig else { return }
        if config.enabled && !config.readOnly {
            showWriteControlConfirmation = true
        } else {
            performSave()
        }
    }

    private func performSave() {
        guard let config = draftConfig else { return }
        Task {
            guard await session.updateRigctld(config), let saved = session.rigctldStatus?.config else { return }
            apply(saved, force: true)
        }
    }
}
