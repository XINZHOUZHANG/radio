import SwiftUI

private enum PluginCenterTab: String, CaseIterable, Identifiable {
    case installed = "已安装"
    case marketplace = "插件市场"

    var id: String { rawValue }
}

struct PluginCenterView: View {
    @EnvironmentObject private var session: TX5DRSession
    @EnvironmentObject private var radio: RadioWebSocket
    @State private var tab = PluginCenterTab.installed
    @State private var marketChannel = "stable"

    var body: some View {
        List {
            Section {
                Picker("插件视图", selection: $tab) {
                    ForEach(PluginCenterTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            switch tab {
            case .installed:
                installedContent
            case .marketplace:
                marketplaceContent
            }
        }
        .scrollContentBackground(.hidden)
        .background(RadioPalette.background.ignoresSafeArea())
        .navigationTitle("插件中心")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task {
            await session.loadPluginCenter(channel: marketChannel)
            radio.requestPluginRuntimeLogHistory()
        }
        .refreshable { await refresh() }
        .onChange(of: marketChannel) { _, channel in
            Task { await session.loadPluginMarket(channel: channel) }
        }
    }

    @ViewBuilder
    private var installedContent: some View {
        if let runtime = session.pluginRuntimeInfo, session.isAdmin {
            Section("运行环境") {
                LabeledContent("形态", value: runtime.distribution)
                LabeledContent("插件目录", value: runtime.pluginDir)
                LabeledContent("数据目录", value: runtime.pluginDataDir)
            }
        }

        Section {
            NavigationLink {
                PluginLogsView()
            } label: {
                Label("实时日志", systemImage: "doc.text.magnifyingglass")
            }
            if let operatorId = session.selectedOperatorId {
                Button {
                    Task { await session.setAllTransmitControlPluginsPaused(operatorId: operatorId, paused: true) }
                } label: {
                    Label("暂停全部发射控制插件", systemImage: "pause.circle")
                }
                Button {
                    Task { await session.setAllTransmitControlPluginsPaused(operatorId: operatorId, paused: false) }
                } label: {
                    Label("恢复全部发射控制插件", systemImage: "play.circle")
                }
            }
        }

        Section("已安装（\(plugins.count)）") {
            if plugins.isEmpty {
                ContentUnavailableView("没有插件", systemImage: "puzzlepiece.extension")
                    .listRowBackground(Color.clear)
            } else {
                ForEach(plugins) { plugin in
                    NavigationLink {
                        PluginDetailView(pluginName: plugin.name)
                    } label: {
                        PluginRow(plugin: plugin)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var marketplaceContent: some View {
        Section {
            Picker("频道", selection: $marketChannel) {
                Text("稳定版").tag("stable")
                Text("每日构建").tag("nightly")
            }
            .pickerStyle(.segmented)
        } footer: {
            Text("插件由 TX-5DR 服务端下载并校验；安装前请检查权限和来源。")
        }

        Section("目录（\(marketEntries.count)）") {
            if marketEntries.isEmpty {
                ContentUnavailableView("市场暂不可用", systemImage: "shippingbox")
                    .listRowBackground(Color.clear)
            } else {
                ForEach(marketEntries) { entry in
                    NavigationLink {
                        PluginMarketDetailView(entry: entry, channel: marketChannel)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(entry.title).font(.headline)
                                Spacer()
                                Text(entry.latestVersion)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(RadioPalette.cyan)
                            }
                            Text(entry.description)
                                .font(.caption)
                                .foregroundStyle(RadioPalette.muted)
                                .lineLimit(2)
                            if let installed = installedPlugin(named: entry.name) {
                                Text(installed.version == entry.latestVersion ? "已安装" : "可更新：\(installed.version) → \(entry.latestVersion)")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(installed.version == entry.latestVersion ? RadioPalette.accent : RadioPalette.warning)
                            }
                        }
                    }
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if session.isAdmin, tab == .installed {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("重新加载全部") { Task { await session.reloadAllPlugins() } }
                    Button("重新扫描目录") { Task { await session.rescanPlugins() } }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
            }
        }
    }

    private var plugins: [TX5DRPluginStatus] {
        (radio.pluginSnapshot ?? session.pluginSnapshot)?.plugins.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        } ?? []
    }

    private var marketEntries: [TX5DRPluginMarketEntry] {
        session.pluginMarketCatalog?.catalog.plugins ?? []
    }

    private func installedPlugin(named name: String) -> TX5DRPluginStatus? {
        plugins.first { $0.name == name }
    }

    private func refresh() async {
        switch tab {
        case .installed: await session.refreshPlugins()
        case .marketplace: await session.loadPluginMarket(channel: marketChannel)
        }
    }
}

private struct PluginRow: View {
    let plugin: TX5DRPluginStatus

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: plugin.type == .strategy ? "point.3.connected.trianglepath.dotted" : "puzzlepiece.extension.fill")
                .font(.title3)
                .foregroundStyle(statusColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(plugin.name).font(.headline.monospaced())
                    if plugin.isBuiltIn {
                        Text("内置").font(.caption2.weight(.bold)).foregroundStyle(RadioPalette.cyan)
                    }
                }
                Text("v\(plugin.version) · \(statusText)")
                    .font(.caption)
                    .foregroundStyle(statusColor)
                if let description = plugin.description, !description.isEmpty {
                    Text(description)
                        .font(.caption2)
                        .foregroundStyle(RadioPalette.muted)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var statusText: String {
        if plugin.autoDisabled == true { return "自动停用" }
        if !plugin.loaded { return "加载失败" }
        if plugin.type == .strategy { return "策略插件" }
        return plugin.enabled ? "运行中" : "已停用"
    }

    private var statusColor: Color {
        if plugin.autoDisabled == true || !plugin.loaded { return RadioPalette.transmit }
        return plugin.enabled || plugin.type == .strategy ? RadioPalette.accent : RadioPalette.muted
    }
}

private struct PluginDetailView: View {
    @EnvironmentObject private var session: TX5DRSession
    @EnvironmentObject private var radio: RadioWebSocket
    let pluginName: String

    var body: some View {
        Group {
            if let plugin {
                List {
                    statusSection(plugin)
                    operatorSection(plugin)
                    configurationSection(plugin)
                    quickActionsSection(plugin)
                    panelsSection(plugin)
                    diagnosticsSection(plugin)
                }
                .scrollContentBackground(.hidden)
                .background(RadioPalette.background.ignoresSafeArea())
            } else {
                ContentUnavailableView("插件不存在", systemImage: "puzzlepiece.extension")
            }
        }
        .navigationTitle(pluginName)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await session.refreshPlugins() }
    }

    private var plugin: TX5DRPluginStatus? {
        (radio.pluginSnapshot ?? session.pluginSnapshot)?.plugins.first { $0.name == pluginName }
    }

    private func statusSection(_ plugin: TX5DRPluginStatus) -> some View {
        Section("状态") {
            LabeledContent("版本", value: plugin.version)
            LabeledContent("类型", value: plugin.type == .strategy ? "策略" : "工具")
            LabeledContent("实例", value: plugin.instanceScope ?? "operator")
            LabeledContent("运行", value: plugin.loaded ? "已加载" : "加载失败")
            if plugin.errorCount > 0 {
                LabeledContent("错误次数", value: String(plugin.errorCount))
            }
            if let lastError = plugin.lastError, !lastError.isEmpty {
                Text(lastError).font(.caption).foregroundStyle(RadioPalette.transmit)
            }
            if session.isAdmin, plugin.type == .utility {
                Toggle("启用插件", isOn: Binding(
                    get: { plugin.enabled },
                    set: { enabled in Task { await session.setPluginEnabled(name: plugin.name, enabled: enabled) } }
                ))
                .disabled(session.isWorking)
            }
            if session.isAdmin {
                Button("重新加载此插件") { Task { await session.reloadPlugin(name: plugin.name) } }
            }
        }
    }

    @ViewBuilder
    private func operatorSection(_ plugin: TX5DRPluginStatus) -> some View {
        if let operatorId = session.selectedOperatorId {
            Section("当前操作员") {
                LabeledContent("操作员", value: session.selectedOperator?.myCallsign ?? operatorId)
                if plugin.type == .strategy {
                    let current = session.pluginOperatorStates[operatorId]?.currentStrategy == plugin.name
                    Button(current ? "当前策略插件" : "设为当前策略") {
                        Task { await session.setPluginStrategy(operatorId: operatorId, pluginName: plugin.name) }
                    }
                    .disabled(current || session.isWorking)
                }
                let paused = plugin.pausedOperatorIds?.contains(operatorId) == true
                Button(paused ? "恢复此操作员插件" : "暂停此操作员插件") {
                    Task { await session.setPluginPaused(name: plugin.name, operatorId: operatorId, paused: !paused) }
                }
            }
        }
    }

    @ViewBuilder
    private func configurationSection(_ plugin: TX5DRPluginStatus) -> some View {
        if plugin.hasGlobalSettings || plugin.hasOperatorSettings || !(plugin.ui?.pages?.isEmpty ?? true) {
            Section("设置与页面") {
                if plugin.hasGlobalSettings, session.isAdmin {
                    NavigationLink("全局设置") {
                        PluginSettingsEditorView(plugin: plugin, operatorId: nil)
                    }
                }
                if plugin.hasOperatorSettings, let operatorId = session.selectedOperatorId {
                    NavigationLink("操作员设置") {
                        PluginSettingsEditorView(plugin: plugin, operatorId: operatorId)
                    }
                }
                ForEach(plugin.ui?.pages ?? []) { page in
                    if page.accessScope == "operator" || session.isAdmin {
                        NavigationLink {
                            PluginPageView(plugin: plugin, page: page)
                        } label: {
                            HStack {
                                Label(page.title, systemImage: "rectangle.on.rectangle.angled")
                                Spacer()
                                Text(page.accessScope ?? "admin")
                                    .font(.caption2)
                                    .foregroundStyle(RadioPalette.muted)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func quickActionsSection(_ plugin: TX5DRPluginStatus) -> some View {
        if let actions = plugin.quickActions, !actions.isEmpty {
            Section("快捷操作") {
                ForEach(actions) { action in
                    Button {
                        radio.invokePluginAction(
                            pluginName: plugin.name,
                            actionId: action.id,
                            operatorId: session.selectedOperatorId
                        )
                    } label: {
                        Label(action.label, systemImage: "bolt.circle")
                    }
                    .disabled(radio.state != .ready)
                }
            }
        }
    }

    @ViewBuilder
    private func panelsSection(_ plugin: TX5DRPluginStatus) -> some View {
        if let panels = plugin.panels, !panels.isEmpty, let operatorId = session.selectedOperatorId {
            Section("实时面板") {
                ForEach(panels) { panel in
                    NavigationLink {
                        PluginPanelView(plugin: plugin, panel: panel, operatorId: operatorId)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(panel.title)
                            Text("\(panel.component) · \(panel.slot ?? "operator")")
                                .font(.caption2.monospaced())
                                .foregroundStyle(RadioPalette.muted)
                        }
                    }
                }
            }
        }
    }

    private func diagnosticsSection(_ plugin: TX5DRPluginStatus) -> some View {
        Section("权限与来源") {
            if let source = plugin.source {
                LabeledContent("来源", value: "市场 · \(source.channel)")
            } else {
                LabeledContent("来源", value: plugin.isBuiltIn ? "TX-5DR 内置" : "本地目录")
            }
            if let permissions = plugin.permissions, !permissions.isEmpty {
                Text(permissions.joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            } else {
                Text("未声明敏感权限").foregroundStyle(RadioPalette.muted)
            }
        }
    }
}

private struct PluginMarketDetailView: View {
    @EnvironmentObject private var session: TX5DRSession
    let entry: TX5DRPluginMarketEntry
    let channel: String
    @State private var confirmingUninstall = false

    var body: some View {
        List {
            Section("插件") {
                LabeledContent("名称", value: entry.name)
                LabeledContent("最新版本", value: entry.latestVersion)
                LabeledContent("最低主机版本", value: entry.minHostVersion)
                if let author = entry.author { LabeledContent("作者", value: author) }
                if let license = entry.license { LabeledContent("许可", value: license) }
                Text(entry.description)
            }
            Section("权限") {
                if entry.permissions.isEmpty {
                    Text("未声明敏感权限").foregroundStyle(RadioPalette.muted)
                } else {
                    ForEach(entry.permissions, id: \.self) { Label($0, systemImage: "lock.shield") }
                }
            }
            if let repository = entry.repository, let url = URL(string: repository) {
                Section("链接") { Link("源代码仓库", destination: url) }
            }
            Section {
                actionButton
                if installed != nil, installed?.isBuiltIn == false {
                    Button("卸载插件", role: .destructive) { confirmingUninstall = true }
                }
            } footer: {
                Text("安装包由 TX-5DR 服务端下载，并按照目录中的 SHA-256 校验值验证。")
            }
        }
        .scrollContentBackground(.hidden)
        .background(RadioPalette.background.ignoresSafeArea())
        .navigationTitle(entry.title)
        .confirmationDialog("卸载 \(entry.title)？", isPresented: $confirmingUninstall) {
            Button("卸载", role: .destructive) {
                Task { await session.uninstallPlugin(name: entry.name, channel: channel) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("插件程序将从服务端移除；plugin-data 会保留。")
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if !session.isAdmin {
            Text("只有管理员可以安装或更新插件").foregroundStyle(RadioPalette.muted)
        } else if installed?.isBuiltIn == true {
            Text("内置插件不能由市场替换").foregroundStyle(RadioPalette.warning)
        } else if let installed {
            if installed.version == entry.latestVersion {
                Label("已安装最新版本", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(RadioPalette.accent)
            } else {
                Button("更新到 \(entry.latestVersion)") {
                    Task { await session.updatePlugin(name: entry.name, channel: channel) }
                }
            }
        } else {
            Button("安装插件") {
                Task { await session.installPlugin(name: entry.name, channel: channel) }
            }
        }
    }

    private var installed: TX5DRPluginStatus? {
        session.pluginSnapshot?.plugins.first { $0.name == entry.name }
    }
}
