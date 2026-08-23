import SwiftUI

struct PluginSettingsEditorView: View {
    @EnvironmentObject private var session: TX5DRSession
    let plugin: TX5DRPluginStatus
    let operatorId: String?
    @State private var text = "{}"
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            if loading {
                Spacer()
                ProgressView("读取插件设置")
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
        .navigationTitle(operatorId == nil ? "全局设置" : "操作员设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                Button(saving ? "保存中" : "保存") { Task { await save() } }
                    .disabled(loading || saving)
            }
        }
        .safeAreaInset(edge: .bottom) {
            descriptorBar
        }
        .task { await load() }
        .alert("插件设置失败", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("好") { error = nil }
        } message: {
            Text(error ?? "未知错误")
        }
    }

    private var descriptorBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(descriptorKeys, id: \.self) { key in
                    if let descriptor = descriptors[key] {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(descriptor.label).font(.caption.weight(.semibold))
                            Text("\(key) · \(descriptor.type.rawValue)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(RadioPalette.muted)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(RadioPalette.panelRaised, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var descriptors: [String: TX5DRPluginSettingDescriptor] {
        let scope = operatorId == nil ? "global" : "operator"
        return (plugin.settings ?? [:])
            .filter { $0.value.effectiveScope == scope && $0.value.hidden != true }
    }

    private var descriptorKeys: [String] { descriptors.keys.sorted() }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            text = JSONValue.object(
                try await session.loadPluginSettings(name: plugin.name, operatorId: operatorId)
            ).prettyPrinted
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let value = try JSONValue.parse(text)
            guard let settings = value.objectValue else {
                throw NSError(
                    domain: "TX5DRPluginSettings",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "插件设置必须是 JSON 对象"]
                )
            }
            if await session.savePluginSettings(
                name: plugin.name,
                operatorId: operatorId,
                settings: settings
            ) {
                await load()
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct PluginPanelView: View {
    @EnvironmentObject private var session: TX5DRSession
    @EnvironmentObject private var radio: RadioWebSocket
    let plugin: TX5DRPluginStatus
    let panel: TX5DRPluginPanelDescriptor
    let operatorId: String

    var body: some View {
        Group {
            if panel.component == "iframe", let page, canAccess(page) {
                PluginPageView(
                    plugin: plugin,
                    page: page,
                    params: iframeParams,
                    title: panel.title
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if panel.component == "iframe", let page, !canAccess(page) {
                            ContentUnavailableView(
                                "没有页面权限",
                                systemImage: "lock.shield",
                                description: Text("此插件页面只允许管理员访问。")
                            )
                        } else if panel.component == "iframe" {
                            ContentUnavailableView(
                                "插件页面声明不完整",
                                systemImage: "rectangle.on.rectangle.angled",
                                description: Text("面板没有关联有效的 pageId。")
                            )
                        } else if let data {
                            PluginJSONDataView(value: data)
                        } else {
                            ContentUnavailableView(
                                "等待插件数据",
                                systemImage: "waveform.path.ecg",
                                description: Text("插件通过 TX-5DR WebSocket 推送后会自动显示。")
                            )
                        }
                    }
                    .padding(14)
                }
                .background(RadioPalette.background.ignoresSafeArea())
                .navigationTitle(panel.title)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    private var page: TX5DRPluginUIPage? {
        guard let pageId = panel.pageId else { return nil }
        return plugin.ui?.pages?.first { $0.id == pageId }
    }

    private var iframeParams: [String: String] {
        var params = panel.params ?? [:]
        params["operatorId"] = operatorId
        params["panelId"] = panel.id
        return params
    }

    private func canAccess(_ page: TX5DRPluginUIPage) -> Bool {
        page.accessScope == "operator" || session.isAdmin
    }

    private var data: JSONValue? {
        radio.pluginPanelData["\(plugin.name):\(operatorId):\(panel.id)"]
    }
}

private struct PluginJSONDataView: View {
    let value: JSONValue

    var body: some View {
        if let object = value.objectValue {
            RadioPanel {
                VStack(spacing: 10) {
                    ForEach(object.keys.sorted(), id: \.self) { key in
                        HStack(alignment: .top) {
                            Text(key).foregroundStyle(RadioPalette.muted)
                            Spacer(minLength: 14)
                            Text(object[key]?.compactDescription ?? "—")
                                .multilineTextAlignment(.trailing)
                                .textSelection(.enabled)
                        }
                        if key != object.keys.sorted().last { Divider().opacity(0.25) }
                    }
                }
            }
        } else {
            Text(value.prettyPrinted)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(RadioPalette.panel, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

struct PluginLogsView: View {
    @EnvironmentObject private var radio: RadioWebSocket

    var body: some View {
        List {
            if radio.pluginRuntimeLogs.isEmpty && radio.pluginLogs.isEmpty {
                ContentUnavailableView("暂无插件日志", systemImage: "doc.text.magnifyingglass")
                    .listRowBackground(Color.clear)
            }
            if !radio.pluginRuntimeLogs.isEmpty {
                Section("宿主运行日志") {
                    ForEach(radio.pluginRuntimeLogs.reversed()) { entry in
                        logRow(
                            level: entry.level,
                            source: entry.pluginName ?? entry.stage,
                            message: entry.message,
                            timestamp: entry.timestamp
                        )
                    }
                }
            }
            if !radio.pluginLogs.isEmpty {
                Section("插件日志") {
                    ForEach(radio.pluginLogs.reversed()) { entry in
                        logRow(
                            level: entry.level,
                            source: entry.pluginName,
                            message: entry.message,
                            timestamp: entry.timestamp
                        )
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(RadioPalette.background.ignoresSafeArea())
        .navigationTitle("插件日志")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { radio.requestPluginRuntimeLogHistory() } label: { Image(systemName: "arrow.clockwise") }
                Button("清空") { radio.clearPluginLogs() }
            }
        }
        .task { radio.requestPluginRuntimeLogHistory() }
    }

    private func logRow(level: String, source: String, message: String, timestamp: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(level.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(levelColor(level))
                Text(source).font(.caption.monospaced()).foregroundStyle(RadioPalette.cyan)
                Spacer()
                Text(logDate(timestamp), style: .time).font(.caption2).foregroundStyle(RadioPalette.muted)
            }
            Text(message).font(.caption).textSelection(.enabled)
        }
        .padding(.vertical, 3)
    }

    private func levelColor(_ level: String) -> Color {
        switch level {
        case "error": RadioPalette.transmit
        case "warn": RadioPalette.warning
        case "info": RadioPalette.accent
        default: RadioPalette.muted
        }
    }

    private func logDate(_ value: Double) -> Date {
        Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1_000 : value)
    }
}

private extension JSONValue {
    var compactDescription: String {
        switch self {
        case .string(let value): value
        case .number(let value): value.formatted()
        case .bool(let value): value ? "true" : "false"
        case .null: "null"
        case .array, .object: prettyPrinted
        }
    }
}
