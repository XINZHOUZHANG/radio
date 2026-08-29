import Foundation
import SwiftUI

struct HardwareDiagnosticsView: View {
    @EnvironmentObject private var session: TX5DRSession
    @EnvironmentObject private var radio: RadioWebSocket

    @State private var selectedProfileID = ""
    @State private var radioStatus: JSONValue?
    @State private var realtimeStats: JSONValue?
    @State private var voicePTTStatus: JSONValue?
    @State private var lastResult: String?
    @State private var busy = false
    @State private var pendingConfirmation: HardwareConfirmation?
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("物理电台") {
                LabeledContent("连接") {
                    Label(
                        hardwareConnected ? "已连接" : "未连接",
                        systemImage: hardwareConnected
                            ? "checkmark.circle.fill"
                            : "antenna.radiowaves.left.and.right.slash"
                    )
                    .foregroundStyle(hardwareConnected ? RadioPalette.accent : RadioPalette.warning)
                }
                LabeledContent("控制通道", value: radio.state.label)
                if let connection = radioStatus?["status"]?["connectionStatus"] {
                    LabeledContent("Hamlib 状态", value: compactValue(connection))
                }
                if let health = radioStatus?["status"]?["connectionHealth"] {
                    JSONSnapshotDisclosure(title: "连接健康", value: health)
                }

                HStack {
                    Button {
                        Task { await connect() }
                    } label: {
                        Label("连接", systemImage: "link")
                    }
                    .disabled(busy || hardwareConnected)

                    Spacer()

                    Button {
                        Task { await reconnect() }
                    } label: {
                        Label("重连", systemImage: "arrow.clockwise")
                    }
                    .disabled(busy)

                    Spacer()

                    Button(role: .destructive) {
                        pendingConfirmation = .disconnect
                    } label: {
                        Label("断开", systemImage: "link.badge.minus")
                    }
                    .disabled(busy || !hardwareConnected)
                }
            }

            if session.isAdmin {
                Section {
                    if session.profiles.isEmpty {
                        ContentUnavailableView(
                            "没有可测试的 Profile",
                            systemImage: "radio",
                            description: Text("请先创建 TX-5DR 电台 Profile。")
                        )
                    } else {
                        Picker("测试 Profile", selection: $selectedProfileID) {
                            ForEach(session.profiles) { profile in
                                Text("\(profile.name) · \(profile.endpointSummary)").tag(profile.id)
                            }
                        }

                        if let profile = selectedProfile {
                            LabeledContent("类型", value: profile.radioType)
                            LabeledContent("端点", value: profile.endpointSummary)
                            JSONSnapshotDisclosure(title: "测试配置", value: profile.radio)
                        }

                        Button {
                            Task { await testConnection() }
                        } label: {
                            Label("测试 Hamlib / CAT 连接", systemImage: "cable.connector")
                        }
                        .disabled(busy || selectedProfile == nil)

                        Button {
                            pendingConfirmation = .ptt
                        } label: {
                            Label("测试 PTT（发射 0.5 秒）", systemImage: "dot.radiowaves.up.forward")
                        }
                        .tint(RadioPalette.transmit)
                        .disabled(busy || selectedProfile == nil || selectedProfile?.radioType == "none")

                        Button {
                            pendingConfirmation = .cw
                        } label: {
                            Label("测试 CW 键控（0.5 秒）", systemImage: "waveform.path")
                        }
                        .tint(RadioPalette.warning)
                        .disabled(busy || selectedProfile == nil || selectedProfile?.radioType == "none")
                    }
                } header: {
                    Text("Profile 硬件测试")
                } footer: {
                    Text("测试由 TX-5DR 在服务端执行。PTT 与 CW 会真实控制电台，请先接假负载或确认频率、功率、天线和当地法规。")
                }

                Section("服务端音频") {
                    if let profile = selectedProfile {
                        JSONSnapshotDisclosure(title: "当前 Profile 音频配置", value: profile.audio)
                    }
                    Button(role: .destructive) {
                        pendingConfirmation = .resetAudio
                    } label: {
                        Label("重置服务端音频设置", systemImage: "speaker.wave.2.bubble")
                    }
                    .disabled(busy)
                }
            }

            Section("实时音频与 PTT") {
                if let held = voicePTTStatus?["isLocked"]?.boolValue
                    ?? voicePTTStatus?["locked"]?.boolValue {
                    LabeledContent("语音 PTT 锁", value: held ? "占用" : "空闲")
                }
                JSONSnapshotDisclosure(title: "Voice PTT 状态", value: voicePTTStatus)
                JSONSnapshotDisclosure(title: "Realtime 统计", value: realtimeStats)
            }

            if let lastResult {
                Section("最近测试结果") {
                    Text(lastResult)
                        .font(.subheadline)
                        .textSelection(.enabled)
                }
            }

