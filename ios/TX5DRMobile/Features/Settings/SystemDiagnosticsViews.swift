import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct ServerCPUProfileView: View {
    @EnvironmentObject private var session: TX5DRSession

    @State private var status: ServerCPUProfileStatus?
    @State private var busy = false
    @State private var exportDocument: TX5DRBinaryDocument?
    @State private var exportFileName = "tx5dr-cpu-profile.cpuprofile"
    @State private var showingExporter = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("采样状态") {
                if let status {
                    LabeledContent("状态") {
                        Label(stateLabel(status.state), systemImage: stateIcon(status.state))
                            .foregroundStyle(stateColor(status.state))
                    }
                    LabeledContent("运行环境", value: runtimeLabel(status.distribution))
                    LabeledContent("配置来源", value: status.source)
                    if let captureID = status.captureId {
                        LabeledContent("采样 ID", value: captureID)
                    }
                    if let requestedAt = status.requestedAt {
                        LabeledContent("请求时间", value: formattedTimestamp(requestedAt))
                    }
                    if let startedAt = status.startedAt {
                        LabeledContent("开始时间", value: formattedTimestamp(startedAt))
                    }
                    if let completedAt = status.completedAt {
                        LabeledContent("完成时间", value: formattedTimestamp(completedAt))
                    }
                } else {
                    ProgressView("正在读取诊断状态…")
                }
            }

            if let status {
                Section("诊断流程") {
                    Text(flowDescription(status))
                        .font(.subheadline)
                    if status.state == .armed || status.state == .running {
                        LabeledContent(
                            status.state == .armed ? "建议启动操作" : "建议结束操作",
                            value: status.state == .armed
                                ? status.recommendedStartAction
                                : status.recommendedFinishAction
                        )
                    }

                    switch status.state {
                    case .idle, .interrupted, .missing:
                        Button {
                            Task { await arm() }
                        } label: {
                            Label("准备 CPU 采样", systemImage: "record.circle")
                        }
                        .disabled(busy)
                    case .armed, .running:
                        Button(role: .destructive) {
                            Task { await cancel() }
                        } label: {
                            Label("取消本次采样", systemImage: "xmark.circle")
                        }
                        .disabled(busy)
                    case .completed:
                        Button {
                            Task { await download() }
                        } label: {
                            Label("导出诊断文件", systemImage: "square.and.arrow.down")
                        }
                        .disabled(busy || status.profilePath == nil)

                        Button {
                            Task { await dismiss() }
                        } label: {
                            Label("完成并清除结果", systemImage: "checkmark.circle")
                        }
                        .disabled(busy)
                    case .environmentOverride:
                        Label("服务端由环境变量开启性能采样，此处只读。", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(RadioPalette.warning)
                    }
                } footer: {
                    Text("引导采样通常需要按上方建议重启 TX-5DR。iOS App 不会擅自重启远端服务。")
                }

                Section("文件位置") {
                    LabeledContent("服务端目录", value: status.outputDir)
                    if let host = status.hostOutputDirHint {
                        LabeledContent("宿主机目录", value: host)
                    }
                    if let path = status.profilePath {
                        LabeledContent("诊断文件", value: path)
                    }
                    if let hostPath = status.hostProfilePathHint {
                        LabeledContent("宿主机文件", value: hostPath)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(RadioPalette.background.ignoresSafeArea())
        .navigationTitle("CPU 性能诊断")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button {
                Task { await load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(busy)
        }
        .task { await load() }
        .task(id: status?.state.rawValue) {
            guard status?.state == .armed || status?.state == .running else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                await load(silent: true)
            }
        }
        .refreshable { await load() }
        .fileExporter(
            isPresented: $showingExporter,
            document: exportDocument,
            contentType: UTType(filenameExtension: "cpuprofile") ?? .data,
            defaultFilename: exportFileName
        ) { result in
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
        }
        .alert("性能诊断失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "未知错误")
        }
    }

    private func load(silent: Bool = false) async {
        guard !busy else { return }
        if !silent { busy = true }
        defer { if !silent { busy = false } }
        do { status = try await session.fetchServerCPUProfileStatus() }
        catch { if !silent { errorMessage = error.localizedDescription } }
    }

    private func arm() async {
        await perform {
            status = try await session.armServerCPUProfile()
            session.noticeMessage = "CPU 采样已准备，请按页面建议操作 TX-5DR"
        }
    }

    private func cancel() async {
        await perform {
            status = try await session.cancelServerCPUProfile()
            session.noticeMessage = "CPU 采样已取消"
        }
    }

    private func dismiss() async {
        await perform {
            status = try await session.dismissServerCPUProfile()
            session.noticeMessage = "CPU 诊断结果已清除"
        }
    }

    private func download() async {
        await perform {
            let data = try await session.downloadServerCPUProfile()
            exportDocument = TX5DRBinaryDocument(data: data)
            let suffix = status?.captureId?.replacingOccurrences(
                of: "[^A-Za-z0-9_-]",
                with: "-",
                options: .regularExpression
            )
            exportFileName = "tx5dr-cpu-profile\(suffix.map { "-\($0)" } ?? "").cpuprofile"
            showingExporter = true
        }
    }

    private func perform(_ operation: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do { try await operation() }
        catch { errorMessage = error.localizedDescription }
    }

    private func stateLabel(_ state: ServerCPUProfileStatus.State) -> String {
        switch state {
        case .idle: "空闲"
        case .armed: "等待重启开始"
        case .running: "采样中"
        case .completed: "已完成"
        case .interrupted: "已中断"
        case .missing: "文件缺失"
        case .environmentOverride: "外部配置"
        }
    }

    private func stateIcon(_ state: ServerCPUProfileStatus.State) -> String {
        switch state {
        case .idle: "circle"
        case .armed: "record.circle"
        case .running: "waveform.path.ecg"
        case .completed: "checkmark.circle.fill"
        case .interrupted, .missing: "exclamationmark.triangle.fill"
        case .environmentOverride: "lock.fill"
        }
    }

    private func stateColor(_ state: ServerCPUProfileStatus.State) -> Color {
        switch state {
        case .completed: RadioPalette.accent
        case .armed, .environmentOverride: RadioPalette.warning
        case .running: RadioPalette.cyan
        case .interrupted, .missing: RadioPalette.transmit
        case .idle: RadioPalette.muted
        }
    }

    private func runtimeLabel(_ value: String) -> String {
        [
            "electron": "Electron",
            "docker": "Docker",
            "android-bridge": "Android Bridge",
            "linux-service": "Linux 服务",
            "web-dev": "开发服务器",
        ][value] ?? value
    }

    private func flowDescription(_ status: ServerCPUProfileStatus) -> String {
        switch status.state {
        case .idle: "准备采样后，按 TX-5DR 给出的操作重启服务并复现 CPU 过高问题。"
        case .armed: "采样已准备。按建议操作启动服务后，TX-5DR 会开始记录。"
        case .running: "正在记录 CPU Profile。复现问题后按建议操作结束采样。"
        case .completed: "诊断文件已生成，可直接保存到 iPhone 或 iCloud Drive。"
        case .interrupted: "上一次采样没有正常结束，可以清理后重新开始。"
        case .missing: "状态记录存在，但服务端诊断文件已找不到。"
        case .environmentOverride: "性能采样由服务端外部配置管理，App 不会修改它。"
        }
    }

    private func formattedTimestamp(_ value: Double) -> String {
        Date(timeIntervalSince1970: value / 1_000).formatted(date: .abbreviated, time: .standard)
    }
}

struct DiagnosticLogUploadView: View {
    @EnvironmentObject private var session: TX5DRSession

    @State private var sources: [DiagnosticLogSource] = []
    @State private var selectedSourceID = ""
    @State private var preset: DiagnosticRangePreset = .oneHour
    @State private var customFrom = Date().addingTimeInterval(-3_600)
    @State private var customTo = Date()
    @State private var feedback = ""
    @State private var receipt: DiagnosticUploadReceipt?
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("日志来源") {
                if sources.isEmpty, busy {
                    ProgressView("正在读取可用日志…")
                } else if sources.isEmpty {
                    ContentUnavailableView("没有可上传日志", systemImage: "doc.text.magnifyingglass")
                } else {
                    Picker("来源", selection: $selectedSourceID) {
                        ForEach(sources) { source in
                            Text(sourceLabel(source)).tag(source.id)
                        }
                    }

                    if let source = selectedSource {
                        LabeledContent("文件", value: source.fileName)
                        LabeledContent("文件数量", value: String(source.fileCount))
                        LabeledContent("总大小", value: ByteCountFormatter.string(
                            fromByteCount: Int64(source.totalBytes),
                            countStyle: .file
                        ))
                        LabeledContent("可用范围", value: sourceCoverage(source))
                    }
                }
            }

            Section("时间范围") {
                Picker("范围", selection: $preset) {
                    ForEach(DiagnosticRangePreset.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }

                if preset == .custom {
                    DatePicker("开始", selection: $customFrom)
                    DatePicker("结束", selection: $customTo)
                }

                if let range = selectedRange {
                    LabeledContent("开始", value: range.from.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("结束", value: range.to.formatted(date: .abbreviated, time: .shortened))
                    if !rangeOverlapsSelectedSource(range) {
                        Label("所选时间不在服务端现有日志范围内", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(RadioPalette.warning)
                    }
                } else {
                    Label("时间范围无效：结束必须晚于开始、不能晚于当前时间，且最多 7 天。", systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(RadioPalette.transmit)
                }
            }

            Section {
                TextField("请描述问题、发生时间和当时的操作", text: $feedback, axis: .vertical)
                    .lineLimit(4...8)
                    .onChange(of: feedback) { _, value in
                        if value.count > 2_000 { feedback = String(value.prefix(2_000)) }
                    }
                Text("\(feedback.count) / 2000")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(RadioPalette.muted)
            } header: {
                Text("问题描述（可选）")
            } footer: {
                Text("上传由 TX-5DR 服务端执行。提交前请确认日志中没有你不希望分享的信息。")
            }

            if let receipt {
                Section("上传回执") {
                    Label("日志上传成功", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(RadioPalette.accent)
                    LabeledContent("上传 ID", value: receipt.uploadId)
                    LabeledContent("日志行数", value: String(receipt.lineCount))
                    LabeledContent("保留至", value: retainedUntil(receipt.retainedUntil))
                }
            }

            Section {
                Button {
                    Task { await upload() }
                } label: {
                    HStack {
                        Spacer()
                        if busy { ProgressView().padding(.trailing, 4) }
                        Label("上传诊断日志", systemImage: "icloud.and.arrow.up")
                        Spacer()
                    }
                }
                .disabled(!canUpload)
            }
        }
        .scrollContentBackground(.hidden)
        .background(RadioPalette.background.ignoresSafeArea())
        .navigationTitle("诊断日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button {
                Task { await load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(busy)
        }
        .task { await load() }
        .refreshable { await load() }
        .alert("日志操作失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "未知错误")
        }
    }

    private var selectedSource: DiagnosticLogSource? {
        sources.first { $0.id == selectedSourceID }
    }

    private var selectedRange: (from: Date, to: Date)? {
        let to = preset == .custom ? customTo : Date()
        let from = preset == .custom ? customFrom : to.addingTimeInterval(-preset.duration)
        guard from < to,
              to <= Date().addingTimeInterval(60),
              to.timeIntervalSince(from) <= 7 * 24 * 3_600 else { return nil }
        return (from, to)
    }

    private var canUpload: Bool {
        guard !busy, !selectedSourceID.isEmpty, let range = selectedRange else { return false }
        return rangeOverlapsSelectedSource(range)
    }

    private func load() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            sources = try await session.fetchDiagnosticLogSources()
            if !sources.contains(where: { $0.id == selectedSourceID }) {
                selectedSourceID = sources.first(where: { $0.id == "server" })?.id ?? sources.first?.id ?? ""
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func upload() async {
        guard let range = selectedRange, canUpload else { return }
        busy = true
        defer { busy = false }
        do {
            receipt = try await session.uploadDiagnosticLogs(DiagnosticUploadRequest(
                sourceId: selectedSourceID,
                fromMs: range.from.timeIntervalSince1970 * 1_000,
                toMs: range.to.timeIntervalSince1970 * 1_000,
                feedback: feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil
                    : feedback.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
            session.noticeMessage = "诊断日志已上传"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func rangeOverlapsSelectedSource(_ range: (from: Date, to: Date)) -> Bool {
        guard let source = selectedSource,
              let availableFrom = source.availableFromMs,
              let availableTo = source.availableToMs else { return true }
        let fromMs = range.from.timeIntervalSince1970 * 1_000
        let toMs = range.to.timeIntervalSince1970 * 1_000
        return toMs >= availableFrom && fromMs <= availableTo
    }

    private func sourceLabel(_ source: DiagnosticLogSource) -> String {
        let label = [
            "server": "TX-5DR 服务端",
            "electron-main": "Electron 主进程",
            "electron-renderer": "Electron 网页进程",
        ][source.id] ?? source.id
        return "\(label) · \(source.fileName)"
    }

    private func sourceCoverage(_ source: DiagnosticLogSource) -> String {
        guard let from = source.availableFromMs, let to = source.availableToMs else { return "未知" }
        let start = Date(timeIntervalSince1970: from / 1_000).formatted(date: .numeric, time: .shortened)
        let end = Date(timeIntervalSince1970: to / 1_000).formatted(date: .numeric, time: .shortened)
        return "\(start) – \(end)"
    }

    private func retainedUntil(_ value: JSONValue) -> String {
        if let milliseconds = value.doubleValue {
            return Date(timeIntervalSince1970: milliseconds / 1_000).formatted(date: .abbreviated, time: .standard)
        }
        if let text = value.stringValue,
           let date = ISO8601DateFormatter().date(from: text) {
            return date.formatted(date: .abbreviated, time: .standard)
        }
        return value.stringValue ?? value.prettyPrinted
    }
}

struct StorageManagementView: View {
    @EnvironmentObject private var session: TX5DRSession

    @State private var status: JSONValue?
    @State private var summary: JSONValue?
    @State private var dates: [String] = []
    @State private var selectedDate = ""
    @State private var records: JSONValue?
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("持久化状态") {
                LabeledContent("状态") {
                    Label(
                        storageEnabled ? "已启用" : "已停用",
                        systemImage: storageEnabled ? "checkmark.circle.fill" : "pause.circle.fill"
                    )
                    .foregroundStyle(storageEnabled ? RadioPalette.accent : RadioPalette.warning)
                }
                if let totalDates = summary?["data"]?["totalDates"]?.intValue {
                    LabeledContent("有记录日期", value: String(totalDates))
                }
                if let totalRecords = summary?["data"]?["totalRecordsRecent"]?.intValue {
                    LabeledContent("近 7 日记录", value: String(totalRecords))
                }
                if let totalFrames = summary?["data"]?["totalFramesRecent"]?.intValue {
                    LabeledContent("近 7 日帧数", value: String(totalFrames))
                }

                Button {
                    Task { await toggleStorage() }
                } label: {
                    Label(storageEnabled ? "停用持久化" : "启用持久化", systemImage: storageEnabled ? "pause.fill" : "play.fill")
                }
                .disabled(busy)

                Button {
                    Task { await flush() }
                } label: {
                    Label("立即刷新写入缓冲区", systemImage: "arrow.down.doc.fill")
                }
                .disabled(busy || !storageEnabled)
            }

            Section("按日期查看") {
                if dates.isEmpty {
                    Text("尚无持久化记录")
                        .foregroundStyle(RadioPalette.muted)
                } else {
                    Picker("日期", selection: $selectedDate) {
                        ForEach(dates, id: \.self) { date in
                            Text(date).tag(date)
                        }
                    }
                    Button {
                        Task { await loadRecords() }
                    } label: {
                        Label("读取所选日期", systemImage: "doc.text.magnifyingglass")
                    }
                    .disabled(selectedDate.isEmpty || busy)
                }

                JSONSnapshotDisclosure(title: "日期记录与统计", value: records)
            }

            Section("原始状态") {
                JSONSnapshotDisclosure(title: "存储状态", value: status)
                JSONSnapshotDisclosure(title: "存储摘要", value: summary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(RadioPalette.background.ignoresSafeArea())
        .navigationTitle("解码存储")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button {
                Task { await load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(busy)
        }
        .task { await load() }
        .refreshable { await load() }
        .onChange(of: selectedDate) { _, _ in records = nil }
        .alert("存储操作失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "未知错误")
        }
    }

    private var storageEnabled: Bool {
        status?["data"]?["enabled"]?.boolValue
            ?? summary?["data"]?["enabled"]?.boolValue
            ?? false
    }

    private func load() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        var failures: [String] = []
        do { status = try await session.fetchStorageStatus() }
        catch { failures.append("状态：\(error.localizedDescription)") }
        do { summary = try await session.fetchStorageSummary() }
        catch { failures.append("摘要：\(error.localizedDescription)") }
        do {
            let response = try await session.fetchStorageDates()
            dates = response["data"]?["dates"]?.arrayValue?.compactMap(\.stringValue) ?? []
            if !dates.contains(selectedDate) { selectedDate = dates.last ?? "" }
        } catch {
            failures.append("日期：\(error.localizedDescription)")
        }
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
    }

    private func toggleStorage() async {
        await perform {
            status = try await session.setStorageEnabled(!storageEnabled)
            summary = try await session.fetchStorageSummary()
            session.noticeMessage = storageEnabled ? "解码持久化已启用" : "解码持久化已停用"
        }
    }

    private func flush() async {
        await perform {
            _ = try await session.flushStorage()
            status = try await session.fetchStorageStatus()
            session.noticeMessage = "存储缓冲区已写入"
        }
    }

    private func loadRecords() async {
        guard !selectedDate.isEmpty else { return }
        await perform {
            records = try await session.fetchStorageRecords(date: selectedDate)
        }
    }

    private func perform(_ operation: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do { try await operation() }
        catch { errorMessage = error.localizedDescription }
    }
}

private enum DiagnosticRangePreset: String, CaseIterable, Identifiable {
    case fifteenMinutes
    case oneHour
    case sixHours
    case oneDay
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fifteenMinutes: "最近 15 分钟"
        case .oneHour: "最近 1 小时"
        case .sixHours: "最近 6 小时"
        case .oneDay: "最近 24 小时"
        case .custom: "自定义"
        }
    }

    var duration: TimeInterval {
        switch self {
        case .fifteenMinutes: 15 * 60
        case .oneHour: 60 * 60
        case .sixHours: 6 * 60 * 60
        case .oneDay: 24 * 60 * 60
        case .custom: 0
        }
    }
}

struct TX5DRBinaryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }

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
