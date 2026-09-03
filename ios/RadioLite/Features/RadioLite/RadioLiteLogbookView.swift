import MapKit
import SwiftUI
import UniformTypeIdentifiers

struct RadioLiteLogbookView: View {
    @EnvironmentObject private var session: RadioLiteSession
    @State private var search = ""
    @State private var showManualQSO = false
    @State private var showImporter = false
    @State private var exportURL: URL?
    @State private var showExporter = false
    @State private var operationStatus: String?
    @State private var importing = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        List {
            Section {
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(RadioPalette.muted)
                    TextField("搜索呼号、网格或模式", text: $search)
                        .focused($searchFocused)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundStyle(RadioPalette.muted)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(RadioPalette.panelRaised, in: RoundedRectangle(cornerRadius: 12))
                .listRowBackground(Color.clear)
                .listRowInsets(.init(top: 8, leading: 14, bottom: 4, trailing: 14))

                HStack {
                    Label("\(session.qsoTotal) QSO", systemImage: "book.closed.fill")
                    Spacer()
                    NavigationLink {
                        RadioLiteGridMapView()
                    } label: {
                        Label("\(session.grids.count) 网格", systemImage: "map.fill")
                    }
                }
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(RadioPalette.accent)
                .listRowBackground(Color.clear)
            }

            if let operationStatus {
                Section {
                    Label(operationStatus, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(RadioPalette.accent)
                }
                .listRowBackground(RadioPalette.panel)
            }

            Section("最近通联") {
                if filteredQSOs.isEmpty {
                    ContentUnavailableView(
                        search.isEmpty ? "还没有日志" : "没有匹配结果",
                        systemImage: "book.closed"
                    )
                    .frame(minHeight: 190)
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(filteredQSOs) { qso in
                        RadioLiteQSORow(qso: qso)
                            .listRowBackground(RadioPalette.panel)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .background(RadioPalette.background.ignoresSafeArea())
        .navigationTitle("ADIF 日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button {
                        Task { await prepareExport() }
                    } label: { Label("导出 ADIF", systemImage: "square.and.arrow.up") }
                    if session.isAdmin {
                        Button { showImporter = true } label: {
                            Label(importing ? "导入中…" : "导入 ADIF", systemImage: "square.and.arrow.down")
                        }
                        .disabled(importing)
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { Task { await session.refreshLogs() } } label: { Image(systemName: "arrow.clockwise") }
                Button { showManualQSO = true } label: { Image(systemName: "plus") }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { searchFocused = false }
            }
        }
        .refreshable { await session.refreshLogs() }
        .task { if session.qsos.isEmpty { await session.refreshLogs() } }
        .sheet(isPresented: $showManualQSO) { RadioLiteManualQSOView() }
        .sheet(isPresented: $showExporter) {
            if let exportURL {
                NavigationStack {
                    VStack(spacing: 22) {
                        Image(systemName: "doc.badge.arrow.up")
                            .font(.system(size: 48))
                            .foregroundStyle(RadioPalette.accent)
                        Text("ADIF 已准备好")
                            .font(.title2.bold())
                        ShareLink(item: exportURL) {
                            Label("共享 radio-lite-log.adi", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(RadioActionButtonStyle(tint: RadioPalette.accent, prominent: true))
                    }
                    .padding(24)
                    .navigationTitle("导出日志")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showExporter = false } } }
                }
                .presentationDetents([.medium])
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [
                UTType(filenameExtension: "adi") ?? .data,
                UTType(filenameExtension: "adif") ?? .data,
                .plainText,
                .data,
            ]
        ) { result in
            Task { await importFile(result) }
        }
    }

    private var filteredQSOs: [RadioLiteQSORecord] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !query.isEmpty else { return session.qsos }
        return session.qsos.filter {
            $0.call.uppercased().contains(query)
                || ($0.grid?.uppercased().contains(query) == true)
                || $0.mode.uppercased().contains(query)
                || ($0.submode?.uppercased().contains(query) == true)
        }
    }

    private func prepareExport() async {
        do {
            exportURL = try await session.exportADIF()
            showExporter = true
        } catch {
            session.errorMessage = error.localizedDescription
        }
    }

    private func importFile(_ result: Result<URL, Error>) async {
        guard !importing else { return }
        importing = true
        defer { importing = false }
        do {
            let url = try result.get()
            let counts = try await session.importADIF(from: url)
            operationStatus = "导入 \(counts.0) 条，跳过 \(counts.1) 条重复记录"
        } catch {
            session.errorMessage = "ADIF 导入失败：\(error.localizedDescription)"
        }
    }
}

private struct RadioLiteQSORow: View {
    let qso: RadioLiteQSORecord

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(qso.call)
                    .font(.headline.monospaced())
                if let grid = qso.grid {
                    Text(grid)
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(RadioPalette.cyan)
                }
                Spacer()
                Text(qso.submode ?? qso.mode)
                    .font(.caption.monospaced().weight(.bold))
                    .foregroundStyle(RadioPalette.accent)
            }
            HStack {
                Label(Date(timeIntervalSince1970: Double(qso.startedAtMs) / 1_000).formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                Spacer()
                if let frequency = qso.frequencyHz {
                    Text(String(format: "%.6f MHz", Double(frequency) / 1_000_000))
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(RadioPalette.muted)
            HStack(spacing: 8) {
                Text(qso.source.replacingOccurrences(of: "_", with: " "))
                if let sent = qso.rstSent { Text("发 \(sent)") }
                if let received = qso.rstReceived { Text("收 \(received)") }
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(RadioPalette.muted)
        }
        .padding(.vertical, 5)
    }
}

struct RadioLiteManualQSOView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: RadioLiteSession
    @State private var call = ""
    @State private var grid = ""
    @State private var frequencyMHz = ""
    @State private var mode = "SSB"
    @State private var submode = "USB"
    @State private var rstSent = "59"
    @State private var rstReceived = "59"
    @State private var power = ""
    @State private var comment = ""
    @State private var startedAt = Date()
    @State private var endedAt = Date()
    @State private var includeEnd = true
    @State private var saving = false
    @State private var formError: String?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case call
        case grid
        case frequencyMHz
        case rstSent
        case rstReceived
        case power
        case comment
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("对方") {
                    TextField("呼号", text: $call)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .call)
                    TextField("网格（可选）", text: $grid)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .grid)
                }
                Section("电台") {
                    TextField("频率 MHz", text: $frequencyMHz)
                        .keyboardType(.decimalPad)
                        .focused($focusedField, equals: .frequencyMHz)
                    Picker("模式", selection: $mode) {
                        ForEach(["SSB", "CW", "AM", "FM", "DIGITAL"], id: \.self) { Text($0) }
                    }
                    if mode == "SSB" {
                        Picker("子模式", selection: $submode) {
                            Text("USB").tag("USB")
                            Text("LSB").tag("LSB")
                        }
                    }
                    HStack {
                        TextField("发送报告", text: $rstSent)
                            .focused($focusedField, equals: .rstSent)
                        TextField("接收报告", text: $rstReceived)
                            .focused($focusedField, equals: .rstReceived)
                    }
                    TextField("功率 W（可选）", text: $power)
                        .keyboardType(.decimalPad)
                        .focused($focusedField, equals: .power)
                }
                Section("时间") {
                    DatePicker("开始", selection: $startedAt)
                    Toggle("记录结束时间", isOn: $includeEnd)
                    if includeEnd { DatePicker("结束", selection: $endedAt) }
                }
                Section("备注") {
                    TextEditor(text: $comment)
                        .frame(minHeight: 90)
                        .focused($focusedField, equals: .comment)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    if let formError {
                        Label(formError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(RadioPalette.transmit)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Spacer()
                        Button {
                            focusedField = nil
                        } label: {
                            Label("收起键盘", systemImage: "keyboard.chevron.compact.down")
                        }
                        .buttonStyle(.bordered)
                        .disabled(focusedField == nil)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(.ultraThinMaterial)
                .overlay(alignment: .top) { Divider().opacity(0.35) }
            }
            .navigationTitle("手动记录语音 QSO")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "保存中" : "保存") {
                        focusedField = nil
                        Task { await save() }
                    }
                    .disabled(saving)
                }
            }
        }
        .onAppear {
            if let state = session.rigState {
                frequencyMHz = String(format: "%.6f", Double(state.frequencyHz) / 1_000_000)
                if ["USB", "LSB"].contains(state.mode) {
                    mode = "SSB"
                    submode = state.mode
                } else {
                    mode = state.mode
                    submode = ""
                }
            }
        }
    }

    private var form: RadioLiteManualQSOForm {
        RadioLiteManualQSOForm(
            radioId: session.selectedRadioId,
            call: call,
            grid: grid,
            frequencyMHz: frequencyMHz,
            mode: mode,
            submode: submode,
            rstSent: rstSent,
            rstReceived: rstReceived,
            powerWatts: power,
            comment: comment,
            startedAt: startedAt,
            endedAt: includeEnd ? endedAt : nil
        )
    }

    private func save() async {
        focusedField = nil
        formError = nil
        let request: RadioLiteManualQSO
        do {
            request = try form.makeRequest()
        } catch {
            formError = error.localizedDescription
            return
        }

        saving = true
        defer { saving = false }
        do {
            try await session.addManualQSO(request)
            dismiss()
        } catch {
            formError = "保存失败：\(error.localizedDescription)"
        }
    }
}

