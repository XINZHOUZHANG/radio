import SwiftUI

struct RadioLiteFT8View: View {
    let onShowRadio: () -> Void
    @EnvironmentObject private var session: RadioLiteSession
    @EnvironmentObject private var media: RadioLiteMediaClient
    @State private var decodeFeed = RadioLiteDecodeFeedState()
    @State private var filter = DecodeFilter.all
    @State private var cachedWorkedCallsigns: Set<String> = []
    @State private var showInfo = false
    @State private var showOperations = false
    @State private var manualCall = ""
    @State private var manualGrid = ""
    @State private var audioFrequency = "1300"
    @State private var parity = "odd"
    @FocusState private var focusedField: Field?

    private enum Field { case call, grid, audio }
    private enum DecodeHistoryAnchor: Hashable { case latest }
    private enum DecodeFilter: String, CaseIterable, Identifiable {
        case all = "全部", toMe = "叫我", cq = "CQ", newDX = "新 DX"
        var id: Self { self }
    }
    private struct DecodeSection: Identifiable {
        let batch: RadioLiteDigitalDecodeBatch
        let decodes: [RadioLiteDigitalDecode]
        var id: String { batch.id }
    }

    init(onShowRadio: @escaping () -> Void = {}) {
        self.onShowRadio = onShowRadio
    }

