import SwiftUI

struct RadioLiteFT8View: View {
    @EnvironmentObject private var session: RadioLiteSession
    @EnvironmentObject private var media: RadioLiteMediaClient
    @State private var decodeFeed = RadioLiteDecodeFeedState()
    @State private var manualCall = ""
    @State private var manualGrid = ""
    @State private var audioFrequency = "1300"
    @State private var parity = "odd"
    @FocusState private var focusedField: Field?

    private enum Field { case call, grid, audio }
    private enum DecodeHistoryAnchor: Hashable { case latest }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                modeAndSlotPanel
                if let qso = session.automaticQSO { qsoPanel(qso) }
                decodePanel
                RadioLiteSpectrumView(
                    spectrum: media.spectrum,
                    capability: media.spectrumCapability,
                    history: media.spectrumHistory,
                    policy: media.policy,
                    compact: true,
                    selectedAudioFrequencyHz: selectedDecode?.audioFrequencyHz
                )
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
        .onAppear { decodeFeed.receive(session.decodeBatches) }
        .onChange(of: session.decodeBatches) { _, batches in
            decodeFeed.receive(batches)
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
                    Label("UTC 解码历史", systemImage: "clock.badge.checkmark")
                        .foregroundStyle(RadioPalette.accent)
                    Spacer()
                    if decodeFeed.displayedBatches.isEmpty {
                        Text("等待解码")
                    } else {
                        Text("\(decodeFeed.displayedBatches.count) 个时隙")
                            .monospacedDigit()
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(RadioPalette.muted)
                Text("保留当前模式最近的完整时隙；选中消息或浏览旧时隙时，新批次不会推动当前内容。")
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
                    Label("解码历史", systemImage: "text.line.first.and.arrowtriangle.forward")
                        .font(.headline)
                    Spacer()
                    if !decodeFeed.isFollowingLatest {
                        Button("回到最新") { decodeFeed.resume() }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(RadioPalette.accent)
                            .buttonStyle(.plain)
                    }
                }
                HStack(spacing: 8) {
                    Text(decodeFeed.cqOnly ? "仅显示 CQ" : "显示全部消息")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(RadioPalette.muted)
                    Spacer()
                    Toggle("仅 CQ", isOn: cqOnlyBinding)
                        .labelsHidden()
                        .tint(RadioPalette.accent)
                }
                if decodeFeed.displayedBatches.isEmpty {
                    ContentUnavailableView(
                        "暂无 \(decodeFeed.mode) 解码",
                        systemImage: "waveform.badge.magnifyingglass"
                    )
                    .frame(minHeight: 130)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            VStack(spacing: 0) {
                                Color.clear
                                    .frame(height: 1)
                                    .id(DecodeHistoryAnchor.latest)
                                LazyVStack(spacing: 12) {
                                    ForEach(decodeFeed.displayedBatches) { batch in
                                        decodeBatchSection(batch)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                        .frame(minHeight: 280, maxHeight: 480)
                        .scrollIndicators(.visible)
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 4).onChanged { _ in
                                decodeFeed.pauseFollowingLatest()
                            }
                        )
                        .onChange(of: decodeFeed.latestScrollRequestRevision) { _, _ in
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(DecodeHistoryAnchor.latest, anchor: .top)
                            }
                        }
                    }
                }
            }
        }
    }

    private func decodeBatchSection(_ batch: RadioLiteDigitalDecodeBatch) -> some View {
        let decodes = decodeFeed.filteredDecodes(in: batch)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(Self.utcSlotFormatter.string(from: slotDate(batch.slotStartMs)))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.66))
                Text("UTC")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(RadioPalette.muted)
                Rectangle()
                    .fill(Color.white.opacity(0.09))
                    .frame(height: 1)
                Text("\(decodes.count)/\(batch.decodes.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(RadioPalette.muted)
            }
            if decodes.isEmpty {
                Text("此时隙没有符合筛选条件的消息")
                    .font(.caption)
                    .foregroundStyle(RadioPalette.muted.opacity(0.72))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            } else {
                ForEach(decodes) { decode in
                    Button { decodeFeed.select(decodeId: decode.id) } label: {
                        decodeRow(decode)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .background(
            RadioPalette.panelRaised.opacity(0.38),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.white.opacity(0.045))
        }
    }

    private func decodeRow(_ decode: RadioLiteDigitalDecode) -> some View {
        let selected = decodeFeed.selectedDecodeId == decode.id
        let message = RadioLiteFTMessage.parse(decode.message)
        let emphasis = message.emphasis(myCallsign: stationCallsign)
        let tint = decodeTint(emphasis)
        let country = message.sender.map {
            RadioLiteCallsignCountryResolver.offline.countryLabel(for: $0)
        }
        let distance = RadioLiteMaidenheadDistance.kilometers(
            from: stationGrid,
            to: message.grid
        )
        let metadata: [String] = [
            message.sender,
            country,
            message.grid,
            distance.map { "\($0) km 大圆" },
        ].compactMap { $0 }
        return HStack(alignment: .top, spacing: 10) {
            Text(String(format: "%+.0f", decode.snrDb))
                .font(.caption.monospacedDigit().weight(.bold))
                .foregroundStyle(tint.opacity(decode.snrDb >= -10 ? 1 : 0.7))
                .frame(width: 34, alignment: .trailing)
            VStack(alignment: .leading, spacing: 4) {
                Text(decode.message)
                    .font(.subheadline.monospaced().weight(emphasis == .normal ? .regular : .semibold))
                    .foregroundStyle(emphasis == .normal ? Color.white.opacity(0.82) : Color.white)
                    .lineLimit(2)
                if !metadata.isEmpty {
                    Text(metadata.joined(separator: " · "))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(tint.opacity(emphasis == .normal ? 0.68 : 0.9))
                        .lineLimit(2)
                }
                Text("\(decode.audioFrequencyHz) Hz · Δt \(String(format: "%+.1f", decode.deltaTimeSeconds)) s")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(RadioPalette.muted.opacity(0.78))
            }
            Spacer(minLength: 4)
            Image(systemName: selected ? "checkmark.circle.fill" : "chevron.right")
                .foregroundStyle(selected ? tint : RadioPalette.muted)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .background(
            decodeBackground(emphasis, selected: selected),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? tint.opacity(0.58) : tint.opacity(emphasis == .normal ? 0.04 : 0.22))
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
                    Text("队列为空。选择一条解码消息或在下方手动输入呼号。")
                        .font(.subheadline)
                        .foregroundStyle(RadioPalette.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(session.callQueue?.entries ?? []) { entry in
                        HStack(spacing: 10) {
                            Image(systemName: entry.status == "active" ? "antenna.radiowaves.left.and.right" : "clock")
                                .foregroundStyle(entry.status == "active" ? RadioPalette.transmit : RadioPalette.accent)
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
                    if let grid = qso.targetGrid { Text(grid).foregroundStyle(RadioPalette.muted) }
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
                Text("已锁定解码历史")
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

    private var selectedDecode: RadioLiteDigitalDecode? {
        decodeFeed.selectedDecode
    }

    private var stationCallsign: String? {
        session.selectedRadio?.station.callsign
    }

    private var stationGrid: String? {
        session.selectedRadio?.station.grid
    }

    private var modeBinding: Binding<String> {
        Binding(
            get: { decodeFeed.mode },
            set: { value in
                decodeFeed.changeMode(to: value, batches: session.decodeBatches)
            }
        )
    }

    private var cqOnlyBinding: Binding<Bool> {
        Binding(
            get: { decodeFeed.cqOnly },
            set: { decodeFeed.setCQOnly($0) }
        )
    }

    private func slotDate(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }

    private func decodeTint(_ emphasis: RadioLiteFTMessageEmphasis) -> Color {
        switch emphasis {
        case .normal: RadioPalette.muted
        case .cq: RadioPalette.accent
        case .addressedToMe: RadioPalette.transmit
        }
    }

    private func decodeBackground(
        _ emphasis: RadioLiteFTMessageEmphasis,
        selected: Bool
    ) -> Color {
        switch emphasis {
        case .normal:
            selected ? Color.white.opacity(0.09) : RadioPalette.panelRaised.opacity(0.5)
        case .cq:
            RadioPalette.accent.opacity(selected ? 0.18 : 0.09)
        case .addressedToMe:
            RadioPalette.transmit.opacity(selected ? 0.22 : 0.13)
        }
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
        case .receiving: RadioPalette.accent
        case .waitingToTransmit: RadioPalette.warning
        case .transmitting: RadioPalette.transmit
        }
    }

    private static let utcSlotFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
