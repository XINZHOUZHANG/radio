import SwiftUI

struct LogbookSyncProvidersView: View {
    @EnvironmentObject private var session: TX5DRSession

    let logbookId: String
    let callsign: String

    @State private var busyProviderIds: Set<String> = []
    @State private var notices: [String: SyncNotice] = [:]
    @State private var pendingPreflight: PendingPreflight?
    @State private var actionError: String?

    var body: some View {
        List {
            Section {
                LabeledContent("操作呼号", value: callsign)
                Text("同步由 TX-5DR 插件执行；App 不保存外部日志服务的密码或密钥。")
                    .font(.caption)
                    .foregroundStyle(RadioPalette.muted)
            }

            if providers.isEmpty {
                ContentUnavailableView(
                    "没有日志同步插件",
                    systemImage: "arrow.triangle.2.circlepath",
                    description: Text("请先由管理员在插件中心安装并启用日志同步提供商。")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(providers) { provider in
                    providerSection(provider)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(RadioPalette.background.ignoresSafeArea())
        .navigationTitle("外部日志同步")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: callsign) { await reload() }
        .refreshable { await reload() }
        .sheet(item: $pendingPreflight) { pending in
            preflightSheet(pending)
        }
        .alert("同步失败", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("好") { actionError = nil }
        } message: {
            Text(actionError ?? "未知错误")
        }
    }

    @ViewBuilder
    private func providerSection(_ provider: TX5DRLogbookSyncProvider) -> some View {
        Section {
            HStack(spacing: 10) {
                Label(
                    configured[provider.id] == true ? "已配置" : "未配置",
                    systemImage: configured[provider.id] == true ? "checkmark.seal.fill" : "exclamationmark.circle"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(configured[provider.id] == true ? RadioPalette.accent : RadioPalette.warning)

                Spacer()

                Button("测试连接") { testConnection(provider) }
                    .buttonStyle(.bordered)
                    .disabled(isBusy(provider))
            }

            if let settingsPage = page(provider.settingsPageId, for: provider),
               let plugin = plugin(for: provider) {
                NavigationLink {
                    PluginPageView(
                        plugin: plugin,
                        page: settingsPage,
                        params: ["callsign": callsign],
                        title: "\(provider.displayName) 设置"
                    )
                } label: {
                    Label("账户与同步设置", systemImage: "gearshape")
                }
            } else {
                Label("插件设置页面当前不可用", systemImage: "rectangle.slash")
                    .foregroundStyle(RadioPalette.muted)
            }

            if let actions = provider.actions, !actions.isEmpty {
                ForEach(actions) { action in
                    actionRow(action, provider: provider)
                }
            } else {
                defaultActions(provider)
            }

            if isBusy(provider) {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("TX-5DR 正在执行同步…")
                        .font(.caption)
                        .foregroundStyle(RadioPalette.muted)
                }
            }

            if let notice = notices[provider.id] {
                Label(notice.text, systemImage: notice.systemImage)
                    .font(.caption)
                    .foregroundStyle(notice.color)
                    .textSelection(.enabled)
            }
        } header: {
            HStack {
                Text(provider.displayName)
                Spacer()
                Text(provider.id)
                    .font(.caption2.monospaced())
                    .foregroundStyle(RadioPalette.muted)
            }
        } footer: {
            if let scope = provider.accessScope {
                Text(scope == "operator" ? "当前操作员可执行此同步提供商。" : "此同步提供商需要管理员权限。")
            }
        }
    }

    @ViewBuilder
    private func actionRow(
        _ action: TX5DRLogbookSyncAction,
        provider: TX5DRLogbookSyncProvider
    ) -> some View {
        if let pageId = action.pageId,
           let actionPage = page(pageId, for: provider),
           let plugin = plugin(for: provider) {
            NavigationLink {
                PluginPageView(
                    plugin: plugin,
                    page: actionPage,
                    params: ["callsign": callsign],
                    title: action.label
                )
            } label: {
                actionLabel(action)
            }
        } else if let operation = action.operation {
            Button { start(provider, operation: operation) } label: {
                actionLabel(action)
            }
            .disabled(isBusy(provider))
        } else {
            Label(action.label, systemImage: "questionmark.diamond")
                .foregroundStyle(RadioPalette.muted)
        }
    }

    private func actionLabel(_ action: TX5DRLogbookSyncAction) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(action.label, systemImage: systemImage(for: action.icon))
            if let description = action.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(RadioPalette.muted)
            }
        }
    }

    private func defaultActions(_ provider: TX5DRLogbookSyncProvider) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button { start(provider, operation: .download) } label: {
                    Label("下载", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)

                Button { start(provider, operation: .upload) } label: {
                    Label("上传", systemImage: "arrow.up.circle")
                }
                .buttonStyle(.bordered)
            }