struct RadioLiteGridMapView: View {
    @EnvironmentObject private var session: RadioLiteSession
    @State private var camera: MapCameraPosition = .automatic
    @State private var selected: RadioLiteGridSummary?

    var body: some View {
        Map(position: $camera) {
            ForEach(session.grids.prefix(600)) { item in
                MapPolygon(coordinates: coordinates(item))
                    .foregroundStyle(RadioPalette.accent.opacity(fillOpacity(item.qsoCount)))
                    .stroke(RadioPalette.accent.opacity(0.42), lineWidth: 0.7)
                Annotation(item.grid, coordinate: CLLocationCoordinate2D(latitude: item.latitude, longitude: item.longitude)) {
                    Button { selected = item } label: {
                        VStack(spacing: 2) {
                            Text("\(item.qsoCount)")
                                .font(.caption2.bold().monospacedDigit())
                                .frame(minWidth: 25, minHeight: 25)
                                .foregroundStyle(.black)
                                .background(RadioPalette.accent, in: Circle())
                            Text(item.grid)
                                .font(.caption2.monospaced().bold())
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.black.opacity(0.72), in: Capsule())
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .mapStyle(.standard)
        .mapControls { MapCompass(); MapScaleView(); MapPitchToggle() }
        .navigationTitle("通联网格")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Label("\(session.grids.count) 网格", systemImage: "square.grid.3x3")
                Spacer()
                Text("服务端 ADIF 聚合")
            }
            .font(.caption.weight(.semibold))
            .padding(12)
            .background(.ultraThinMaterial)
        }
        .sheet(item: $selected) { item in
            NavigationStack {
                List {
                    LabeledContent("网格", value: item.grid)
                    LabeledContent("QSO", value: String(item.qsoCount))
                    LabeledContent("最近", value: Date(timeIntervalSince1970: Double(item.lastQsoAtMs) / 1_000).formatted())
                    Section("频段") {
                        ForEach(item.bands.sorted(by: { $0.value > $1.value }), id: \.key) {
                            LabeledContent($0.key, value: String($0.value))
                        }
                    }
                    Section("模式") {
                        ForEach(item.modes.sorted(by: { $0.value > $1.value }), id: \.key) {
                            LabeledContent($0.key, value: String($0.value))
                        }
                    }
                }
                .navigationTitle(item.grid)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { selected = nil } } }
            }
            .presentationDetents([.medium])
        }
    }

    private func coordinates(_ item: RadioLiteGridSummary) -> [CLLocationCoordinate2D] {
        let halfLat = item.latitudeSpan / 2
        let halfLon = item.longitudeSpan / 2
        return [
            .init(latitude: item.latitude - halfLat, longitude: item.longitude - halfLon),
            .init(latitude: item.latitude - halfLat, longitude: item.longitude + halfLon),
            .init(latitude: item.latitude + halfLat, longitude: item.longitude + halfLon),
            .init(latitude: item.latitude + halfLat, longitude: item.longitude - halfLon),
        ]
    }

    private func fillOpacity(_ count: Int) -> Double {
        min(0.3, 0.07 + log10(Double(max(1, count))) * 0.06)
    }
}
