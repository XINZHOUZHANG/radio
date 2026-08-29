import SwiftUI
import UIKit

struct FT8DecodedFeedState: Equatable {
    private(set) var frozenFrames: [FrameMessage]?

    var isFrozen: Bool { frozenFrames != nil }

    func displayedFrames(live: [FrameMessage]) -> [FrameMessage] {
        frozenFrames ?? live
    }

    mutating func freeze(live: [FrameMessage]) {
        frozenFrames = live
    }

    mutating func resume() {
        frozenFrames = nil
    }

    mutating func clear() {
        if isFrozen { frozenFrames = [] }
    }
}

private enum FT8FocusedField: Hashable {
    case callsign
    case filter
    case contextCallsign
    case contextGrid
    case reportSent
    case reportReceived
    case audioFrequency
    case slot(String)
}

struct FT8View: View {
    @EnvironmentObject private var session: TX5DRSession
    @EnvironmentObject private var radio: RadioWebSocket
    @State private var callsign = ""
    @State private var filter = ""
    @State private var runtimeExpanded = false
    @State private var slotDrafts: [String: String] = [:]
    @State private var contextDraft = FT8OperatorContextDraft()
    @State private var contextDirty = false
    @State private var decodedFeed = FT8DecodedFeedState()
    @FocusState private var focusedField: FT8FocusedField?

