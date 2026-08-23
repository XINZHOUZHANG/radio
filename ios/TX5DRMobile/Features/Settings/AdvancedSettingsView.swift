import SwiftUI

private struct SettingsEndpoint: Identifiable, Hashable {
    let title: String
    let subtitle: String
    let loadPath: String
    let savePath: String?
    let saveMethod: HTTPMethod
    let adminOnly: Bool

    var id: String { "\(loadPath):\(savePath ?? "read")" }

    static let all: [SettingsEndpoint] = [
        .init(title: "台站信息", subtitle: "呼号、网格和台站坐标", loadPath: "/station/info", savePath: "/station/info", saveMethod: .put, adminOnly: false),
        .init(title: "FT8 / FT4", subtitle: "解码与自动应答参数", loadPath: "/settings/ft8", savePath: "/settings/ft8", saveMethod: .put, adminOnly: false),
        .init(title: "解码窗口", subtitle: "时隙解码窗口与容差", loadPath: "/settings/decode-windows", savePath: "/settings/decode-windows", saveMethod: .put, adminOnly: false),
        .init(title: "频率预设", subtitle: "各频段与模式预设", loadPath: "/settings/frequency-presets", savePath: "/settings/frequency-presets", saveMethod: .put, adminOnly: false),
        .init(title: "语音", subtitle: "语音 PTT 与音频配置", loadPath: "/voice/config", savePath: "/voice/config", saveMethod: .post, adminOnly: false),
        .init(title: "CW 键控", subtitle: "键速、音调和硬件键控", loadPath: "/cw/config", savePath: "/cw/config", saveMethod: .put, adminOnly: false),
        .init(title: "CW 解码器", subtitle: "解码后端和调谐参数", loadPath: "/cw/decoder/config", savePath: "/cw/decoder/config", saveMethod: .put, adminOnly: false),
        .init(title: "实时音频", subtitle: "传输策略与公网 UDP 入口", loadPath: "/settings/realtime", savePath: "/settings/realtime", saveMethod: .put, adminOnly: true),
        .init(title: "音频设备", subtitle: "输入、输出和采样配置", loadPath: "/audio/settings", savePath: "/audio/settings", saveMethod: .post, adminOnly: true),
        .init(title: "电台 / Hamlib", subtitle: "电台型号、串口或 rigctld", loadPath: "/radio/config", savePath: "/radio/config", saveMethod: .post, adminOnly: true),
        .init(title: "远程访问安全", subtitle: "来源、连接限制与公开访问", loadPath: "/auth/remote-access", savePath: "/auth/remote-access", saveMethod: .patch, adminOnly: true),
        .init(title: "可观测性", subtitle: "遥测与诊断选项", loadPath: "/settings/observability", savePath: "/settings/observability", saveMethod: .put, adminOnly: true),
        .init(title: "服务端日志", subtitle: "日志级别和模块开关", loadPath: "/system/logging", savePath: "/system/logging", saveMethod: .put, adminOnly: true),
        .init(title: "发射音频统计", subtitle: "PTT 上行各阶段诊断", loadPath: "/realtime/tx-stats", savePath: nil, saveMethod: .get, adminOnly: false),
        .init(title: "系统网络", subtitle: "服务端接口和地址", loadPath: "/system/network-info", savePath: nil, saveMethod: .get, adminOnly: true),
        .init(title: "系统时钟", subtitle: "时钟同步状态", loadPath: "/system/clock", savePath: nil, saveMethod: .get, adminOnly: true),
        .init(title: "插件", subtitle: "已安装插件与运行状态", loadPath: "/plugins", savePath: nil, saveMethod: .get, adminOnly: true),
        .init(title: "插件市场", subtitle: "服务端可安装插件目录", loadPath: "/plugins/market/catalog", savePath: nil, saveMethod: .get, adminOnly: true),
        .init(title: "OpenWebRX 台站", subtitle: "SDR 接收站配置", loadPath: "/openwebrx/stations", savePath: nil, saveMethod: .get, adminOnly: true),
    ]
}

struct AdvancedSettingsView: View {
    @EnvironmentObject private var session: TX5DRSession

