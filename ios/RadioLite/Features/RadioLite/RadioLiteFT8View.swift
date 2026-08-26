import SwiftUI

struct RadioLiteFT8View: View {
    @EnvironmentObject private var session: RadioLiteSession
    @State private var decodeFeed = RadioLiteDecodeFeedState()
    @State private var manualCall = ""
    @State private var manualGrid = ""
    @State private var audioFrequency = "1300"
    @State private var parity = "odd"
    @FocusState private var focusedField: Field?

    private enum Field { case call, grid, audio }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                modeAndSlotPanel
                if let qso = session.automaticQSO { qsoPanel(qso) }
                decodePanel
                queuePanel
                manualPanel
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 28)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(RadioPalette.background.ignoresSafeArea())
        .navigationTitle("FT8 / FT4")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { try? await session.refreshDigitalSnapshot() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { focusedField = nil }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let selectedDecode {
                selectedActionBar(selectedDecode)
            }
        }
        .onAppear { decodeFeed.receive(latestBatch) }
        .onChange(of: latestBatch?.id) { _, _ in
            decodeFeed.receive(latestBatch)
        }
    }

    private var modeAndSlotPanel: some View {
        RadioPanel {
            VStack(spacing: 13) {
                Picker("数字模式", selection: modeBinding) {
                    Text("FT8 · 15 秒").tag("FT8")
                    Text("FT4 · 7.5 秒").tag("FT4")
                }
                .pickerStyle(.segmented)
                slotClockPanel
                HStack {
                    Label("整时隙批次", systemImage: "clock.badge.checkmark")
                        .foregroundStyle(RadioPalette.accent)
                    Spacer()
                    if let batch = decodeFeed.displayedBatch {
                        Text(slotDate(batch.slotStartMs), style: .time)
                            .monospacedDigit()
                        Text("· \(batch.decodes.count) 条")
                    } else {
                        Text("等待解码")
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(RadioPalette.muted)
                Text("列表只在一个 UTC 时隙完成后整体更新；选中一条消息时会冻结当前批次，避免跳动。")
                    .font(.caption)
                    .foregroundStyle(RadioPalette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var slotClockPanel: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            if let clock = RadioLiteDigitalSlotClock(mode: decodeFeed.mode) {
                let snapshot = clock.snapshot(at: context.date)
                let state = clock.displayState(
                    at: context.date,
                    rigState: session.rigState,
                    automaticQSO: session.automaticQSO
                )
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Label("UTC 时隙", systemImage: "timer")
                            .foregroundStyle(RadioPalette.accent)
                        Spacer()
                        Text("\(decodeFeed.mode) · \(parityLabel(snapshot.parity))数时隙")
                    }
                    .font(.caption.weight(.semibold))
                    ProgressView(value: snapshot.progress)
                        .tint(displayColor(state))
                    HStack {
                        Text("剩余 \(snapshot.remainingSeconds, specifier: "%.1f") 秒")
                            .monospacedDigit()
                        Spacer()
                        Label(displayLabel(state), systemImage: displaySymbol(state))
                            .foregroundStyle(displayColor(state))
                    }
                    .font(.caption.weight(.semibold))
                }
                .foregroundStyle(RadioPalette.muted)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var decodePanel: some View {
        RadioPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("解码消息", systemImage: "text.line.first.and.arrowtriangle.forward")
                        .font(.headline)
                    Spacer()
                    Toggle("仅 CQ", isOn: cqOnlyBinding)
                        .labelsHidden()
                        .tint(RadioPalette.accent)
                    Text("CQ")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(RadioPalette.muted)
                }
                if filteredDecodes.isEmpty {
                    ContentUnavailableView(
                        decodeFeed.cqOnly ? "本时隙没有 CQ" : "本时隙没有解码",
                        systemImage: "waveform.badge.magnifyingglass"
                    )
                    .frame(minHeight: 130)
                } else {
                    LazyVStack(spacing: 7) {
                        ForEach(filteredDecodes) { decode in
                            Button { decodeFeed.select(decodeId: decode.id) } label: {
                                decodeRow(decode)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func decodeRow(_ decode: RadioLiteDigitalDecode) -> some View {
        let selected = decodeFeed.selectedDecodeId == decode.id
        return HStack(spacing: 10) {
            Text(String(format: "%+.0f", decode.snrDb))
                .font(.caption.monospacedDigit().weight(.bold))
                .foregroundStyle(decode.snrDb >= -10 ? RadioPalette.accent : RadioPalette.muted)
                .frame(width: 34, alignment: .trailing)
            VStack(alignment: .leading, spacing: 4) {
                Text(decode.message)
                    .font(.subheadline.monospaced().weight(isCQ(decode.message) ? .semibold : .regular))
                    .foregroundStyle(isCQ(decode.message) ? Color.white : Color.white.opacity(0.82))
                    .lineLimit(2)
                Text("\(decode.audioFrequencyHz) Hz · Δt \(String(format: "%+.1f", decode.deltaTimeSeconds)) s")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(RadioPalette.muted)
            }
            Spacer(minLength: 4)
            Image(systemName: selected ? "checkmark.circle.fill" : "chevron.right")
                .foregroundStyle(selected ? RadioPalette.accent : RadioPalette.muted)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .background(
            selected ? RadioPalette.accent.opacity(0.13) : RadioPalette.panelRaised.opacity(0.7),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? RadioPalette.accent.opacity(0.5) : Color.white.opacity(0.04))
        }
    }

    private var queuePanel: some View {
        RadioPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("呼叫队列", systemImage: "list.number")
                        .font(.headline)
                    Spacer()
                    Text("\(session.callQueue?.entries.count ?? 0) 个")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(RadioPalette.muted)
                }
                if let status = session.digitalActionStatus {
                    Label(status, systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(RadioPalette.accent)
                        .transition(.opacity)
                }
                if session.callQueue?.entries.isEmpty != false {
                    Text("队列为空。选择一条 CQ 或在下方手动输入呼号。")
                        .font(.subheadline)
                        .foregroundStyle(RadioPalette.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(session.callQueue?.entries ?? []) { entry in
                        HStack(spacing: 10) {
                            Image(systemName: entry.status == "active" ? "antenna.radiowaves.left.and.right" : "clock")
                                .foregroundStyle(entry.status == "active" ? RadioPalette.transmit : RadioPalette.cyan)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.targetCallsign)
                                    .font(.headline.monospaced())
                                Text("\(entry.mode) · \(entry.audioFrequencyHz) Hz · \(entry.txParity == "odd" ? "奇数" : "偶数")时隙")
                                    .font(.caption)
                                    .foregroundStyle(RadioPalette.muted)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                Task { await session.removeQueueEntry(entry.id) }
                            } label: {
                                Image(systemName: "trash")
                                    .frame(width: 36, height: 36)
                                    .background(RadioPalette.transmit.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                            .disabled(entry.status == "active")
                        }
                        .padding(10)
                        .background(RadioPalette.panelRaised.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
                    }
                    HStack {
                        Button("跳过当前") { Task { await session.skipQueue() } }
                            .buttonStyle(RadioActionButtonStyle(tint: RadioPalette.warning))
                        Button("停止自动 QSO") { Task { await session.stopAutomaticQSO(requeue: false) } }
                            .buttonStyle(RadioActionButtonStyle(tint: RadioPalette.transmit))
                    }
                }
            }
        }
    }

    private var manualPanel: some View {
        RadioPanel {
            VStack(alignment: .leading, spacing: 12) {
                Label("手动呼叫", systemImage: "keyboard")
                    .font(.headline)
                HStack(spacing: 9) {
                    TextField("呼号 JA1ABC", text: $manualCall)
                        .focused($focusedField, equals: .call)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .radioLiteInputStyle()
                    TextField("网格 PM95", text: $manualGrid)
                        .focused($focusedField, equals: .grid)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .radioLiteInputStyle()
                }
                HStack(spacing: 9) {
                    TextField("音频 Hz", text: $audioFrequency)
                        .focused($focusedField, equals: .audio)
                        .keyboardType(.numberPad)
                        .radioLiteInputStyle()
                    Picker("发射时隙", selection: $parity) {
                        Text("偶数").tag("even")
                        Text("奇数").tag("odd")
                    }
                    .pickerStyle(.segmented)
                }
                Button("加入 \(decodeFeed.mode) 呼叫队列") {
                    focusedField = nil
                    guard let frequency = Int(audioFrequency) else { return }
                    Task {
                        await session.addManualCall(
                            callsign: manualCall,
                            grid: manualGrid.isEmpty ? nil : manualGrid,
                            mode: decodeFeed.mode,
                            audioFrequencyHz: frequency,
                            parity: parity
                        )
                        manualCall = ""
                        manualGrid = ""
                    }
                }
                .buttonStyle(RadioActionButtonStyle(tint: RadioPalette.accent, prominent: true))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .disabled(!session.hasControl || manualCall.trimmingCharacters(in: .whitespaces).isEmpty || !(200...5_000).contains(Int(audioFrequency) ?? 0))
            }
        }
    }

    private func qsoPanel(_ qso: RadioLiteAutoQSO) -> some View {
        RadioPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("自动 QSO", systemImage: "bolt.horizontal.circle.fill")
                        .font(.headline)
                        .foregroundStyle(qso.phase == "failed" ? RadioPalette.transmit : RadioPalette.accent)
                    Spacer()
                    Text(qso.phase.replacingOccurrences(of: "_", with: " ").uppercased())
                        .font(.caption.monospaced().weight(.bold))
                        .foregroundStyle(RadioPalette.warning)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(qso.targetCallsign)
                        .font(.title2.monospaced().bold())
                    if let grid = qso.targetGrid { Text(grid).foregroundStyle(RadioPalette.cyan) }
                    Spacer()
                    Text(qso.mode).font(.headline).foregroundStyle(RadioPalette.accent)
                }
                if let outbound = qso.outboundMessage {
                    LabeledContent("下一条", value: outbound)
                        .font(.subheadline.monospaced())
                }
                if let inbound = qso.lastInboundMessage {
                    LabeledContent("收到", value: inbound)
                        .font(.subheadline.monospaced())
                }
                if let failure = qso.failureReason {
                    Text(failure).font(.caption).foregroundStyle(RadioPalette.transmit)
                }
                HStack {
                    Button("暂停并重排") { Task { await session.stopAutomaticQSO(requeue: true) } }
                        .buttonStyle(RadioActionButtonStyle(tint: RadioPalette.warning))
                    Button("停止") { Task { await session.stopAutomaticQSO(requeue: false) } }
                        .buttonStyle(RadioActionButtonStyle(tint: RadioPalette.transmit))
                }
            }
        }
    }

    private func selectedActionBar(_ decode: RadioLiteDigitalDecode) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(decode.message)
                    .font(.caption.monospaced().weight(.semibold))
                    .lineLimit(1)
                Text("已冻结当前时隙")
                    .font(.caption2)
                    .foregroundStyle(RadioPalette.muted)
            }
            Spacer()
            Button("取消") {
                decodeFeed.resume()
            }
            .buttonStyle(RadioActionButtonStyle(tint: RadioPalette.muted))
            Button("加入队列") {
                Task {
                    await session.addDecodeToQueue(decode.id)
                    decodeFeed.resume()
                }
            }
            .buttonStyle(RadioActionButtonStyle(tint: RadioPalette.accent, prominent: true))
            .disabled(!session.hasControl)
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider().opacity(0.25) }
    }

    private var latestBatch: RadioLiteDigitalDecodeBatch? {
        latestBatch(for: decodeFeed.mode)
    }

    private var filteredDecodes: [RadioLiteDigitalDecode] {
        decodeFeed.filteredDecodes
    }

    private var selectedDecode: RadioLiteDigitalDecode? {
        decodeFeed.selectedDecode
    }

    private var modeBinding: Binding<String> {
        Binding(
            get: { decodeFeed.mode },
            set: { value in
                decodeFeed.changeMode(to: value, latestBatch: latestBatch(for: value))
            }
        )
    }

    private var cqOnlyBinding: Binding<Bool> {
        Binding(
            get: { decodeFeed.cqOnly },
            set: { decodeFeed.setCQOnly($0) }
        )
    }

    private func latestBatch(for mode: String) -> RadioLiteDigitalDecodeBatch? {
        session.decodeBatches.first { $0.mode == mode }
    }

    private func isCQ(_ message: String) -> Bool {
        let normalized = message.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized == "CQ" || normalized.hasPrefix("CQ ")
    }

    private func slotDate(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }

    private func parityLabel(_ parity: RadioLiteDigitalSlotClock.Parity) -> String {
        parity == .even ? "偶" : "奇"
    }

    private func displayLabel(_ state: RadioLiteDigitalSlotClock.DisplayState) -> String {
        switch state {
        case .receiving: "RX 接收"
        case .waitingToTransmit: "等待 TX"
        case .transmitting: "TX 发射"
        }
    }

    private func displaySymbol(_ state: RadioLiteDigitalSlotClock.DisplayState) -> String {
        switch state {
        case .receiving: "arrow.down.circle.fill"
        case .waitingToTransmit: "clock.fill"
        case .transmitting: "antenna.radiowaves.left.and.right"
        }
    }

    private func displayColor(_ state: RadioLiteDigitalSlotClock.DisplayState) -> Color {
        switch state {
        case .receiving: RadioPalette.cyan
        case .waitingToTransmit: RadioPalette.warning
        case .transmitting: RadioPalette.transmit
        }
    }
}
