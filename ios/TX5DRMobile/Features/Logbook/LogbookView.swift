import SwiftUI

struct LogbookView: View {
    @EnvironmentObject private var session: TX5DRSession
    @State private var search = ""
    @State private var showingNewQSO = false
    @State private var pendingDelete: QSORecord?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.25)
            content
        }
        .background(RadioPalette.background.ignoresSafeArea())
        .navigationTitle("通联日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                NavigationLink {
                    LogbookManagementView()
                } label: {
                    Image(systemName: "books.vertical")
                }
                Button { showingNewQSO = true } label: { Image(systemName: "plus") }
                    .disabled(session.selectedLogbookId == nil)
            }
        }
        .task { await session.loadQSOs() }
        .sheet(isPresented: $showingNewQSO) { NewQSOView() }
        .confirmationDialog(
            "删除这条 QSO？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let pendingDelete { Task { await session.deleteQSO(pendingDelete) } }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(pendingDelete.map { "\($0.callsign) · \($0.mode)" } ?? "")
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                Menu {
                    ForEach(session.logbooks) { logbook in
                        Button {
                            session.selectLogbook(logbook.id)
                        } label: {
                            if logbook.id == session.selectedLogbookId {
                                Label(logbook.name, systemImage: "checkmark")
                            } else {
                                Text(logbook.name)
                            }
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: "book.closed.fill")
                        Text(selectedLogbook?.name ?? "选择日志本")
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(RadioPalette.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                Spacer()
                if let health = selectedLogbook?.health {
                    Label(health.state, systemImage: health.writable ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(health.writable ? RadioPalette.accent : RadioPalette.warning)
                }
            }

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(RadioPalette.muted)
                TextField("按呼号筛选", text: $search)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .onSubmit { Task { await session.loadQSOs(callsign: search) } }
                if !search.isEmpty {
                    Button {
                        search = ""
                        Task { await session.loadQSOs() }
                    } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(RadioPalette.muted)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RadioPalette.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(14)
    }

    @ViewBuilder
    private var content: some View {
        if session.logbooks.isEmpty {
            ContentUnavailableView(
                "没有可用日志本",
                systemImage: "book.closed",
                description: Text("请先在 TX-5DR 服务端创建并连接日志本。")
            )
        } else if session.qsos.isEmpty {
            ContentUnavailableView(
                "暂无 QSO",
                systemImage: "text.book.closed",
                description: Text("数字模式自动完成或手动补录后会显示在这里。")
            )
        } else {
            List {
                ForEach(session.qsos) { qso in
                    QSOListRow(qso: qso)
                        .listRowBackground(RadioPalette.panel)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { pendingDelete = qso } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable { await session.loadQSOs(callsign: search.isEmpty ? nil : search) }
        }
    }

    private var selectedLogbook: LogbookInfo? {
        guard let id = session.selectedLogbookId else { return nil }
        return session.logbooks.first { $0.id == id }
    }
}
private struct QSOListRow: View {
    let qso: QSORecord

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(qso.callsign)
                        .font(.headline.monospaced())
                    if let grid = qso.grid, !grid.isEmpty {
                        Text(grid)
                            .font(.caption.monospaced())
                            .foregroundStyle(RadioPalette.cyan)
                    }
                }
                Text(dateText)
                    .font(.caption)
                    .foregroundStyle(RadioPalette.muted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(qso.submode ?? qso.mode)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(RadioPalette.accent)
                Text(String(format: "%.6f MHz", qso.frequency / 1_000_000))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(RadioPalette.muted)
            }
        }
        .padding(.vertical, 4)
    }

    private var dateText: String {
        let seconds = qso.startTime > 10_000_000_000 ? qso.startTime / 1_000 : qso.startTime
        return Date(timeIntervalSince1970: seconds).formatted(date: .abbreviated, time: .shortened)
    }
}

private struct NewQSOView: View {
    @EnvironmentObject private var session: TX5DRSession
    @EnvironmentObject private var radio: RadioWebSocket
    @Environment(\.dismiss) private var dismiss
    @State private var callsign = ""
    @State private var grid = ""
    @State private var frequencyMHz = "14.074000"
    @State private var mode = "FT8"
    @State private var startTime = Date()
    @State private var reportSent = ""
    @State private var reportReceived = ""
    @State private var notes = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("通联") {
                    TextField("呼号", text: $callsign)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    TextField("网格（可选）", text: $grid)
                        .textInputAutocapitalization(.characters)
                    TextField("频率 MHz", text: $frequencyMHz)
                        .keyboardType(.decimalPad)
                    Picker("模式", selection: $mode) {
                        ForEach(["FT8", "FT4", "SSB", "CW", "FM", "AM"], id: \.self) { Text($0) }
                    }
                    DatePicker("开始时间", selection: $startTime)
                }
                Section("信号报告") {
                    TextField("发送", text: $reportSent)
                    TextField("接收", text: $reportReceived)
                }
                Section("备注") {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                }
            }
            .navigationTitle("补录 QSO")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(!isValid)
                }
            }
            .onAppear {
                if let hz = radio.frequency?.frequency {
                    frequencyMHz = String(format: "%.6f", hz / 1_000_000)
                }
                mode = radio.currentMode.name
            }
        }
    }

    private var isValid: Bool {
        !callsign.trimmingCharacters(in: .whitespaces).isEmpty && (Double(frequencyMHz) ?? 0) > 0
    }

    private func save() {
        guard let mhz = Double(frequencyMHz) else { return }
        let request = CreateQSORequest(
            callsign: callsign.uppercased(),
            frequency: mhz * 1_000_000,
            mode: mode,
            submode: nil,
            startTime: startTime.timeIntervalSince1970 * 1_000,
            endTime: nil,
            grid: grid.isEmpty ? nil : grid.uppercased(),
            qth: nil,
            reportSent: reportSent.isEmpty ? nil : reportSent,
            reportReceived: reportReceived.isEmpty ? nil : reportReceived,
            messageHistory: [],
            comment: nil,
            notes: notes.isEmpty ? nil : notes
        )
        Task {
            await session.createQSO(request)
            if session.errorMessage == nil { dismiss() }
        }
    }
}
