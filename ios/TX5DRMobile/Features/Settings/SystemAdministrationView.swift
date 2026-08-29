import Foundation
import SwiftUI

struct TX5DRSystemAdministrationView: View {
    @EnvironmentObject private var session: TX5DRSession

    @State private var bootstrapStatus: JSONValue?
    @State private var updateStatus: JSONValue?
    @State private var networkInfo: JSONValue?
    @State private var realtimeStats: JSONValue?
    @State private var loading = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section("系统概览") {
                LabeledContent("启动状态", value: bootstrapLifecycle)
                if let hostname = networkInfo?["hostname"]?.stringValue {
                    LabeledContent("主机名", value: hostname)
                }
                if let port = networkInfo?["webPort"]?.intValue {
                    LabeledContent("网页端口", value: String(port))
                }
                if let active = networkInfo?["activeConnections"]?.intValue,
                   let maximum = networkInfo?["maxConnections"]?.intValue {
                    LabeledContent("连接数", value: "\(active) / \(maximum)")
                }
                if loading {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("正在读取 TX-5DR 状态…")
                            .foregroundStyle(RadioPalette.muted)
                    }
                }
            }

            Section("原生管理工具") {
                if session.isAdmin {
                    NavigationLink {
                        ClockAndNTPSettingsView()
                    } label: {
                        settingsLabel("时钟与 NTP", subtitle: "测量偏差、自动校准和服务器顺序", icon: "clock.badge.checkmark")
                    }

                    NavigationLink {
                        ServerCPUProfileView()
                    } label: {
                        settingsLabel("CPU 性能诊断", subtitle: "引导采样、状态跟踪和诊断文件导出", icon: "gauge.with.dots.needle.67percent")
                    }

                    NavigationLink {
                        DiagnosticLogUploadView()
                    } label: {
                        settingsLabel("诊断日志", subtitle: "选择范围并上传脱敏服务端日志", icon: "waveform.badge.magnifyingglass")
                    }
                }

                NavigationLink {
                    StorageManagementView()
                } label: {
                    settingsLabel("解码存储", subtitle: "持久化状态、日期、记录和缓冲区", icon: "externaldrive")
                }

                NavigationLink {
                    HardwareDiagnosticsView()
                } label: {
                    settingsLabel("电台与音频诊断", subtitle: "Hamlib、PTT、CW、音频及实时链路", icon: "stethoscope")
                }
            }

            if session.isAdmin {
                Section("启动与更新") {
                    JSONSnapshotDisclosure(title: "Bootstrap 详情", value: bootstrapStatus)
                    JSONSnapshotDisclosure(title: "更新状态", value: updateStatus)

                    Button {
                        Task { await retryBootstrap() }
                    } label: {
                        Label("重试失败的启动阶段", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(loading)
                }
            }

            Section("网络与实时链路") {
                JSONSnapshotDisclosure(title: "网络信息", value: networkInfo)
                JSONSnapshotDisclosure(title: "Realtime 统计", value: realtimeStats)
            }
        }
        .scrollContentBackground(.hidden)
        .background(RadioPalette.background.ignoresSafeArea())
        .navigationTitle("TX-5DR 系统")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button {
                Task { await load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(loading)
        }
        .task { await load() }
        .refreshable { await load() }
        .alert("请求失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "未知错误")
        }
    }

    private var bootstrapLifecycle: String {
        guard let value = bootstrapStatus?["lifecycle"]?.stringValue else { return "—" }
        return [
            "pending": "等待",
            "running": "启动中",
            "completed": "完成",
            "failed": "失败",
            "dismissed": "已忽略",
        ][value] ?? value
    }

    @ViewBuilder
    private func settingsLabel(_ title: String, subtitle: String, icon: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(RadioPalette.muted)
            }
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(RadioPalette.accent)
        }
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }

        var failures: [String] = []
        do { bootstrapStatus = try await session.fetchSystemBootstrapStatus() }
        catch { failures.append("启动状态：\(error.localizedDescription)") }
        do { networkInfo = try await session.fetchSystemNetworkInfo() }
        catch { failures.append("网络信息：\(error.localizedDescription)") }
        do { realtimeStats = try await session.fetchRealtimeStats() }
        catch { failures.append("实时统计：\(error.localizedDescription)") }
        if session.isAdmin {
            do { updateStatus = try await session.fetchSystemUpdateStatus() }
            catch { failures.append("更新状态：\(error.localizedDescription)") }
        }
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
    }

    private func retryBootstrap() async {
        loading = true
        defer { loading = false }
        do {
            bootstrapStatus = try await session.retrySystemBootstrap()
            session.noticeMessage = "已请求 TX-5DR 重试启动阶段"
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct ClockAndNTPSettingsView: View {
    @EnvironmentObject private var session: TX5DRSession

    @State private var status: ClockStatusDetail?
    @State private var settings: NTPServerListSettings?
    @State private var serverDrafts: [NTPServerDraft] = []
    @State private var offsetText = "0"
    @State private var autoApply = false
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("校准状态") {
                if let status {
                    LabeledContent("状态") {
                        Label(syncStateLabel(status.syncState), systemImage: indicatorIcon(status.indicatorState))
                            .foregroundStyle(indicatorColor(status.indicatorState))
                    }
                    LabeledContent("已应用偏差", value: milliseconds(status.appliedOffsetMs))
                    LabeledContent("最近测量", value: milliseconds(status.measuredOffsetMs))
                    LabeledContent("NTP 服务器", value: status.serverUsed ?? "—")
                    LabeledContent("最后同步", value: formattedTimestamp(status.lastSyncTime))
                    if let message = status.errorMessage, !message.isEmpty {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(RadioPalette.warning)
                            .textSelection(.enabled)
                    }
                } else {
                    ProgressView("正在读取时钟状态…")
                }

                Button {
                    Task { await measure() }
                } label: {
                    Label("立即测量 NTP 偏差", systemImage: "ruler")
                }
                .disabled(busy)
            }

            Section {
                Toggle(isOn: Binding(
                    get: { autoApply },
                    set: { value in
                        autoApply = value
                        Task { await updateAutoApply(value) }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("自动应用测量偏差")
                        Text("TX-5DR 会把测得的偏差用于数字模式时隙校准")
                            .font(.caption)
                            .foregroundStyle(RadioPalette.muted)
                    }
                }
                .disabled(status == nil || busy)

                HStack {
                    TextField("偏差毫秒", text: $offsetText)
                        .keyboardType(.numbersAndPunctuation)
                    Button("应用") {
                        Task { await applyManualOffset() }
                    }
                    .disabled(Double(offsetText) == nil || busy)
                }
            } header: {
                Text("手动偏差")
            } footer: {
                Text("仅在确认服务端系统时钟存在固定偏差时手动设置；一般应保留自动应用。")
            }

            Section {
                ForEach($serverDrafts) { $draft in
                    HStack(spacing: 10) {
                        TextField("pool.ntp.org", text: $draft.value)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                        Button(role: .destructive) {
                            removeServer(draft.id)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .disabled(serverDrafts.count <= 1 || busy)
                    }
                }
                .onMove { source, destination in
                    serverDrafts.move(fromOffsets: source, toOffset: destination)
                }

                Button {
                    serverDrafts.insert(NTPServerDraft(value: ""), at: 0)
                } label: {
                    Label("添加 NTP 服务器", systemImage: "plus.circle")
                }
                .disabled(busy)

                HStack {
                    Button("恢复默认") { restoreDefaults() }
                        .disabled(settings?.defaultServers.isEmpty != false || busy)
                    Spacer()
                    Button("保存服务器") {
                        Task { await saveServers() }
                    }
                    .disabled(!serversAreValid || busy)
                }
            } header: {
                Text("NTP 服务器顺序")
            } footer: {
                Text("TX-5DR 按列表顺序尝试服务器。地址不能包含 http://、路径或空格，至少保留一个。")
            }
        }
        .scrollContentBackground(.hidden)
        .background(RadioPalette.background.ignoresSafeArea())
        .navigationTitle("时钟与 NTP")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                EditButton()
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(busy)
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .alert("时钟设置失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "未知错误")
        }
    }

    private var normalizedServers: [String] {
        serverDrafts.map { $0.value.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private var serversAreValid: Bool {
        !normalizedServers.isEmpty
            && normalizedServers.allSatisfy(validNTPHost)
            && Set(normalizedServers).count == normalizedServers.count
    }

    private func validNTPHost(_ host: String) -> Bool {
        !host.isEmpty
            && host.count <= 253
            && !host.contains("://")
            && !host.contains("/")
            && host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    }

    private func load() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let loadedStatus = try await session.fetchClockStatus()
            let loadedSettings = try await session.fetchNTPServerSettings()
            status = loadedStatus
            settings = loadedSettings
            autoApply = loadedStatus.autoApplyOffset
            offsetText = String(format: "%.3f", loadedStatus.appliedOffsetMs)
            serverDrafts = loadedSettings.servers.map(NTPServerDraft.init(value:))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func measure() async {
        await perform {
            status = try await session.measureClockOffset()
            if let status { offsetText = String(format: "%.3f", status.appliedOffsetMs) }
            session.noticeMessage = "NTP 偏差测量完成"
        }
    }

    private func updateAutoApply(_ enabled: Bool) async {
        await perform {
            status = try await session.setClockAutoApply(enabled)
            autoApply = status?.autoApplyOffset ?? enabled
            session.noticeMessage = enabled ? "已启用自动时钟校准" : "已关闭自动时钟校准"
        }
    }

    private func applyManualOffset() async {
        guard let value = Double(offsetText) else { return }
        await perform {
            status = try await session.setClockOffset(value)
            offsetText = String(format: "%.3f", status?.appliedOffsetMs ?? value)
            session.noticeMessage = "时钟偏差已应用"
        }
    }

    private func saveServers() async {
        guard serversAreValid else {
            errorMessage = "请修正空地址、重复地址或无效的 NTP 地址。"
            return
        }
        await perform {
            let updated = try await session.updateNTPServers(normalizedServers)
            settings = updated
            serverDrafts = updated.servers.map(NTPServerDraft.init(value:))
            session.noticeMessage = "NTP 服务器列表已保存"
        }
    }

    private func restoreDefaults() {
        guard let defaults = settings?.defaultServers, !defaults.isEmpty else { return }
        serverDrafts = defaults.map(NTPServerDraft.init(value:))
    }

    private func removeServer(_ id: UUID) {
        guard serverDrafts.count > 1 else { return }
        serverDrafts.removeAll { $0.id == id }
    }

    private func perform(_ operation: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do { try await operation() }
        catch {
            autoApply = status?.autoApplyOffset ?? autoApply
            errorMessage = error.localizedDescription
        }
    }

    private func milliseconds(_ value: Double) -> String {
        String(format: "%+.3f ms", value)
    }

    private func formattedTimestamp(_ value: Double?) -> String {
        guard let value, value > 0 else { return "—" }
        return Date(timeIntervalSince1970: value / 1_000).formatted(date: .abbreviated, time: .standard)
    }

    private func syncStateLabel(_ state: ClockStatusDetail.SyncState) -> String {
        switch state {
        case .synced: "已同步"
        case .stale: "数据过期"
        case .never: "尚未同步"
        case .failed: "同步失败"
        }
    }

    private func indicatorIcon(_ state: ClockStatusDetail.IndicatorState) -> String {
        switch state {
        case .ok: "checkmark.circle.fill"
        case .warn, .stale, .never: "exclamationmark.triangle.fill"
        case .alert, .failed: "xmark.octagon.fill"
        }
    }

    private func indicatorColor(_ state: ClockStatusDetail.IndicatorState) -> Color {
        switch state {
        case .ok: RadioPalette.accent
        case .warn, .stale, .never: RadioPalette.warning
        case .alert, .failed: RadioPalette.transmit
        }
    }
}

private struct NTPServerDraft: Identifiable {
    let id = UUID()
    var value: String
}

struct JSONSnapshotDisclosure: View {
    let title: String
    let value: JSONValue?

    var body: some View {
        if let value {
            DisclosureGroup(title) {
                ScrollView(.horizontal) {
                    Text(displayText(value))
                        .font(.caption.monospaced())
                        .foregroundStyle(RadioPalette.muted)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                }
            }
        } else {
            LabeledContent(title, value: "—")
        }
    }

    private func displayText(_ value: JSONValue) -> String {
        let text = value.prettyPrinted
        guard text.count > 20_000 else { return text }
        return String(text.prefix(20_000)) + "\n…内容过长，已在此页截断"
    }
}