    var body: some View {
        List {
            Section {
                NavigationLink {
                    PSKReporterSettingsView()
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("PSK Reporter")
                        Text("上报身份、运行状态与统计")
                            .font(.caption)
                            .foregroundStyle(RadioPalette.muted)
                    }
                }
                NavigationLink {
                    RigctldBridgeSettingsView()
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Rigctld 桥")
                        Text("Hamlib TCP 监听、权限与客户端")
                            .font(.caption)
                            .foregroundStyle(RadioPalette.muted)
                    }
                }
                ForEach(visibleEndpoints) { endpoint in
                    NavigationLink {
                        JSONSettingsEditorView(endpoint: endpoint)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(endpoint.title)
                            Text(endpoint.subtitle)
                                .font(.caption)
                                .foregroundStyle(RadioPalette.muted)
                        }
                    }
                }
            } footer: {
                Text("编辑器直接使用 TX-5DR 原生 JSON 协议；保存前会在本机验证 JSON。只读页面不会显示保存按钮。")
            }
        }
        .scrollContentBackground(.hidden)
        .background(RadioPalette.background.ignoresSafeArea())
        .navigationTitle("服务端设置")
    }

    private var visibleEndpoints: [SettingsEndpoint] {
        SettingsEndpoint.all.filter { !$0.adminOnly || session.isAdmin }
    }
}

private struct JSONSettingsEditorView: View {
    @EnvironmentObject private var session: TX5DRSession
    let endpoint: SettingsEndpoint
    @State private var text = ""
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            if loading {
                Spacer()
                ProgressView("读取 TX-5DR")
                Spacer()
            } else {
                TextEditor(text: $text)
                    .font(.system(.caption, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(10)
                    .scrollContentBackground(.hidden)
                    .background(RadioPalette.panel)
            }
        }
        .background(RadioPalette.background.ignoresSafeArea())
        .navigationTitle(endpoint.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                if endpoint.savePath != nil {
                    Button(saving ? "保存中" : "保存") { Task { await save() } }
                        .disabled(loading || saving)
                }
            }
        }
        .task { await load() }
        .alert("请求失败", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("好") { error = nil }
        } message: {
            Text(error ?? "未知错误")
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            text = try await session.readJSON(endpoint.loadPath).prettyPrinted
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() async {
        guard let path = endpoint.savePath else { return }
        saving = true
        defer { saving = false }
        do {
            let value = try JSONValue.parse(text)
            let response = try await session.writeJSON(path, method: endpoint.saveMethod, value: value)
            text = response.prettyPrinted
            session.noticeMessage = "\(endpoint.title)已保存"
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ProtocolConsoleView: View {
    @EnvironmentObject private var session: TX5DRSession
    @EnvironmentObject private var radio: RadioWebSocket
    @State private var channel = 0
    @State private var method: HTTPMethod = .get
    @State private var target = "/radio/status"
    @State private var payload = "{}"
    @State private var response = ""
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Picker("通道", selection: $channel) {
                    Text("REST").tag(0)
                    Text("WebSocket").tag(1)
                }
                .pickerStyle(.segmented)
            }
            Section(channel == 0 ? "API 路径" : "消息类型") {
                if channel == 0 {
                    Picker("方法", selection: $method) {
                        ForEach(HTTPMethod.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    TextField("/radio/status", text: $target)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    TextField("例如 refreshRadioCapabilities", text: $target)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            Section("JSON 数据") {
                TextEditor(text: $payload)
                    .font(.caption.monospaced())
                    .frame(minHeight: 150)
            }
            Section {
                Button("发送") { send() }
                    .frame(maxWidth: .infinity)
            }
            if !response.isEmpty {
                Section("响应") {
                    Text(response)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(RadioPalette.background.ignoresSafeArea())
        .navigationTitle("协议控制台")
        .alert("发送失败", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("好") { error = nil }
        } message: { Text(error ?? "未知错误") }
    }

    private func send() {
        do {
            let value = payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : try JSONValue.parse(payload)
            if channel == 1 {
                radio.sendCommand(target, data: value)
                response = "消息已提交到控制通道"
            } else {
                Task {
                    do {
                        response = try await session.requestJSON(target, method: method, value: method == .get ? nil : value).prettyPrinted
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