    var body: some View {
        VStack(spacing: 0) {
            controlHeader
            Divider().opacity(0.25)
            runtimeControls
            Divider().opacity(0.25)
            decodedList
        }
        .background(RadioPalette.background.ignoresSafeArea())
        .navigationTitle("FT8 / FT4")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    radio.clearDecodedFrames()
                    decodedFeed.clear()
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(displayedFrames.isEmpty)
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { focusedField = nil }
            }
        }
        .onAppear { syncContextDraft(force: true) }
        .onChange(of: session.selectedOperatorId) { _, _ in
            focusedField = nil
            slotDrafts = [:]
            contextDirty = false
            decodedFeed.resume()
            syncContextDraft(force: true)
        }
        .onChange(of: selectedStatus) { _, _ in
            syncContextDraft(force: false)
        }
    }

    private var controlHeader: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.selectedOperator?.myCallsign ?? "未选择操作员")
                        .font(.headline)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(operatorActive ? RadioPalette.accent : RadioPalette.muted)
                            .frame(width: 7, height: 7)
                        Text(operatorActive ? "操作员运行中" : "操作员已停止")
                            .font(.caption)
                            .foregroundStyle(RadioPalette.muted)
                    }
                }
                Spacer()
                Button(operatorActive ? "停止" : "启动") {
                    session.setOperatorRunning(!operatorActive)
                }
                .buttonStyle(RadioActionButtonStyle(tint: operatorActive ? RadioPalette.warning : RadioPalette.accent))
                .disabled(!controlsReady)
            }

            HStack(spacing: 8) {
                TextField("目标呼号", text: $callsign)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .callsign)
                    .submitLabel(.done)
                    .onSubmit { focusedField = nil }
                    .padding(12)
                    .background(RadioPalette.panelRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Button("呼叫") {
                    callTarget(callsign)
                }
                .buttonStyle(RadioActionButtonStyle(tint: RadioPalette.accent, prominent: true))
                .disabled(callsign.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !controlsReady)
                if targetQueueSupported {
                    Menu {
                        Button("加入队列并在空闲时启动") { enqueue(startIfIdle: true) }
                        Button("仅加入等待队列") { enqueue(startIfIdle: false) }
                    } label: {
                        Image(systemName: "text.badge.plus")
                            .frame(width: 42, height: 42)
                            .background(RadioPalette.panelRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .disabled(callsign.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !controlsReady)
                }
            }

            HStack {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(RadioPalette.muted)
                TextField("筛选解码消息", text: $filter)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .filter)
                    .submitLabel(.done)
                    .onSubmit { focusedField = nil }
                    .font(.subheadline)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RadioPalette.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(14)
    }

    private var runtimeControls: some View {
        DisclosureGroup(isExpanded: $runtimeExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                contextEditor

                HStack {
                    Text("发射周期")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(RadioPalette.muted)
                    Spacer()
                    cycleButton("偶数", cycle: 0)
                    cycleButton("奇数", cycle: 1)
                }

                Picker("当前槽位", selection: Binding(
                    get: { runtime?["currentState"]?.stringValue ?? "TX1" },
                    set: { value in
                        guard let id = session.selectedOperatorId else { return }
                        radio.setOperatorRuntimeState(value, operatorId: id)
                    }
                )) {
                    ForEach(runtimeSlots, id: \.self) { Text($0).tag($0) }
                }

                ForEach(runtimeSlots, id: \.self) { slot in
                    HStack {
                        Text(slot)
                            .font(.caption.monospaced().weight(.bold))
                            .frame(width: 34, alignment: .leading)
                        TextField("消息内容", text: Binding(
                            get: { slotDrafts[slot] ?? runtime?["slots"]?[slot]?.stringValue ?? "" },
                            set: { slotDrafts[slot] = $0 }
                        ))
                        .font(.caption.monospaced())
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .slot(slot))
                        .submitLabel(.done)
                        .onSubmit {
                            saveSlot(slot)
                            focusedField = nil
                        }
                        Button { saveSlot(slot) } label: { Image(systemName: "checkmark.circle") }
                            .buttonStyle(.plain)
                    }
                }

                queueView
            }
            .padding(.top, 12)
        } label: {
            HStack {
                Label("自动应答、时隙与队列", systemImage: "list.bullet.rectangle")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if targetQueueSupported, let queue {
                    Text("\(queue.rows.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(RadioPalette.muted)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RadioPalette.panel)
    }

    private var contextEditor: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("通联上下文")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(RadioPalette.muted)
                Spacer()
                if contextDirty {
                    Text("未应用")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(RadioPalette.warning)
                }
            }

            HStack(spacing: 8) {
                TextField("目标呼号", text: contextBinding(\.targetCallsign))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .contextCallsign)
                    .textFieldStyle(.roundedBorder)
                TextField("目标网格", text: contextBinding(\.targetGrid))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .contextGrid)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 8) {
                TextField("TX 报告", text: contextBinding(\.reportSent))
                    .keyboardType(.numbersAndPunctuation)
                    .focused($focusedField, equals: .reportSent)
                    .textFieldStyle(.roundedBorder)
                TextField("RX 报告", text: contextBinding(\.reportReceived))
                    .keyboardType(.numbersAndPunctuation)
                    .focused($focusedField, equals: .reportReceived)
                    .textFieldStyle(.roundedBorder)
                TextField("音频 Hz", text: contextBinding(\.audioFrequencyHz))
                    .keyboardType(.numberPad)
                    .focused($focusedField, equals: .audioFrequency)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 8) {
                Button {
                    applyContext()
                } label: {
                    Label("应用上下文", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(RadioActionButtonStyle(tint: RadioPalette.accent))
                .disabled(!contextDirty || contextDraft.validationMessage != nil || !controlsReady)

                Button {
                    resetToCQ()
                } label: {
                    Label("回 CQ", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(RadioActionButtonStyle(tint: RadioPalette.warning))
                .disabled(!controlsReady)
            }

            if let validation = contextDraft.validationMessage {
                Label(validation, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(RadioPalette.warning)
            }
        }
        .padding(10)
        .background(RadioPalette.panelRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var queueView: some View {
        if !targetQueueSupported {
            Text("当前自动化策略不支持呼叫队列，请使用“呼叫”。")
                .font(.caption)
                .foregroundStyle(RadioPalette.muted)
        } else if let queue {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("自动呼叫队列")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(RadioPalette.muted)
                    Spacer()
                    Button("清空", role: .destructive) {
                        guard let id = session.selectedOperatorId else { return }
                        radio.clearOperatorQueue(operatorId: id, version: queue.version)
                    }
                    .font(.caption)
                    .disabled(queue.rows.isEmpty)
                }
                if queue.rows.isEmpty {
                    Text("队列为空；输入目标呼号后可选择加入队列。")
                        .font(.caption)
                        .foregroundStyle(RadioPalette.muted)
                } else {
                    ForEach(queue.rows) { row in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(row.entryId == queue.activeEntryId ? RadioPalette.accent : RadioPalette.muted)
                                .frame(width: 7, height: 7)
                            Text(row.callsign)
                                .font(.caption.monospaced().weight(.semibold))
                            Text(row.displayState)
                                .font(.caption2.monospaced())
                                .foregroundStyle(RadioPalette.muted)
                            Spacer()
                            if row.displayState == "no-response" {
                                Button { retry(row, queue: queue) } label: { Image(systemName: "arrow.clockwise") }
                                    .buttonStyle(.plain)
                            }
                            Button(role: .destructive) { remove(row, queue: queue) } label: { Image(systemName: "trash") }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(10)
            .background(RadioPalette.panelRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            Text("当前策略未提供辅助呼叫队列。")
                .font(.caption)
                .foregroundStyle(RadioPalette.muted)
        }
    }

    private var decodedList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label(
                    decodedFeed.isFrozen ? "已暂停更新" : "实时更新",
                    systemImage: decodedFeed.isFrozen ? "pause.circle.fill" : "dot.radiowaves.left.and.right"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(decodedFeed.isFrozen ? RadioPalette.warning : RadioPalette.accent)

                Text("\(filteredFrames.count) 条")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(RadioPalette.muted)

                Spacer()

                Button(decodedFeed.isFrozen ? "继续实时" : "暂停更新") {
                    if decodedFeed.isFrozen {
                        decodedFeed.resume()
                    } else {
                        decodedFeed.freeze(live: radio.decodedFrames)
                    }
                }
                .buttonStyle(RadioActionButtonStyle(tint: decodedFeed.isFrozen ? RadioPalette.accent : RadioPalette.warning))
                .disabled(displayedFrames.isEmpty && !decodedFeed.isFrozen)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(RadioPalette.panel)

            Group {
                if filteredFrames.isEmpty {
                    ContentUnavailableView(
                        decodedFeed.isFrozen ? "已暂停，当前快照为空" : "等待数字模式解码",
                        systemImage: decodedFeed.isFrozen ? "pause.circle" : "waveform.path.ecg",
                        description: Text(decodedFeed.isFrozen ? "点“继续实时”恢复接收最新解码。" : "启动操作员后，TX-5DR 的时隙解码会实时显示在这里。")
                    )
                } else {
                    List(filteredFrames) { frame in
                        Button {
                            if !decodedFeed.isFrozen {
                                decodedFeed.freeze(live: radio.decodedFrames)
                            }
                            selectDecodedFrame(frame)
                        } label: {
                            HStack(spacing: 12) {
                                Text(String(format: "%+.0f", frame.snr))
                                    .font(.system(.subheadline, design: .monospaced).weight(.bold))
                                    .foregroundStyle(frame.snr >= 0 ? RadioPalette.accent : RadioPalette.cyan)
                                    .frame(width: 38, alignment: .trailing)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(frame.message)
                                        .font(.system(.body, design: .monospaced).weight(.medium))
                                        .foregroundStyle(Color.white)
                                    HStack(spacing: 12) {
                                        Text(String(format: "DT %+.1f", frame.dt))
                                        Text(String(format: "%.0f Hz", frame.freq))
                                        if let operatorId = frame.operatorId {
                                            Text(operatorId)
                                        }
                                    }
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(RadioPalette.muted)
                                }
                                Spacer()
                                Image(systemName: "scope")
                                    .foregroundStyle(RadioPalette.muted)
                            }
                            .padding(.vertical, 3)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(RadioPalette.panel)
                        .contextMenu {
                            if let candidate = candidateCallsign(in: frame.message) {
                                Button("呼叫 \(candidate)") { callTarget(candidate, frequency: frame.freq) }
                            }
                            Button("复制消息") { UIPasteboard.general.string = frame.message }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .scrollDismissesKeyboard(.interactively)
                }
            }
        }
    }

    private var selectedStatus: JSONValue? {
        guard let id = session.selectedOperatorId else { return nil }
        return radio.operatorStatuses[id]
    }

    private var operatorActive: Bool { selectedStatus?["isActive"]?.boolValue ?? false }

    private var controlsReady: Bool {
        session.selectedOperatorId != nil && radio.state == .ready
    }

    private var selectedStrategyName: String? {
        if let name = selectedStatus?["strategy"]?["name"]?.stringValue { return name }
        if let name = selectedStatus?["strategyName"]?.stringValue { return name }
        guard let id = session.selectedOperatorId else { return nil }
        return session.pluginOperatorStates[id]?.currentStrategy
    }

    private var targetQueueSupported: Bool {
        let plugins = (radio.pluginSnapshot ?? session.pluginSnapshot)?.plugins ?? []
        return FT8QueueCapability.supports(strategyName: selectedStrategyName, plugins: plugins)
    }

    private var runtime: JSONValue? { selectedStatus?["runtime"] }

    private var queue: AssistedQueueSnapshot? {
        runtime?["queue"]?.decoded()
    }

    private var runtimeSlots: [String] { ["TX1", "TX2", "TX3", "TX4", "TX5", "TX6"] }

    private var transmitCycles: [Double] {
        if let values = selectedStatus?["transmitCycles"]?.arrayValue {
            return values.compactMap(\.doubleValue)
        }
        return session.selectedOperator?.transmitCycles ?? [0]
    }

    private func cycleButton(_ title: String, cycle: Double) -> some View {
        let selected = transmitCycles.contains(cycle)
        return Button(title) {
            guard let id = session.selectedOperatorId else { return }
            var cycles = transmitCycles
            if selected { cycles.removeAll { $0 == cycle } }
            else { cycles.append(cycle) }
            if cycles.isEmpty { cycles = [cycle] }
            radio.setOperatorTransmitCycles(cycles.sorted(), operatorId: id)
        }
        .buttonStyle(RadioActionButtonStyle(tint: selected ? RadioPalette.accent : RadioPalette.muted))
    }

    private func saveSlot(_ slot: String) {
        focusedField = nil
        guard let id = session.selectedOperatorId else { return }
        let content = slotDrafts[slot] ?? runtime?["slots"]?[slot]?.stringValue ?? ""
        radio.setOperatorRuntimeSlotContent(content, slot: slot, operatorId: id)
    }

    private func contextBinding(_ keyPath: WritableKeyPath<FT8OperatorContextDraft, String>) -> Binding<String> {
        Binding(
            get: { contextDraft[keyPath: keyPath] },
            set: { value in
                contextDraft[keyPath: keyPath] = value
                contextDirty = true
            }
        )
    }

    private func syncContextDraft(force: Bool) {
        guard force || !contextDirty else { return }
        contextDraft = FT8OperatorContextDraft(status: selectedStatus)
        contextDirty = false
    }

    private func applyContext() {
        focusedField = nil
        _ = sendContext(contextDraft, notice: "FT8 通联上下文已应用")
    }

    private func resetToCQ() {
        focusedField = nil
        guard let id = session.selectedOperatorId else { return }
        var draft = contextDraft
        draft.targetCallsign = ""
        draft.targetGrid = ""
        draft.reportSent = "0"
        draft.reportReceived = "0"
        guard sendContext(draft, notice: "已重置为 CQ") else { return }
        contextDraft = draft
        callsign = ""
        radio.setOperatorRuntimeState("TX6", operatorId: id)
    }

    private func selectDecodedFrame(_ frame: FrameMessage) {
        focusedField = nil
        guard let candidate = candidateCallsign(in: frame.message) else { return }
        callsign = candidate
        contextDraft.targetCallsign = candidate
        contextDraft.audioFrequencyHz = String(max(1, min(3_000, Int(frame.freq.rounded()))))
        contextDirty = true
    }

    private func callTarget(_ rawTarget: String, frequency: Double? = nil) {
        focusedField = nil
        let target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !target.isEmpty else { return }

        var draft = contextDraft
        draft.targetCallsign = target
        if let frequency {
            draft.audioFrequencyHz = String(max(1, min(3_000, Int(frequency.rounded()))))
        }
        guard sendContext(draft, notice: nil) else { return }
        contextDraft = draft
        session.requestFT8Call(target)
        callsign = ""
    }

    @discardableResult
    private func sendContext(_ draft: FT8OperatorContextDraft, notice: String?) -> Bool {
        guard let id = session.selectedOperatorId else {
            session.errorMessage = "请先选择操作员"
            return false
        }
        do {
            radio.setOperatorContext(try draft.commandContext(), operatorId: id)
            contextDirty = false
            if let notice { session.noticeMessage = notice }
            return true
        } catch {
            session.errorMessage = error.localizedDescription
            return false
        }
    }

    private func enqueue(startIfIdle: Bool) {
        focusedField = nil
        guard targetQueueSupported else {
            session.noticeMessage = RadioServerNotice.localized("strategy_not_queue_capable")
            return
        }
        guard let id = session.selectedOperatorId else { return }
        let target = callsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !target.isEmpty else { return }
        radio.enqueueOperatorTarget(target, operatorId: id, startIfIdle: startIfIdle)
        callsign = ""
    }

    private func retry(_ row: AssistedQueueRow, queue: AssistedQueueSnapshot) {
        guard let id = session.selectedOperatorId else { return }
        radio.retryOperatorTarget(operatorId: id, entryId: row.entryId, version: queue.version)
    }

    private func remove(_ row: AssistedQueueRow, queue: AssistedQueueSnapshot) {
        guard let id = session.selectedOperatorId else { return }
        radio.removeOperatorTarget(operatorId: id, entryId: row.entryId, version: queue.version)
    }

    private var filteredFrames: [FrameMessage] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !query.isEmpty else { return displayedFrames }
        return displayedFrames.filter { $0.message.uppercased().contains(query) }
    }

    private var displayedFrames: [FrameMessage] {
        decodedFeed.displayedFrames(live: radio.decodedFrames)
    }

    private func candidateCallsign(in message: String) -> String? {
        message
            .uppercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .first { token in
                (3...10).contains(token.count)
                    && token.contains(where: \.isNumber)
                    && token.allSatisfy { $0.isLetter || $0.isNumber || $0 == "/" }
            }
    }
}