    var body: some View {
        GeometryReader { geometry in
            let worked = workedCallsigns
            let sections = visibleSections(worked: worked)
            let caller = latestCaller
            let rowHeight = geometry.size.width < 375 ? TX.rowHCompact : TX.rowH
            VStack(spacing: 0) {
                slotProgress
                navigationRow
                slotStatus
                filterRow
                if let caller { callerCard(caller) }
                decodeList(sections, worked: worked, rowHeight: rowHeight, omitFirstHeader: caller != nil)
                operationBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(TX.bg.ignoresSafeArea())
        .foregroundStyle(TX.text1)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showOperations) { operationsSheet }
        .sheet(isPresented: $showInfo) { informationSheet }
        .onAppear {
            decodeFeed.receive(session.decodeBatches)
            cacheWorkedCallsigns()
        }
        .onChange(of: session.decodeBatches) { _, batches in decodeFeed.receive(batches) }
        .onChange(of: session.qsos) { _, _ in cacheWorkedCallsigns() }
        .onChange(of: session.selectedRadioId) { _, _ in
            decodeFeed = RadioLiteDecodeFeedState(mode: decodeFeed.mode)
            decodeFeed.receive(session.decodeBatches)
            cacheWorkedCallsigns()
        }
    }

    private var slotProgress: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            GeometryReader { geometry in
                if let clock = RadioLiteDigitalSlotClock(mode: decodeFeed.mode) {
                    let snapshot = clock.snapshot(at: context.date)
                    let state = clock.displayState(
                        at: context.date, rigState: session.rigState, automaticQSO: session.automaticQSO
                    )
                    Rectangle().fill(displayColor(state))
                        .frame(width: geometry.size.width * snapshot.progress)
                }
            }
        }
        .frame(height: 3)
        .background(TX.raised)
        .accessibilityHidden(true)
    }

    private var navigationRow: some View {
        HStack(spacing: 8) {
            Button(action: onShowRadio) {
                HStack(spacing: 6) {
                    Text(frequencyText).font(TX.data(18, .semibold))
                        .lineLimit(1).minimumScaleFactor(0.75)
                    Text(bandText).font(TX.data(10.5))
                        .padding(.horizontal, 5).padding(.vertical, 3)
                        .background(TX.raised, in: RoundedRectangle(cornerRadius: 5))
                }
                .foregroundStyle(TX.text1)
                .frame(maxWidth: .infinity, minHeight: TX.hitMin, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("电台频率 \(frequencyText)，\(bandText)，打开电台页")
            Picker("数字模式", selection: modeBinding) {
                Text("FT8").tag("FT8")
                Text("FT4").tag("FT4")
            }
            .font(TX.ui(12, .semibold))
            .pickerStyle(.segmented)
            .frame(width: 88, height: 30)
            Button { showInfo = true } label: {
                Image(systemName: "info.circle")
                    .font(TX.ui(17)).foregroundStyle(TX.text3)
                    .frame(width: TX.hitMin, height: TX.hitMin)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("解码说明与刷新")
        }
        .padding(.leading, TX.pagePad)
        .frame(height: 44)
    }

    private var slotStatus: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            if let clock = RadioLiteDigitalSlotClock(mode: decodeFeed.mode) {
                let snapshot = clock.snapshot(at: context.date)
                let state = clock.displayState(
                    at: context.date, rigState: session.rigState, automaticQSO: session.automaticQSO
                )
                let delta = RadioLiteFT8TimingPresentation.meanDelta(
                    batches: session.decodeBatches, mode: decodeFeed.mode, at: context.date
                )
                let needsClockCheck = delta.map { abs($0) > 1 } ?? false
                HStack(spacing: 6) {
                    Circle().fill(displayColor(state)).frame(width: 5, height: 5)
                    Text(displayLabel(state)).font(TX.ui(11, .semibold))
                        .foregroundStyle(displayColor(state))
                    Text(delta.map { "Δt \(String(format: "%+.1f", $0))s" } ?? "Δt —")
                        .font(TX.data(11)).foregroundStyle(needsClockCheck ? TX.amber : TX.text3)
                    if needsClockCheck {
                        Text("请对时").font(TX.ui(10.5, .semibold)).foregroundStyle(TX.amber)
                    }
                    Spacer(minLength: 2)
                    Text("\(snapshot.remainingSeconds, specifier: "%.1f")s")
                        .font(TX.data(12.5)).foregroundStyle(TX.text2)
                }
                .padding(.horizontal, TX.pagePad)
                .frame(height: 30)
                .background(needsClockCheck ? TX.amber.opacity(0.09) : TX.card)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(height: 30)
    }

    private var filterRow: some View {
        HStack(spacing: 5) {
            ForEach(DecodeFilter.allCases) { item in
                Button {
                    filter = item
                    decodeFeed.resume()
                } label: {
                    HStack(spacing: 3) {
                        Text(item.rawValue)
                        if item == .toMe && toMeCount > 0 {
                            Text("\(toMeCount)").font(TX.data(10.5, .semibold))
                        }
                    }
                    .font(TX.ui(12, .semibold))
                    .foregroundStyle(filter == item ? (item == .toMe ? TX.amber : TX.teal) : TX.text3)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background(filter == item ? TX.raised : TX.card, in: RoundedRectangle(cornerRadius: TX.chipRadius))
                    .overlay {
                        RoundedRectangle(cornerRadius: TX.chipRadius)
                            .strokeBorder(filter == item ? TX.stroke : TX.divider)
                    }
                    .frame(height: TX.hitMin)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(filter == item ? .isSelected : [])
            }
        }
        .padding(.horizontal, TX.pagePad)
        .frame(height: 44)
    }

    private func callerCard(_ decode: RadioLiteDigitalDecode) -> some View {
        Button {
            filter = .all
            decodeFeed.select(decodeId: decode.id)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "arrow.turn.down.right").font(TX.ui(18, .semibold))
                VStack(alignment: .leading, spacing: 3) {
                    Text("有人在呼叫你 · 最新时隙").font(TX.ui(11, .semibold))
                    Text(decode.message).font(TX.data(14.5, .semibold))
                        .lineLimit(1).minimumScaleFactor(0.75)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(TX.ui(12, .semibold))
            }
            .foregroundStyle(TX.amber)
            .padding(.horizontal, TX.pagePad)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(TX.amber.opacity(0.09), in: RoundedRectangle(cornerRadius: TX.cardRadius))
            .padding(.horizontal, TX.pagePad)
            .frame(height: 66)
        }
        .buttonStyle(.plain)
        .accessibilityHint("仅选中消息；加入队列需要再次点击，不会自动发射")
    }

    private func decodeList(
        _ sections: [DecodeSection], worked: Set<String>, rowHeight: CGFloat, omitFirstHeader: Bool
    ) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    Color.clear.frame(height: 0).id(DecodeHistoryAnchor.latest)
                    if sections.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "waveform").font(TX.ui(26))
                            Text(decodeFeed.displayedBatches.isEmpty ? "等待 \(decodeFeed.mode) 解码" : "没有符合筛选的消息")
                                .font(TX.ui(15))
                        }
                        .foregroundStyle(TX.text3)
                        .frame(maxWidth: .infinity, minHeight: 160)
                    }
                    ForEach(sections) { section in
                        if !omitFirstHeader || section.id != sections.first?.id {
                            slotSeparator(section)
                        }
                        ForEach(section.decodes) { decode in
                            let presentation = RadioLiteDenseDecodePresentation(
                                decode: decode, slotStartMs: section.batch.slotStartMs,
                                stationCallsign: stationCallsign, workedCallsigns: worked
                            )
                            Button { decodeFeed.select(decodeId: decode.id) } label: {
                                RadioLiteDenseDecodeRow(
                                    presentation: presentation, selected: selectedDecode?.id == decode.id,
                                    height: rowHeight
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .scrollIndicators(.visible)
            .simultaneousGesture(
                DragGesture(minimumDistance: 4).onChanged { _ in decodeFeed.pauseFollowingLatest() }
            )
            .onChange(of: decodeFeed.latestScrollRequestRevision) { _, _ in
                proxy.scrollTo(DecodeHistoryAnchor.latest, anchor: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomTrailing) {
            if !decodeFeed.isFollowingLatest && selectedDecode == nil {
                Button("回到最新") { decodeFeed.resume() }
                    .font(TX.ui(12, .semibold)).foregroundStyle(TX.teal)
                    .padding(.horizontal, 12).frame(height: TX.hitMin)
                    .background(TX.raised, in: Capsule())
                    .padding(8)
            }
        }
    }

    private func slotSeparator(_ section: DecodeSection) -> some View {
        HStack(spacing: 8) {
            Rectangle().fill(TX.divider).frame(height: 1)
            Text("\(Self.utcSlotFormatter.string(from: Date(timeIntervalSince1970: Double(section.batch.slotStartMs) / 1_000))) UTC · \(section.decodes.count)")
                .font(TX.data(10.5)).foregroundStyle(TX.text3)
                .fixedSize()
        }
        .padding(.horizontal, TX.pagePad)
        .frame(height: 20)
    }

    private var operationBar: some View {
        HStack(spacing: 8) {
            Button { showOperations = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(TX.ui(18, .semibold))
                    .frame(width: TX.hitMin, height: TX.hitMin)
                    .background(TX.raised, in: RoundedRectangle(cornerRadius: TX.chipRadius))
            }
            .buttonStyle(.plain).foregroundStyle(TX.teal)
            .accessibilityLabel("频谱、呼叫队列和手动操作")
            if let decode = selectedDecode {
                Text(decode.message).font(TX.data(12))
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("取消") { decodeFeed.resume() }
                    .font(TX.ui(12)).foregroundStyle(TX.text3)
                    .frame(minWidth: TX.hitMin, minHeight: TX.hitMin)
                Button("入队") {
                    Task {
                        await session.addDecodeToQueue(decode.id)
                        decodeFeed.resume()
                    }
                }
                .font(TX.ui(13, .semibold))
                .buttonStyle(RadioActionButtonStyle(tint: TX.teal, prominent: true))
                .disabled(!session.hasControl)
                .accessibilityLabel("将选中解码加入呼叫队列")
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.automaticQSO?.targetCallsign ?? "点选解码加入队列")
                        .font(TX.data(13, .semibold)).lineLimit(1)
                    Text(session.digitalActionStatus ?? "\(session.callQueue?.entries.count ?? 0) 个排队 · \(decodeFeed.mode)")
                        .font(TX.ui(11)).foregroundStyle(TX.text3).lineLimit(1)
                }
                Spacer(minLength: 0)
                if session.automaticQSO != nil {
                    Button("停止") { Task { await session.stopAutomaticQSO(requeue: false) } }
                        .font(TX.ui(13, .semibold))
                        .buttonStyle(RadioActionButtonStyle(tint: TX.txRed))
                } else {
                    Button("手动") { showOperations = true }
                        .font(TX.ui(13, .semibold))
                        .buttonStyle(RadioActionButtonStyle(tint: TX.teal))
                }
            }
        }
        .padding(.horizontal, TX.pagePad)
        .frame(height: 64)
        .background(TX.card)
        .overlay(alignment: .top) { Rectangle().fill(TX.divider).frame(height: 1) }
    }

    private var operationsSheet: some View {
        NavigationStack {
            ScrollView(.vertical) {
                LazyVStack(spacing: 12) {
                    if let qso = session.automaticQSO { qsoPanel(qso) }
                    RadioLiteSpectrumView(
                        spectrum: media.spectrum,
                        capability: media.spectrumCapability,
                        history: media.spectrumHistory,
                        policy: media.policy,
                        compact: true,
                        selectedAudioFrequencyHz: selectedDecode?.audioFrequencyHz,
                        transmitAudioFrequencyHz: session.automaticQSO?.audioFrequencyHz ?? Int(audioFrequency)
                    )
                    queuePanel
                    manualPanel
                }
                .padding(TX.pagePad)
            }
            .font(TX.ui(15)).foregroundStyle(TX.text1)
            .scrollDismissesKeyboard(.interactively)
            .background(TX.bg.ignoresSafeArea())
            .navigationTitle("数字操作").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showOperations = false }.font(TX.ui(15, .semibold))
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { focusedField = nil }.font(TX.ui(15))
                }
            }
        }
        .tint(TX.teal)
    }

    private var informationSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("保留当前模式最近的完整时隙；选中消息或浏览旧时隙时，新批次不会推动当前内容。")
                    Text("每行：UTC 分秒 / SNR / 音频 Hz / 报文 / 旗帜与网格。点选后在底部加入队列，原有控制权与发射联锁不变。")
                    Text("叫我：按完整呼号分词匹配，兼容便携呼号。新 DX：离线可识别、与本站不同国家/地区且尚未通联的呼号；未知归属不猜测，不代表完整 DXCC 统计。")
                    Text("Δt 是当前模式最近 30 秒接收解码的均值；绝对值超过 1 秒提示检查双方时间，并不证明本机时钟有误。")
                    Text("已通联或已入队的呼号弱化并加删除线；叫我的消息优先保留琥珀提示。红色 TX 状态只来自实际 PTT 状态，接收文本不冒充本站发射记录。")
                    Button("刷新数字状态") {
                        Task { try? await session.refreshDigitalSnapshot() }
                    }
                    .font(TX.ui(15, .semibold))
                    .buttonStyle(RadioActionButtonStyle(tint: TX.teal))
                }
                .font(TX.ui(15)).foregroundStyle(TX.text2).padding(TX.pagePad)
            }
            .background(TX.bg.ignoresSafeArea())
            .navigationTitle("解码说明").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showInfo = false }.font(TX.ui(15, .semibold))
                }
            }
        }
        .tint(TX.teal)
        .presentationDetents([.medium, .large])
    }

    private var queuePanel: some View {
        RadioPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("呼叫队列", systemImage: "list.number")
                        .font(TX.ui(17, .semibold))
                    Spacer()
                    Text("\(session.callQueue?.entries.count ?? 0) 个")
                        .font(TX.data(12))
                        .foregroundStyle(TX.text3)
                }
                if let status = session.digitalActionStatus {
                    Label(status, systemImage: "checkmark.circle.fill")
                        .font(TX.ui(12, .semibold))
                        .foregroundStyle(TX.teal)
                        .transition(.opacity)
                }
                if session.callQueue?.entries.isEmpty != false {
                    Text("队列为空。选择一条解码消息或在下方手动输入呼号。")
                        .font(TX.ui(15))
                        .foregroundStyle(TX.text3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(session.callQueue?.entries ?? []) { entry in
                        HStack(spacing: 10) {
                            Image(systemName: entry.status == "active" ? "antenna.radiowaves.left.and.right" : "clock")
                                .foregroundStyle(entry.status == "active" ? TX.txRed : TX.teal)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.targetCallsign)
                                    .font(TX.data(17, .semibold))
                                Text("\(entry.mode) · \(entry.audioFrequencyHz) Hz · \(entry.txParity == "odd" ? "奇数" : "偶数")时隙")
                                    .font(TX.ui(12))
                                    .foregroundStyle(TX.text3)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                Task { await session.removeQueueEntry(entry.id) }
                            } label: {
                                Image(systemName: "trash")
                                    .frame(width: 36, height: 36)
                                    .background(TX.txRed.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                            .disabled(entry.status == "active")
                        }
                        .padding(10)
                        .background(TX.raised.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
                    }
                    HStack {
                        Button("跳过当前") { Task { await session.skipQueue() } }
                            .buttonStyle(RadioActionButtonStyle(tint: TX.amber))
                        Button("停止自动 QSO") { Task { await session.stopAutomaticQSO(requeue: false) } }
                            .buttonStyle(RadioActionButtonStyle(tint: TX.txRed))
                    }
                }
            }
        }
    }

    private var manualPanel: some View {
        RadioPanel {
            VStack(alignment: .leading, spacing: 12) {
                Label("手动呼叫", systemImage: "keyboard")
                    .font(TX.ui(17, .semibold))
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
                .buttonStyle(RadioActionButtonStyle(tint: TX.teal, prominent: true))
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
                        .font(TX.ui(17, .semibold))
                        .foregroundStyle(qso.phase == "failed" ? TX.amber : TX.teal)
                    Spacer()
                    Text(qso.phase.replacingOccurrences(of: "_", with: " ").uppercased())
                        .font(TX.data(12, .bold))
                        .foregroundStyle(TX.amber)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(qso.targetCallsign)
                        .font(TX.data(22, .bold))
                    if let grid = qso.targetGrid { Text(grid).foregroundStyle(TX.text3) }
                    Spacer()
                    Text(qso.mode).font(TX.ui(17, .semibold)).foregroundStyle(TX.teal)
                }
                if let outbound = qso.outboundMessage {
                    LabeledContent("下一条", value: outbound)
                        .font(TX.data(15))
                }
                if let inbound = qso.lastInboundMessage {
                    LabeledContent("收到", value: inbound)
                        .font(TX.data(15))
                }
                if let failure = qso.failureReason {
                    Text(failure).font(TX.ui(12)).foregroundStyle(TX.amber)
                }
                HStack {
                    Button("暂停并重排") { Task { await session.stopAutomaticQSO(requeue: true) } }
                        .buttonStyle(RadioActionButtonStyle(tint: TX.amber))
                    Button("停止") { Task { await session.stopAutomaticQSO(requeue: false) } }
                        .buttonStyle(RadioActionButtonStyle(tint: TX.txRed))
                }
            }
        }
    }

    private var selectedDecode: RadioLiteDigitalDecode? { decodeFeed.selectedDecode }
    private var stationCallsign: String? { session.selectedRadio?.station.callsign }

    private var modeBinding: Binding<String> {
        Binding(
            get: { decodeFeed.mode },
            set: { decodeFeed.changeMode(to: $0, batches: session.decodeBatches) }
        )
    }

    private func cacheWorkedCallsigns() {
        cachedWorkedCallsigns = Set(session.qsos.map { RadioLiteDenseDecodeSemantics.baseCallsign($0.call) })
    }

    private var workedCallsigns: Set<String> {
        var result = cachedWorkedCallsigns
        result.formUnion(session.callQueue?.entries.map {
            RadioLiteDenseDecodeSemantics.baseCallsign($0.targetCallsign)
        } ?? [])
        if let target = session.automaticQSO?.targetCallsign {
            result.insert(RadioLiteDenseDecodeSemantics.baseCallsign(target))
        }
        return result
    }

    private func isToMe(_ decode: RadioLiteDigitalDecode) -> Bool {
        decode.message.split(whereSeparator: \.isWhitespace).contains {
            RadioLiteDenseDecodeSemantics.matchesCallsign(String($0), stationCallsign)
        }
    }

    private var toMeCount: Int {
        decodeFeed.displayedBatches.reduce(0) { $0 + $1.decodes.filter(isToMe).count }
    }

    private var latestCaller: RadioLiteDigitalDecode? {
        guard decodeFeed.isFollowingLatest, let batch = decodeFeed.displayedBatches.first,
              Date().timeIntervalSince1970 - Double(batch.receivedAtMs) / 1_000 < 30 else { return nil }
        return batch.decodes.first(where: isToMe)
    }

    private func visibleSections(worked: Set<String>) -> [DecodeSection] {
        decodeFeed.displayedBatches.compactMap { batch in
            let decodes = batch.decodes.filter { decode in
                switch filter {
                case .all: return true
                case .toMe: return isToMe(decode)
                case .cq:
                    return decode.message.split(whereSeparator: \.isWhitespace).first
                        .map { RadioLiteDenseDecodeSemantics.normalizedToken(String($0)) } == "CQ"
                case .newDX:
                    return RadioLiteDenseDecodeSemantics.isNewDX(
                        message: decode.message, stationCallsign: stationCallsign, workedCallsigns: worked
                    )
                }
            }
            return decodes.isEmpty ? nil : DecodeSection(batch: batch, decodes: decodes)
        }
    }

    private var frequencyText: String {
        guard let hz = session.rigState?.frequencyHz, hz > 0 else { return "—.——— ———" }
        return String(format: "%lld.%03lld %03lld", hz / 1_000_000, (hz / 1_000) % 1_000, hz % 1_000)
    }

    private var bandText: String {
        guard let hz = session.rigState?.frequencyHz else { return "—" }
        switch hz {
        case 1_800_000...2_000_000: return "160m"
        case 3_500_000...4_000_000: return "80m"
        case 7_000_000...7_300_000: return "40m"
        case 10_100_000...10_150_000: return "30m"
        case 14_000_000...14_350_000: return "20m"
        case 18_068_000...18_168_000: return "17m"
        case 21_000_000...21_450_000: return "15m"
        case 24_890_000...24_990_000: return "12m"
        case 28_000_000...29_700_000: return "10m"
        default: return "HF"
        }
    }

    private func displayLabel(_ state: RadioLiteDigitalSlotClock.DisplayState) -> String {
        switch state {
        case .receiving: "RX 接收"
        case .waitingToTransmit: "等待 TX"
        case .transmitting: "TX 发射"
        }
    }

    private func displayColor(_ state: RadioLiteDigitalSlotClock.DisplayState) -> Color {
        switch state {
        case .receiving: TX.teal
        case .waitingToTransmit: TX.amber
        case .transmitting: TX.txRed
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

private struct RadioLiteDenseDecodeRow: View {
    let presentation: RadioLiteDenseDecodePresentation
    let selected: Bool
    let height: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(presentation.kind.rail ?? .clear).frame(width: 3)
            HStack(spacing: 8) {
                Text(presentation.time).font(TX.data(10.5))
                    .foregroundStyle(metadataColor).frame(width: 32)
                Text(presentation.snr).font(TX.data(12.5))
                    .foregroundStyle(presentation.kind == .myTx ? TX.txRed : snrColor)
                    .frame(width: 27, alignment: .trailing)
                Text(presentation.frequency).font(TX.data(10.5))
                    .foregroundStyle(metadataColor).frame(width: 32, alignment: .trailing)
                messageText
                    .tracking(0.15).lineLimit(1).minimumScaleFactor(0.72)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !presentation.tail.isEmpty {
                    Text(presentation.tail).font(TX.data(10.5)).foregroundStyle(metadataColor)
                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.leading, 9).padding(.trailing, TX.pagePad)
        }
        .frame(height: height)
        .contentShape(Rectangle())
        .background(presentation.kind.rowBackground)
        .overlay(alignment: .bottom) { Rectangle().fill(TX.divider).frame(height: 0.5) }
        .overlay {
            if selected { Rectangle().strokeBorder(TX.teal.opacity(0.6), lineWidth: 1) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityValue(selected ? "已选中" : "未选中")
    }

    private var metadataColor: Color {
        presentation.kind == .worked ? TX.textMuted : TX.text3
    }

    private var snrColor: Color {
        presentation.kind == .worked ? TX.textMuted : TX.text1.opacity(0.78 / 0.92)
    }

    private var messageText: Text {
        presentation.segments.reduce(Text("")) { result, segment in
            let color: Color = segment.isStation ? TX.amber :
                (segment.isCQPrefix && presentation.kind != .worked ? TX.teal : presentation.kind.messageColor)
            return result + Text(segment.text)
                .font(TX.data(14.5, segment.isStation ? .bold : .medium))
                .foregroundColor(color)
                .strikethrough(presentation.kind.strikethrough, color: TX.textMuted)
        }
    }
}
