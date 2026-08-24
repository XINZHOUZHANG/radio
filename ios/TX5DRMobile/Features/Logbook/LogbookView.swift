import SwiftUI

struct LogbookView: View {
    @EnvironmentObject private var session: TX5DRSession

    @State private var search = ""
    @State private var query = LogbookQSOQuery()
    @State private var showingFilters = false
    @State private var showingNewQSO = false
    @State private var editingQSO: QSORecord?
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
        .task(id: session.selectedLogbookId) {
            query.offset = 0
            await session.loadQSOs(query: query)
        }
        .sheet(isPresented: $showingNewQSO) {
            NavigationStack { QSOEditorView(qso: nil) }
                .environmentObject(session)
                .environmentObject(session.radio)
        }
        .sheet(item: $editingQSO) { qso in
            NavigationStack { QSOEditorView(qso: qso) }
                .environmentObject(session)
                .environmentObject(session.radio)
        }
        .sheet(isPresented: $showingFilters) {
            LogbookQSOFilterView(initialQuery: query) { updated in
                query = updated
                search = updated.callsign ?? ""
                Task { await session.loadQSOs(query: updated) }
            }
        }
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
            Text(pendingDelete.map { "\($0.callsign) · \($0.submode ?? $0.mode)" } ?? "")
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                logbookMenu
                Spacer()
                if let health = selectedLogbook?.health {
                    Label(
                        health.state,
                        systemImage: health.writable ? "checkmark.shield.fill" : "exclamationmark.triangle.fill"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(health.writable ? RadioPalette.accent : RadioPalette.warning)
                }
            }

            HStack(spacing: 9) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(RadioPalette.muted)
                    TextField("按呼号筛选", text: $search)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { applySearch() }
                    if !search.isEmpty {
                        Button { clearSearch() } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundStyle(RadioPalette.muted)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(RadioPalette.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                Button { showingFilters = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                        if query.activeFilterCount > 0 {
                            Text(String(query.activeFilterCount))
                                .font(.caption2.weight(.bold))
                        }
                    }
                    .frame(minWidth: 26)
                }
                .buttonStyle(.bordered)
                .tint(query.activeFilterCount > 0 ? RadioPalette.accent : RadioPalette.muted)
            }

            if let metadata = session.qsoListMetadata {
                pagination(metadata)
            }
        }
        .padding(14)
    }

    private var logbookMenu: some View {
        Menu {
            ForEach(session.logbooks) { logbook in
                Button {
                    query.offset = 0
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
    }

    private func pagination(_ metadata: QSOListResponse.Metadata) -> some View {
        HStack(spacing: 10) {
            Text(pageDescription(metadata))
                .font(.caption.monospacedDigit())
                .foregroundStyle(RadioPalette.muted)
            Spacer()
            Button { changePage(by: -1) } label: {
                Label("上一页", systemImage: "chevron.left")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .disabled(metadata.offset <= 0)
            Button { changePage(by: 1) } label: {
                Label("下一页", systemImage: "chevron.right")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .disabled(metadata.offset + session.qsos.count >= metadata.total)
        }
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
                query.activeFilterCount > 0 ? "没有匹配的 QSO" : "暂无 QSO",
                systemImage: query.activeFilterCount > 0 ? "line.3.horizontal.decrease.circle" : "text.book.closed",
                description: Text(query.activeFilterCount > 0 ? "调整筛选条件后再试。" : "数字模式自动完成或手动补录后会显示在这里。")
            )
        } else {
            List {
                ForEach(session.qsos) { qso in
                    Button { editingQSO = qso } label: {
                        QSOListRow(qso: qso)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(RadioPalette.panel)
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button { editingQSO = qso } label: {
                            Label("编辑", systemImage: "pencil")
                        }
                        .tint(RadioPalette.cyan)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) { pendingDelete = qso } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable { await session.refreshActiveQSOs() }
        }
    }

    private var selectedLogbook: LogbookInfo? {
        guard let id = session.selectedLogbookId else { return nil }
        return session.logbooks.first { $0.id == id }
    }

    private func applySearch() {
        let normalized = search.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        query.callsign = normalized.isEmpty ? nil : normalized
        query.offset = 0
        Task { await session.loadQSOs(query: query) }
    }

    private func clearSearch() {
        search = ""
        query.callsign = nil
        query.offset = 0
        Task { await session.loadQSOs(query: query) }
    }

    private func changePage(by delta: Int) {
        query.offset = max(0, query.offset + delta * query.limit)
        Task { await session.loadQSOs(query: query) }
    }

    private func pageDescription(_ metadata: QSOListResponse.Metadata) -> String {
        guard metadata.total > 0 else { return "0 / 0" }
        let first = metadata.offset + 1
        let last = metadata.offset + session.qsos.count
        let suffix = metadata.hasFilters ? "（全部 \(metadata.totalRecords)）" : ""
        return "\(first)–\(last) / \(metadata.total) \(suffix)"
    }
}

private struct QSOListRow: View {
    let qso: QSORecord

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(qso.callsign)
                    .font(.headline.monospaced())
                if let grid = qso.grid, !grid.isEmpty {
                    Text(grid)
                        .font(.caption.monospaced())
                        .foregroundStyle(RadioPalette.cyan)
                }
                if qso.dxccNeedsReview == true {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(RadioPalette.warning)
                }
                Spacer()
                Text(qso.submode ?? qso.mode)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(RadioPalette.accent)
            }

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(dateText)
                        .font(.caption)
                        .foregroundStyle(RadioPalette.muted)
                    if let entity = qso.dxccEntity, !entity.isEmpty {
                        Text(dxccText(entity))
                            .font(.caption2)
                            .foregroundStyle(RadioPalette.muted)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(String(format: "%.6f MHz", qso.frequency / 1_000_000))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(RadioPalette.muted)
                    if !confirmationBadges.isEmpty {
                        Text(confirmationBadges.joined(separator: " · "))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(RadioPalette.accent)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var dateText: String {
        let seconds = qso.startTime > 10_000_000_000 ? qso.startTime / 1_000 : qso.startTime
        return Date(timeIntervalSince1970: seconds).formatted(date: .abbreviated, time: .shortened)
    }

    private var confirmationBadges: [String] {
        var badges: [String] = []
        if qso.lotwQslReceived == "Y" || qso.lotwQslReceived == "V" { badges.append("LoTW ✓") }
        if qso.qrzQslReceived == "Y" { badges.append("QRZ ✓") }
        return badges
    }

    private func dxccText(_ entity: String) -> String {
        var parts = [entity]
        if let id = qso.dxccId { parts.append("DXCC \(id)") }
        if qso.dxccStatus == "deleted" { parts.append("已删除实体") }
        return parts.joined(separator: " · ")
    }
}
