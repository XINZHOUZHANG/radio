import SwiftUI
import UIKit

struct FT8View: View {
    @EnvironmentObject private var session: TX5DRSession
    @EnvironmentObject private var radio: RadioWebSocket
    @State private var callsign = ""
    @State private var filter = ""
    @State private var runtimeExpanded = false
    @State private var slotDrafts: [String: String] = [:]

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
                Button { radio.clearDecodedFrames() } label: {
                    Image(systemName: "trash")
                }
                .disabled(radio.decodedFrames.isEmpty)
            }
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
            }

            HStack(spacing: 8) {
                TextField("目标呼号", text: $callsign)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(RadioPalette.panelRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Button("呼叫") {
                    session.requestFT8Call(callsign)
                    callsign = ""
                }
                .buttonStyle(RadioActionButtonStyle(tint: RadioPalette.accent, prominent: true))
                Menu {
                    Button("加入队列并在空闲时启动") { enqueue(startIfIdle: true) }
                    Button("仅加入等待队列") { enqueue(startIfIdle: false) }
                } label: {
                    Image(systemName: "text.badge.plus")
                        .frame(width: 42, height: 42)
                        .background(RadioPalette.panelRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(callsign.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            HStack {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(RadioPalette.muted)
                TextField("筛选解码消息", text: $filter)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
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
                        .onSubmit { saveSlot(slot) }
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
                if let queue {
                    Text("\(queue.rows.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(RadioPalette.muted)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RadioPalette.panel)
        .onChange(of: session.selectedOperatorId) { _, _ in slotDrafts = [:] }
    }

    @ViewBuilder
    private var queueView: some View {
        if let queue {
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
        Group {
            if filteredFrames.isEmpty {
                ContentUnavailableView(
                    "等待数字模式解码",
                    systemImage: "waveform.path.ecg",
                    description: Text("启动操作员后，TX-5DR 的时隙解码会实时显示在这里。")
                )
            } else {
                List(filteredFrames) { frame in
                    Button {
                        if let candidate = candidateCallsign(in: frame.message) {
                            callsign = candidate
                        }
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
                            Button("呼叫 \(candidate)") { session.requestFT8Call(candidate) }
                        }
                        Button("复制消息") { UIPasteboard.general.string = frame.message }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var selectedStatus: JSONValue? {
        guard let id = session.selectedOperatorId else { return nil }
        return radio.operatorStatuses[id]
    }

    private var operatorActive: Bool { selectedStatus?["isActive"]?.boolValue ?? false }

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
        guard let id = session.selectedOperatorId else { return }
        let content = slotDrafts[slot] ?? runtime?["slots"]?[slot]?.stringValue ?? ""
        radio.setOperatorRuntimeSlotContent(content, slot: slot, operatorId: id)
    }

    private func enqueue(startIfIdle: Bool) {
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
        guard !query.isEmpty else { return radio.decodedFrames }
        return radio.decodedFrames.filter { $0.message.uppercased().contains(query) }
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
