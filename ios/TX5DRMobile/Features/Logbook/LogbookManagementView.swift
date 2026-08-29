import SwiftUI
import UniformTypeIdentifiers

private struct TX5DRFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data, .plainText, .commaSeparatedText] }
    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct LogbookManagementView: View {
    @EnvironmentObject private var session: TX5DRSession
    @State private var showingCreate = false
    @State private var editingLogbook: LogbookInfo?
    @State private var pendingDelete: LogbookInfo?

    var body: some View {
        List {
            if session.logbooks.isEmpty {
                ContentUnavailableView(
                    "没有日志本",
                    systemImage: "books.vertical",
                    description: Text(session.isAdmin ? "创建一个托管 ADIF 日志本。" : "当前账户没有可访问的日志本。")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(session.logbooks) { logbook in
                    NavigationLink {
                        LogbookMaintenanceView(logbookId: logbook.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(logbook.name).font(.headline)
                                if logbook.isActive {
                                    Text("活动")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(RadioPalette.accent)
                                }
                            }
                            Text("\(logbook.fileName) · \(logbook.health.state)")
                                .font(.caption.monospaced())
                                .foregroundStyle(logbook.health.writable ? RadioPalette.muted : RadioPalette.warning)
                        }
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button { editingLogbook = logbook } label: {
                            Label("编辑", systemImage: "pencil")
                        }
                        .tint(RadioPalette.cyan)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if session.isAdmin {
                            Button(role: .destructive) { pendingDelete = logbook } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(RadioPalette.background.ignoresSafeArea())
        .navigationTitle("日志本管理")
        .toolbar {
            if session.isAdmin {
                Button { showingCreate = true } label: { Image(systemName: "plus") }
            }
        }
        .refreshable { await session.refreshPrimaryData() }
        .sheet(isPresented: $showingCreate) {
            NavigationStack { LogbookEditorView(logbook: nil) }
                .environmentObject(session)
        }
        .sheet(item: $editingLogbook) { logbook in
            NavigationStack { LogbookEditorView(logbook: logbook) }
                .environmentObject(session)
        }
        .confirmationDialog(
            "删除日志本 \(pendingDelete?.name ?? "")？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("永久删除", role: .destructive) {
                guard let logbook = pendingDelete else { return }
                pendingDelete = nil
                Task { await session.deleteLogbook(logbook) }
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("请先导出或创建备份；删除会移除服务端日志本。")
        }
    }
}

private struct LogbookEditorView: View {
    @EnvironmentObject private var session: TX5DRSession
    @Environment(\.dismiss) private var dismiss
    let logbook: LogbookInfo?
    @State private var name: String
    @State private var description: String
    @State private var isActive: Bool

    init(logbook: LogbookInfo?) {
        self.logbook = logbook
        _name = State(initialValue: logbook?.name ?? "")
        _description = State(initialValue: logbook?.description ?? "")
        _isActive = State(initialValue: logbook?.isActive ?? true)
    }

    var body: some View {
        Form {
            TextField("名称", text: $name)
            TextField("说明（可选）", text: $description, axis: .vertical)
                .lineLimit(2...5)
            if logbook != nil {
                Toggle("活动日志本", isOn: $isActive)
            }
        }
        .navigationTitle(logbook == nil ? "新建日志本" : "编辑日志本")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.isWorking)
            }
        }
    }

    private func save() {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let ok: Bool
            if let logbook {
                ok = await session.updateLogbook(
                    logbook,
                    name: cleanName,
                    description: cleanDescription.isEmpty ? nil : cleanDescription,
                    isActive: isActive
                )
            } else {
                ok = await session.createLogbook(
                    name: cleanName,
                    description: cleanDescription.isEmpty ? nil : cleanDescription
                )
            }
            if ok { dismiss() }
        }
    }
}

private struct LogbookMaintenanceView: View {
    @EnvironmentObject private var session: TX5DRSession
    let logbookId: String
    @State private var showingImporter = false
    @State private var exportDocument: TX5DRFileDocument?
    @State private var exportFileName = "logbook.adi"
    @State private var showingExporter = false
    @State private var fileError: String?
    @State private var restorePreflight: LogbookRestorePreflight?
    @State private var restoreRiskAccepted = false
    @State private var restoreConfirmation = ""
    @State private var recoveryBusy = false
    @State private var pendingUnsavedDiscard: LogbookUnsavedAttempt?

    var body: some View {
        List {
            healthSection
            unsavedSection
            operatorsSection
            transferSection
            syncSection
            backupSection
            restoreSection
        }
        .scrollContentBackground(.hidden)
        .background(RadioPalette.background.ignoresSafeArea())
        .navigationTitle(logbook?.name ?? "日志本")
        .task { await reload() }
        .refreshable { await reload() }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: importTypes,
            allowsMultipleSelection: false,
            onCompletion: handleImport
        )
        .fileExporter(
            isPresented: $showingExporter,
            document: exportDocument,
            contentType: .data,
            defaultFilename: exportFileName
        ) { result in
            if case .failure(let error) = result { fileError = error.localizedDescription }
            exportDocument = nil
        }
        .alert("操作失败", isPresented: Binding(
            get: { fileError != nil },
            set: { if !$0 { fileError = nil } }
        )) {
            Button("好") { fileError = nil }
        } message: {
            Text(fileError ?? "未知错误")
        }
        .confirmationDialog(
            "丢弃这条未保存 QSO？",
            isPresented: Binding(
                get: { pendingUnsavedDiscard != nil },
                set: { if !$0 { pendingUnsavedDiscard = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("永久丢弃", role: .destructive) {
                guard let attempt = pendingUnsavedDiscard else { return }
                pendingUnsavedDiscard = nil
                discardUnsaved(attempt)
            }
            Button("取消", role: .cancel) { pendingUnsavedDiscard = nil }
        } message: {
            Text("丢弃后无法再从 TX-5DR 的待写入队列恢复。")
        }
    }

    @ViewBuilder
    private var healthSection: some View {
        Section("健康与统计") {
            if let detail {
                LabeledContent("状态", value: detail.health.state)
                LabeledContent("QSO", value: String(detail.statistics.totalQSOs))
                LabeledContent("唯一呼号", value: String(detail.statistics.uniqueCallsigns))
                LabeledContent("操作员", value: String(detail.statistics.totalOperators))
                if let first = detail.statistics.firstQSO {
                    LabeledContent("首次 QSO", value: first)
                }
                if let last = detail.statistics.lastQSO {
                    LabeledContent("最近 QSO", value: last)
                }
            } else {
                ProgressView("读取统计")
            }
        }
    }

    @ViewBuilder
    private var operatorsSection: some View {
        Section("操作员连接") {
            ForEach(session.operators) { radioOperator in
                operatorRow(radioOperator)
            }
        }
    }

    private func operatorRow(_ radioOperator: RadioOperatorConfig) -> some View {
        let connected = detail?.connectedOperators.contains(radioOperator.id) == true
        return HStack {
            VStack(alignment: .leading) {
                Text(radioOperator.myCallsign)
                Text(radioOperator.id)
                    .font(.caption2.monospaced())
                    .foregroundStyle(RadioPalette.muted)
            }
            Spacer()
            if connected {
                Button("断开", role: .destructive) {
                    Task { await session.disconnectOperatorFromLogbook(radioOperator.id) }
                }
            } else {
                Button("连接") {
                    Task { await session.connectOperator(radioOperator.id, to: logbookId) }
                }
            }
        }
        .disabled(!session.isAdmin)
    }

    @ViewBuilder
    private var unsavedSection: some View {
        if !unsavedAttempts.isEmpty {
            Section {
                ForEach(unsavedAttempts) { attempt in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(attempt.callsign).font(.headline.monospaced())
                                Text("\(attempt.mode) · \(latestDate(attempt.createdAt))")
                                    .font(.caption)
                                    .foregroundStyle(RadioPalette.muted)
                            }
                            Spacer()
                            Button("重试") { retryUnsaved(attempt) }
                                .buttonStyle(.borderedProminent)
                                .disabled(recoveryBusy || backup?.mainHealth.writable != true)
                            Button(role: .destructive) { pendingUnsavedDiscard = attempt } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.bordered)
                            .disabled(recoveryBusy)
                        }
                        if let error = attempt.error, !error.isEmpty {
                            Text(error)
                                .font(.caption2)
                                .foregroundStyle(RadioPalette.warning)
                        }
                    }
                    .padding(.vertical, 3)
                }
            } header: {
                Text("未保存 QSO（\(unsavedAttempts.count)）")
            } footer: {
                Text("写入失败的 QSO 保留在 TX-5DR 内存队列；日志本恢复可写后可以重试。")
            }
        }
    }

    @ViewBuilder
    private var transferSection: some View {
        Section("导入与导出") {
            Button { showingImporter = true } label: {
                Label("导入 ADIF / CSV", systemImage: "square.and.arrow.down")
            }
            Button { export(format: "adif") } label: {
                Label("导出 ADIF", systemImage: "square.and.arrow.up")
            }
            Button { export(format: "csv") } label: {
                Label("导出 CSV", systemImage: "tablecells")
            }
        }
    }

    @ViewBuilder
    private var syncSection: some View {
        Section {
            if let callsign = session.keyerCallsign {
                NavigationLink {
                    LogbookSyncProvidersView(logbookId: logbookId, callsign: callsign)
                } label: {
                    HStack {
                        Label("外部日志服务", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        Text(callsign)
                            .font(.caption.monospaced().weight(.semibold))
                            .foregroundStyle(RadioPalette.accent)
                    }
                }
            } else {
                Label("先选择操作员以使用外部日志同步", systemImage: "person.crop.circle.badge.exclamationmark")
                    .foregroundStyle(RadioPalette.muted)
            }
        } header: {
            Text("插件同步")
        } footer: {
            Text("支持 TX-5DR 已安装插件提供的连接测试、上传预检、下载、上传、完整同步及自定义操作页面。")
        }
    }

    @ViewBuilder
    private var backupSection: some View {
        Section {
            if let backup {
                LabeledContent("修订", value: backup.revision)
                LabeledContent("待写入", value: String(backup.pendingMutations))
                if let latest = backup.latest {
                    LabeledContent("最新备份", value: latestDate(latest.createdAt))
                    LabeledContent(
                        "大小",
                        value: ByteCountFormatter.string(fromByteCount: Int64(latest.size), countStyle: .file)
                    )
                }
                Button { Task { await session.createLogbookBackup(id: logbookId) } } label: {
                    Label("立即创建备份", systemImage: "externaldrive.badge.plus")
                }
                .disabled(!backup.capabilities.canCreate || recoveryBusy || serverOperationBusy)
                Button { downloadBackup() } label: {
                    Label("下载最新备份", systemImage: "externaldrive.badge.icloud")
                }
                .disabled(!backup.capabilities.canDownload || recoveryBusy || serverOperationBusy)
                if backup.capabilities.canDownloadPreRestore {
                    Button { downloadPreRestoreBackup() } label: {
                        Label("下载恢复前快照", systemImage: "clock.arrow.circlepath")
                    }
                    .disabled(recoveryBusy || serverOperationBusy)
                }
            } else {
                ProgressView("读取备份状态")
            }
        } header: {
            Text("服务端备份")
        } footer: {
            Text("每次恢复前，TX-5DR 会自动保留一份恢复前快照。")
        }
    }

    @ViewBuilder
    private var restoreSection: some View {
        if session.isAdmin, let backup, backup.capabilities.canRestore {
            Section {
                if let restorePreflight {
                    LabeledContent("当前日志", value: restoreSummary(restorePreflight.main))
                    LabeledContent("备份文件", value: restoreSummary(restorePreflight.backup))
                    LabeledContent("记录变化", value: signed(restorePreflight.recordDelta))
                    LabeledContent("预计丢失", value: String(restorePreflight.estimatedLoss))
                    LabeledContent("预检到期", value: latestDate(restorePreflight.expiresAt))

                    if restorePreflight.highRisk {
                        Label("高风险：备份内容可能少于当前日志本", systemImage: "exclamationmark.octagon.fill")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(RadioPalette.transmit)
                    }

                    Toggle("我了解恢复会替换当前日志本", isOn: $restoreRiskAccepted)
                    TextField("输入日志本 ID：\(logbookId)", text: $restoreConfirmation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button("确认从备份恢复", role: .destructive) { restoreBackup(restorePreflight) }
                        .disabled(!canConfirmRestore || recoveryBusy || serverOperationBusy)
                } else {
                    Text("先比较当前文件与最新备份；确认记录差异后才会开放恢复按钮。")
                        .font(.caption)
                        .foregroundStyle(RadioPalette.muted)
                    Button { prepareRestore(revision: backup.revision) } label: {
                        Label("比较当前日志与备份", systemImage: "arrow.left.arrow.right")
                    }
                    .disabled(recoveryBusy || serverOperationBusy || backup.latest == nil)
                }
            } header: {
                Text("从备份恢复")
            } footer: {
                Text("确认文字区分大小写，必须与日志本 ID 完全一致。预检过期或修订变化时需重新比较。")
            }
        }
    }

    private var logbook: LogbookInfo? { session.logbooks.first { $0.id == logbookId } }
    private var detail: LogbookDetail? { session.logbookDetails[logbookId] }
    private var backup: LogbookBackupStatus? { session.logbookBackups[logbookId] }
    private var unsavedAttempts: [LogbookUnsavedAttempt] {
        (backup?.unsaved ?? []).compactMap { LogbookUnsavedAttempt($0) }
    }
    private var serverOperationBusy: Bool {
        guard let operation = backup?.operation,
              let state = operation["state"]?.stringValue else { return false }
        return state == "pending" || state == "running"
    }
    private var canConfirmRestore: Bool {
        restoreRiskAccepted && restoreConfirmation == logbookId
    }

    private var importTypes: [UTType] {
        [UTType(filenameExtension: "adi"), UTType(filenameExtension: "adif"), .commaSeparatedText, .plainText]
            .compactMap { $0 }
    }

    private func reload() async {
        await session.loadLogbookDetail(id: logbookId)
        await session.loadLogbookBackup(id: logbookId)
    }

    private func export(format: String) {
        Task {
            do {
                let data = try await session.exportLogbook(id: logbookId, format: format)
                exportDocument = TX5DRFileDocument(data: data)
                let base = (logbook?.name ?? "logbook")
                    .replacingOccurrences(of: "[^A-Za-z0-9_-]+", with: "_", options: .regularExpression)
                exportFileName = "\(base.isEmpty ? "logbook" : base).\(format == "csv" ? "csv" : "adi")"
                showingExporter = true
            } catch {
                fileError = error.localizedDescription
            }
        }
    }

    private func downloadBackup() {
        Task {
            do {
                exportDocument = TX5DRFileDocument(data: try await session.downloadLogbookBackup(id: logbookId))
                exportFileName = "\(logbook?.name ?? "logbook")-backup.adi"
                showingExporter = true
            } catch {
                fileError = error.localizedDescription
            }
        }
    }

    private func downloadPreRestoreBackup() {
        Task {
            do {
                exportDocument = TX5DRFileDocument(
                    data: try await session.downloadPreRestoreLogbookBackup(id: logbookId)
                )
                exportFileName = "\(logbook?.name ?? "logbook")-pre-restore.adi"
                showingExporter = true
            } catch {
                fileError = error.localizedDescription
            }
        }
    }

    private func prepareRestore(revision: String) {
        Task {
            recoveryBusy = true
            defer { recoveryBusy = false }
            do {
                restorePreflight = try await session.prepareLogbookRestore(id: logbookId, revision: revision)
                restoreRiskAccepted = false
                restoreConfirmation = ""
                await session.loadLogbookBackup(id: logbookId)
            } catch {
                fileError = error.localizedDescription
            }
        }
    }

    private func restoreBackup(_ preflight: LogbookRestorePreflight) {
        guard canConfirmRestore else { return }
        Task {
            recoveryBusy = true
            defer { recoveryBusy = false }
            do {
                try await session.restoreLogbookBackup(
                    id: logbookId,
                    preflightToken: preflight.preflightToken,
                    confirmation: restoreConfirmation,
                    revision: preflight.revision
                )
                restorePreflight = nil
                restoreRiskAccepted = false
                restoreConfirmation = ""
            } catch {
                fileError = error.localizedDescription
            }
        }
    }

    private func retryUnsaved(_ attempt: LogbookUnsavedAttempt) {
        Task {
            recoveryBusy = true
            defer { recoveryBusy = false }
            do {
                try await session.retryUnsavedQSO(logbookId: logbookId, attemptId: attempt.id)
            } catch {
                fileError = error.localizedDescription
            }
        }
    }

    private func discardUnsaved(_ attempt: LogbookUnsavedAttempt) {
        Task {
            recoveryBusy = true
            defer { recoveryBusy = false }
            do {
                try await session.discardUnsavedQSO(logbookId: logbookId, attemptId: attempt.id)
            } catch {
                fileError = error.localizedDescription
            }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let granted = url.startAccessingSecurityScopedResource()
            defer { if granted { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            Task { _ = await session.importLogbook(id: logbookId, fileName: url.lastPathComponent, data: data) }
        } catch {
            fileError = error.localizedDescription
        }
    }

    private func latestDate(_ milliseconds: Double) -> String {
        let seconds = milliseconds > 10_000_000_000 ? milliseconds / 1_000 : milliseconds
        return Date(timeIntervalSince1970: seconds).formatted(date: .abbreviated, time: .shortened)
    }

    private func restoreSummary(_ summary: LogbookRestoreFileSummary) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(summary.size), countStyle: .file)
        return "\(summary.recordCount) 条 · \(size)"
    }

    private func signed(_ value: Int) -> String { value > 0 ? "+\(value)" : String(value) }
}

private struct LogbookUnsavedAttempt: Identifiable {
    let id: String
    let callsign: String
    let mode: String
    let createdAt: Double
    let error: String?

    init?(_ value: JSONValue) {
        guard let id = value["attemptId"]?.stringValue,
              let callsign = value["callsign"]?.stringValue,
              let mode = value["mode"]?.stringValue,
              let createdAt = value["createdAt"]?.doubleValue else { return nil }
        self.id = id
        self.callsign = callsign
        self.mode = mode
        self.createdAt = createdAt
        error = value["lastError"]?.stringValue ?? value["error"]?.stringValue
    }
}