            Button { start(provider, operation: .fullSync) } label: {
                Label("完整同步（先下载、再上传）", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .disabled(isBusy(provider))
        .padding(.vertical, 2)
    }

    private func preflightSheet(_ pending: PendingPreflight) -> some View {
        NavigationStack {
            List {
                Section("上传预检") {
                    LabeledContent("待上传", value: String(pending.result.pendingCount))
                    LabeledContent("可以上传", value: String(pending.result.uploadableCount))
                    LabeledContent("被阻止", value: String(pending.result.blockedCount))
                }

                if let issues = pending.result.issues, !issues.isEmpty {
                    Section("发现的问题") {
                        ForEach(issues) { issue in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(issue.qsoCallsign ?? issue.code)
                                        .font(.headline.monospaced())
                                    Spacer()
                                    Text(issue.severity.uppercased())
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(issue.severity == "error" ? RadioPalette.transmit : RadioPalette.warning)
                                }
                                Text(issue.message)
                                if let detail = issue.detail, !detail.isEmpty {
                                    Text(detail)
                                        .font(.caption)
                                        .foregroundStyle(RadioPalette.muted)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }

                if let guidance = pending.result.guidance, !guidance.isEmpty {
                    Section("处理建议") {
                        ForEach(guidance, id: \.self) { Text($0) }
                    }
                }
            }
            .navigationTitle(pending.provider.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { pendingPreflight = nil }
                }
                if pending.result.canSkipBlocked == true, pending.result.uploadableCount > 0 {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("跳过并继续") {
                            pendingPreflight = nil
                            run(pending.provider, operation: pending.operation, skipBlockedQSOs: true)
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var providers: [TX5DRLogbookSyncProvider] {
        session.logbookSyncProviders.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private var configured: [String: Bool] {
        session.logbookSyncConfiguredByCallsign[callsign] ?? [:]
    }

    private func plugin(for provider: TX5DRLogbookSyncProvider) -> TX5DRPluginStatus? {
        session.pluginSnapshot?.plugins.first { $0.name == provider.pluginName }
    }

    private func page(_ pageId: String, for provider: TX5DRLogbookSyncProvider) -> TX5DRPluginUIPage? {
        plugin(for: provider)?.ui?.pages?.first { $0.id == pageId }
    }

    private func isBusy(_ provider: TX5DRLogbookSyncProvider) -> Bool {
        busyProviderIds.contains(provider.id)
    }

    private func reload() async {
        async let syncLoad: Void = session.loadLogbookSyncProviders(callsign: callsign)
        async let pluginLoad: Void = session.refreshPlugins(reportErrors: false)
        _ = await (syncLoad, pluginLoad)
    }

    private func testConnection(_ provider: TX5DRLogbookSyncProvider) {
        guard begin(provider) else { return }
        Task {
            defer { finish(provider) }
            do {
                let result = try await session.testLogbookSyncProvider(
                    providerId: provider.id,
                    callsign: callsign
                )
                let failureText = formatFailures(result.failures)
                let text = result.message ?? (result.success ? "连接测试成功" : "连接测试失败")
                notices[provider.id] = SyncNotice(
                    kind: result.success ? .success : .error,
                    text: [text, failureText].filter { !$0.isEmpty }.joined(separator: "\n")
                )
                await session.loadLogbookSyncProviders(callsign: callsign, reportErrors: false)
            } catch {
                record(error, for: provider)
            }
        }
    }

    private func start(_ provider: TX5DRLogbookSyncProvider, operation: TX5DRLogbookSyncOperation) {
        guard begin(provider) else { return }
        Task {
            defer { finish(provider) }
            do {
                if operation != .download {
                    let preflight = try await session.prepareLogbookSyncUpload(
                        providerId: provider.id,
                        callsign: callsign
                    )
                    guard preflight.ready else {
                        notices[provider.id] = SyncNotice(kind: .warning, text: preflightSummary(preflight))
                        pendingPreflight = PendingPreflight(
                            provider: provider,
                            operation: operation,
                            result: preflight
                        )
                        return
                    }
                }
                try await execute(provider, operation: operation, skipBlockedQSOs: false)
            } catch {
                record(error, for: provider)
            }
        }
    }

    private func run(
        _ provider: TX5DRLogbookSyncProvider,
        operation: TX5DRLogbookSyncOperation,
        skipBlockedQSOs: Bool
    ) {
        guard begin(provider) else { return }
        Task {
            defer { finish(provider) }
            do {
                try await execute(provider, operation: operation, skipBlockedQSOs: skipBlockedQSOs)
            } catch {
                record(error, for: provider)
            }
        }
    }

    private func execute(
        _ provider: TX5DRLogbookSyncProvider,
        operation: TX5DRLogbookSyncOperation,
        skipBlockedQSOs: Bool
    ) async throws {
        switch operation {
        case .download:
            let result = try await session.downloadLogbookSyncProvider(
                providerId: provider.id,
                callsign: callsign
            )
            notices[provider.id] = SyncNotice(
                kind: hasFailures(result.failures) ? .warning : .success,
                text: downloadSummary(result)
            )
        case .upload:
            let result = try await session.uploadLogbookSyncProvider(
                providerId: provider.id,
                callsign: callsign,
                skipBlockedQSOs: skipBlockedQSOs
            )
            notices[provider.id] = SyncNotice(
                kind: result.failed > 0 || hasFailures(result.failures) ? .warning : .success,
                text: uploadSummary(result)
            )
        case .fullSync:
            let download = try await session.downloadLogbookSyncProvider(
                providerId: provider.id,
                callsign: callsign
            )
            let upload = try await session.uploadLogbookSyncProvider(
                providerId: provider.id,
                callsign: callsign,
                skipBlockedQSOs: skipBlockedQSOs
            )
            let hasFailure = hasFailures(download.failures)
                || upload.failed > 0
                || hasFailures(upload.failures)
            notices[provider.id] = SyncNotice(
                kind: hasFailure ? .warning : .success,
                text: "↓ \(downloadSummary(download))\n↑ \(uploadSummary(upload))"
            )
        }

        await session.loadLogbookDetail(id: logbookId)
        await session.loadLogbookBackup(id: logbookId)
        if session.selectedLogbookId == logbookId {
            await session.refreshActiveQSOs()
        }
        await session.loadLogbookSyncProviders(callsign: callsign, reportErrors: false)
    }

    private func begin(_ provider: TX5DRLogbookSyncProvider) -> Bool {
        let inserted = busyProviderIds.insert(provider.id).inserted
        if inserted { notices[provider.id] = nil }
        return inserted
    }

    private func finish(_ provider: TX5DRLogbookSyncProvider) {
        busyProviderIds.remove(provider.id)
    }

    private func record(_ error: Error, for provider: TX5DRLogbookSyncProvider) {
        let text = error.localizedDescription
        notices[provider.id] = SyncNotice(kind: .error, text: text)
        actionError = text
    }

    private func preflightSummary(_ result: TX5DRLogbookSyncUploadPreflight) -> String {
        "预检：待上传 \(result.pendingCount)，可上传 \(result.uploadableCount)，被阻止 \(result.blockedCount)"
    }

    private func uploadSummary(_ result: TX5DRLogbookSyncUploadResult) -> String {
        var parts: [String] = []
        if let submitted = result.submitted { parts.append("提交 \(submitted)") }
        if let verified = result.verified { parts.append("验证 \(verified)") }
        parts.append("上传 \(result.uploaded)")
        parts.append("跳过 \(result.skipped)")
        parts.append("失败 \(result.failed)")
        let failures = formatFailures(result.failures)
        return [parts.joined(separator: " · "), failures].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private func downloadSummary(_ result: TX5DRLogbookSyncDownloadResult) -> String {
        var parts = [
            "下载 \(result.downloaded)",
            "匹配 \(result.matched)",
            "更新 \(result.updated)",
        ]
        if let imported = result.imported { parts.append("导入 \(imported)") }
        if let windows = result.windowCount { parts.append("窗口 \(windows)") }
        let failures = formatFailures(result.failures)
        return [parts.joined(separator: " · "), failures].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private func hasFailures(_ failures: [TX5DRLogbookSyncFailure]?) -> Bool {
        !(failures?.isEmpty ?? true)
    }

    private func formatFailures(_ failures: [TX5DRLogbookSyncFailure]?) -> String {
        (failures ?? []).map { failure in
            var text = failure.qsoCallsign.map { "\($0)：" } ?? ""
            text += failure.message
            if let status = failure.httpStatus { text += "（HTTP \(status)）" }
            if failure.retryable == true { text += "［可重试］" }
            if let detail = failure.detail, detail != failure.message { text += " — \(detail)" }
            return text
        }.joined(separator: "\n")
    }

    private func systemImage(for icon: String?) -> String {
        switch icon {
        case "download": "arrow.down.circle"
        case "upload": "arrow.up.circle"
        case "sync": "arrow.triangle.2.circlepath"
        default: "bolt.circle"
        }
    }
}

private struct PendingPreflight: Identifiable {
    let provider: TX5DRLogbookSyncProvider
    let operation: TX5DRLogbookSyncOperation
    let result: TX5DRLogbookSyncUploadPreflight

    var id: String { "\(provider.id):\(operation.rawValue)" }
}

private struct SyncNotice {
    enum Kind {
        case success
        case warning
        case error
    }

    let kind: Kind
    let text: String

    var systemImage: String {
        switch kind {
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch kind {
        case .success: RadioPalette.accent
        case .warning: RadioPalette.warning
        case .error: RadioPalette.transmit
        }
    }
}