            Section("完整硬件状态") {
                JSONSnapshotDisclosure(title: "Radio 状态", value: radioStatus)
                JSONSnapshotDisclosure(title: "WebSocket 音频边车", value: radio.audioStatus)
                JSONSnapshotDisclosure(title: "天调状态", value: radio.tunerStatus)
            }
        }
        .scrollContentBackground(.hidden)
        .background(RadioPalette.background.ignoresSafeArea())
        .navigationTitle("电台与音频诊断")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button {
                Task { await load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(busy)
        }
        .task {
            if session.profiles.isEmpty { await session.refreshProfiles() }
            resolveSelectedProfile()
            await load()
        }
        .refreshable { await load() }
        .onChange(of: session.activeProfileId) { _, _ in resolveSelectedProfile() }
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(
                get: { pendingConfirmation != nil },
                set: { if !$0 { pendingConfirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(confirmationButtonTitle, role: confirmationRole) {
                let action = pendingConfirmation
                pendingConfirmation = nil
                Task { await performConfirmed(action) }
            }
            Button("取消", role: .cancel) { pendingConfirmation = nil }
        } message: {
            Text(confirmationMessage)
        }
        .alert("硬件操作失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "未知错误")
        }
    }

    private var selectedProfile: RadioProfile? {
        session.profiles.first { $0.id == selectedProfileID }
    }

    private var hardwareConnected: Bool {
        radioStatus?["status"]?["connected"]?.boolValue
            ?? radioStatus?["isConnected"]?.boolValue
            ?? false
    }

    private var confirmationTitle: String {
        switch pendingConfirmation {
        case .ptt: "确认进行真实 PTT 测试？"
        case .cw: "确认进行真实 CW 键控测试？"
        case .disconnect: "断开物理电台？"
        case .resetAudio: "重置服务端音频设置？"
        case nil: "确认操作"
        }
    }

    private var confirmationButtonTitle: String {
        switch pendingConfirmation {
        case .ptt: "发射 0.5 秒"
        case .cw: "键控 0.5 秒"
        case .disconnect: "强制停发并断开"
        case .resetAudio: "重置音频"
        case nil: "确认"
        }
    }

    private var confirmationMessage: String {
        switch pendingConfirmation {
        case .ptt:
            "TX-5DR 会让所选 Profile 对应的电台进入发射约 0.5 秒。请确认已接假负载或安全天线。"
        case .cw:
            "TX-5DR 会实际拉动所选 CW 键控线路约 0.5 秒。请确认端口、极性和发射环境安全。"
        case .disconnect:
            "服务端会先尝试停止所有发射，再关闭当前 CAT/Hamlib 连接。"
        case .resetAudio:
            "当前 Profile 的音频设备、采样率、缓冲区与 IF/AF 参数将恢复默认；正在运行的引擎可能会重启。"
        case nil:
            ""
        }
    }

    private var confirmationRole: ButtonRole? {
        switch pendingConfirmation {
        case .ptt, .cw, .disconnect, .resetAudio: .destructive
        case nil: nil
        }
    }

    private func resolveSelectedProfile() {
        if session.profiles.contains(where: { $0.id == selectedProfileID }) { return }
        selectedProfileID = session.activeProfileId ?? session.profiles.first?.id ?? ""
    }

    private func load() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        var failures: [String] = []
        do { radioStatus = try await session.fetchRadioHardwareStatus() }
        catch { failures.append("电台：\(error.localizedDescription)") }
        do { realtimeStats = try await session.fetchRealtimeStats() }
        catch { failures.append("Realtime：\(error.localizedDescription)") }
        do { voicePTTStatus = try await session.fetchVoicePTTStatus() }
        catch { failures.append("PTT：\(error.localizedDescription)") }
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
    }

    private func connect() async {
        await performJSON(success: "物理电台连接命令已完成") {
            try await session.connectRadioHardware()
        }
    }

    private func reconnect() async {
        await performJSON(success: "物理电台已重新连接") {
            try await session.reconnectRadioHardware()
        }
    }

    private func disconnect() async {
        await performJSON(success: "物理电台已断开") {
            try await session.disconnectRadioHardware()
        }
    }

    private func testConnection() async {
        guard let profile = selectedProfile else { return }
        await performTest {
            try await session.testRadioConnection(profile: profile)
        }
    }

    private func testPTT() async {
        guard let profile = selectedProfile else { return }
        await performTest {
            try await session.testRadioPTT(profile: profile)
        }
    }

    private func testCW() async {
        guard let profile = selectedProfile else { return }
        await performTest {
            try await session.testRadioCWKeyer(profile: profile)
        }
    }

    private func resetAudio() async {
        await performJSON(success: "服务端音频设置已恢复默认") {
            try await session.resetServerAudioSettings()
        }
        await session.refreshProfiles()
        resolveSelectedProfile()
    }

    private func performConfirmed(_ action: HardwareConfirmation?) async {
        switch action {
        case .ptt: await testPTT()
        case .cw: await testCW()
        case .disconnect: await disconnect()
        case .resetAudio: await resetAudio()
        case nil: break
        }
    }

    private func performJSON(
        success: String,
        operation: () async throws -> JSONValue
    ) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let response = try await operation()
            lastResult = response.prettyPrinted
            radioStatus = try? await session.fetchRadioHardwareStatus()
            session.noticeMessage = success
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func performTest(
        operation: () async throws -> GenericSuccessResponse
    ) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let response = try await operation()
            let message = response.message ?? (response.success ? "测试成功" : "测试失败")
            if response.success {
                lastResult = message
                session.noticeMessage = message
            } else {
                errorMessage = message
            }
            radioStatus = try? await session.fetchRadioHardwareStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func compactValue(_ value: JSONValue) -> String {
        value.stringValue
            ?? value.boolValue.map { $0 ? "true" : "false" }
            ?? value.intValue.map(String.init)
            ?? value.prettyPrinted.replacingOccurrences(of: "\n", with: " ")
    }
}

private enum HardwareConfirmation: String, Identifiable {
    case ptt
    case cw
    case disconnect
    case resetAudio

    var id: String { rawValue }
}
