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

    var body: some View {
        List {
            healthSection
            operatorsSection
            transferSection
            backupSection
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
        .alert("文件操作失败", isPresented: Binding(
            get: { fileError != nil },
            set: { if !$0 { fileError = nil } }
        )) {
            Button("好") { fileError = nil }
        } message: {
            Text(fileError ?? "未知错误")
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
                .disabled(!backup.capabilities.canCreate)
                Button { downloadBackup() } label: {
                    Label("下载最新备份", systemImage: "externaldrive.badge.icloud")
                }
                .disabled(!backup.capabilities.canDownload)
            } else {
                ProgressView("读取备份状态")
            }
        } header: {
            Text("服务端备份")
        } footer: {
            Text("恢复备份会覆盖日志本，原生恢复流程将在展示预检差异并二次确认后才允许执行。")
        }
    }

    private var logbook: LogbookInfo? { session.logbooks.first { $0.id == logbookId } }
    private var detail: LogbookDetail? { session.logbookDetails[logbookId] }
    private var backup: LogbookBackupStatus? { session.logbookBackups[logbookId] }

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
}
