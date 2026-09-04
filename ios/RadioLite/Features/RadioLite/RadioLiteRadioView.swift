import SwiftUI

struct RadioLiteRadioView: View {
    @EnvironmentObject private var session: RadioLiteSession
    @EnvironmentObject private var media: RadioLiteMediaClient
    @EnvironmentObject private var audio: RadioLiteAudioEngine
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("radio-lite.receive-audio.has-visited") private var hasVisitedRadioPage = false
    @AppStorage("radio-lite.receive-audio.explicit-choice") private var receiveMonitoringChoice = -1
    @State private var isFrequencyEditing = false
    @State private var isVolumeEditing = false
    @State private var activeSliderIDs: Set<UUID> = []
    @State private var showTransmitInfo = false
    @State private var transmitStartedAt: Date?

    private let modes = RadioLiteRigMode.allCases

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                statusStrip
                frequencyPanel
                RadioLiteTelemetryStrip(
                    telemetry: session.telemetry,
                    isTransmitting: isTransmitting
                )
            }
            .padding(.horizontal, TX.pagePad)
            .padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 12) {
                    RadioLiteSpectrumView(
                        spectrum: media.spectrum,
                        capability: media.spectrumCapability,
                        history: media.spectrumHistory,
                        policy: media.policy
                    )
                    audioPanel
                    RadioLiteRigControlsView(
                        isTransmitting: isTransmitting,
                        hasControl: session.hasControl
                    )
                    .accessibilityHint(
                        canUseTunerAction ? "天调功能可用" : "天调功能不可用"
                    )
                }
                .padding(.horizontal, TX.pagePad)
                .padding(.bottom, 18)
            }
            .scrollDisabled(isFrequencyEditing || isVolumeEditing || !activeSliderIDs.isEmpty)
            .scrollDismissesKeyboard(.interactively)
        }
        .environment(\.radioLiteSliderEditing) { id, editing in
            if editing { activeSliderIDs.insert(id) }
            else { activeSliderIDs.remove(id) }
        }
        .background(TX.bg.ignoresSafeArea())
        .navigationTitle(session.selectedRadio?.name ?? "Radio Lite")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            transmitDock
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { try? await session.refreshRigState() } } label: {
                    Image(systemName: "arrow.clockwise").font(TX.ui(15, .semibold))
                }
                .tint(TX.teal)
            }
        }
        .popover(isPresented: $showTransmitInfo) { transmitInfo }
        .onAppear(perform: handleRadioPageAppearance)
        .onChange(of: isTransmitting) { _, transmitting in
            transmitStartedAt = transmitting ? .now : nil
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                isVolumeEditing = false
                activeSliderIDs.removeAll()
            }
        }
        .onDisappear {
            session.endVoicePTT()
            session.cancelTuning()
            activeSliderIDs.removeAll()
            isVolumeEditing = false
        }
    }

    private var statusStrip: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 5) {
                Circle()
                    .fill(session.control.state == .ready ? TX.teal : TX.amber)
                    .frame(width: 6, height: 6)
                Text(session.control.state == .ready ? (session.hasControl ? "控制中" : "只读") : session.control.state.label)
                    .font(TX.ui(12, .semibold))
                    .foregroundStyle(TX.text1)
                Text(roundTripLabel)
                    .font(TX.data(10.5)).foregroundStyle(TX.text3)
                if session.hasControl {
                    Text("· \(remainingLease(at: context.date))")
                        .font(TX.data(10.5)).foregroundStyle(TX.text2)
                }
                Spacer(minLength: 0)
                if session.radios.count > 1 { radioMenu }
                Button(session.hasControl ? "交还" : "接管控制") {
                    Task {
                        if session.hasControl { await session.releaseControl() }
                        else { try? await session.acquireControl(force: session.isAdmin) }
                    }
                }
                .font(TX.ui(11, .semibold))
                .foregroundStyle(session.hasControl ? TX.text2 : TX.bg)
                .padding(.horizontal, 9)
                .frame(minHeight: TX.hitMin)
                .background(
                    session.hasControl ? TX.raised : TX.amber,
                    in: RoundedRectangle(cornerRadius: TX.chipRadius)
                )
                .buttonStyle(.plain)
                .disabled(session.control.state != .ready)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.85)
        }
        .frame(height: TX.hitMin)
    }

    private var radioMenu: some View {
        Menu {
            ForEach(session.radios) { radio in
                Button {
                    Task { await session.selectRadio(radio.id) }
                } label: {
                    if radio.id == session.selectedRadioId { Label(radio.name, systemImage: "checkmark") }
                    else { Text(radio.name) }
                }
            }
        } label: {
            Label(session.selectedRadio?.name ?? "电台", systemImage: "chevron.down")
                .font(TX.ui(10.5, .semibold))
                .foregroundStyle(TX.text2)
                .lineLimit(1)
                .frame(maxWidth: 70, minHeight: TX.hitMin)
        }
        .buttonStyle(.plain)
    }

    private var frequencyPanel: some View {
        RadioPanel {
            VStack(spacing: 8) {
                RadioLiteFrequencyControls(isEditing: $isFrequencyEditing)
                    .id(session.selectedRadioId)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 5), spacing: 5) {
                    ForEach(modes) { mode in
                        Button(mode.label) { Task { await session.setMode(mode) } }
                            .buttonStyle(RadioLiteModeButtonStyle(
                                selected: mode.matches(readback: session.rigState?.mode)
                            ))
                            .disabled(!session.hasControl)
                    }
                }
                Text("带宽 \(session.rigState?.passbandHz ?? 0) Hz · 长按频率输入")
                    .font(TX.data(10.5))
                    .foregroundStyle(TX.text3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var audioPanel: some View {
        RadioPanel {
            VStack(spacing: 13) {
                HStack {
                    Label("接收音频", systemImage: "speaker.wave.2.fill")
                        .font(TX.ui(15, .semibold))
                        .foregroundStyle(TX.text1)
                    Spacer()
                    Text(media.policy?.tier.uppercased() ?? "—")
                        .font(TX.data(11, .bold))
                        .foregroundStyle(TX.teal)
                }
                HStack(spacing: 12) {
                    Button(action: toggleMonitoring) {
                        Image(systemName: audio.isMonitoring ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .font(TX.ui(16))
                            .foregroundStyle(TX.teal)
                            .frame(width: TX.hitMin, height: TX.hitMin)
                            .background(TX.raised, in: RoundedRectangle(cornerRadius: TX.chipRadius))
                    }
                    .buttonStyle(.plain)
                    Slider(value: $audio.monitorVolume, in: 0...1, onEditingChanged: { isVolumeEditing = $0 })
                        .tint(TX.teal)
                        .padding(.vertical, 12)
                    Text("\(Int(audio.monitorVolume * 100))%")
                        .font(TX.data(11))
                        .foregroundStyle(TX.text3)
                        .frame(width: 38)
                }
                HStack {
                    Label("Opus \((media.policy?.opusBitrate ?? 0) / 1_000) kb/s", systemImage: "waveform")
                    Spacer()
                    Label("RTT \(Int(media.lastRoundTripMs)) ms", systemImage: "timer")
                }
                .font(TX.data(11))
                .foregroundStyle(TX.text3)
            }
        }
    }

    private func toggleMonitoring() {
        let shouldMonitor = !audio.isMonitoring
        var preference = receiveMonitoringPreference
        preference.recordExplicitUserChoice(shouldMonitor)
        persistReceiveMonitoringPreference(preference)

        if !shouldMonitor {
            session.stopReceiveAudio()
            return
        }
        Task { await session.startReceiveAudio() }
    }

    private var transmitDock: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            HStack(spacing: 8) {
                RadioLiteHoldButton(
                    title: transmitTitle(at: context.date),
                    active: isTransmitting,
                    enabled: session.hasControl && session.canTransmit
                ) {
                    session.beginVoicePTT()
                } onRelease: {
                    session.endVoicePTT()
                }
                Button { showTransmitInfo = true } label: {
                    Image(systemName: "info.circle")
                        .font(TX.ui(17))
                        .foregroundStyle(TX.text3)
                        .frame(width: TX.hitMin, height: TX.hitMin)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("查看 PTT 状态与原因")
            }
        }
        .padding(.horizontal, TX.pagePad)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(TX.bg.opacity(0.97))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(TX.divider)
                .frame(height: 0.5)
        }
    }

    private var transmitInfo: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("发射状态").font(TX.ui(17, .semibold)).foregroundStyle(TX.text1)
            Text(transmitReason).font(TX.ui(14)).foregroundStyle(TX.text2)
            if !session.radioCapabilitiesAvailable {
                Text("兼容电台控制：服务器未提供新版分组控制，现有兼容控件仍可使用。")
                    .font(TX.ui(12)).foregroundStyle(TX.text3)
            }
            Text("SWR 与功率只显示电台提供的读数；无有效读数时显示 —。计时从 App 观察到发射状态起算。")
                .font(TX.ui(12)).foregroundStyle(TX.text3)
        }
        .padding(18)
        .frame(maxWidth: 340, alignment: .leading)
        .presentationBackground(TX.card)
        .presentationCompactAdaptation(.popover)
    }

    private var transmitReason: String {
        if !session.hasControl { return "当前只读，请在页面顶部接管控制权。" }
        if !session.canTransmit { return "当前账户没有发射权限，或电台尚未启用硬件发射。" }
        if session.isVoicePTTHeld { return "松开 PTT 即结束语音发射。" }
        if session.isTuning { return "电台正在调谐；调谐控制保留在天调面板。" }
        if session.rigState?.ptt == true { return "电台读回为发射中。" }
        return "按住 PTT 开始语音发射，松开立即结束。"
    }

    private func transmitTitle(at date: Date) -> String {
        if isTransmitting {
            let nowMs = UInt64(max(0, date.timeIntervalSince1970 * 1_000))
            let swr: String
            if let telemetry = session.telemetry,
               !telemetry.isStale(nowMs: nowMs, periodMs: 1_000),
               telemetry.supportsMeter("SWR"),
               let value = telemetry.meters.swr, value.isFinite {
                swr = String(format: "%.1f", value)
            } else { swr = "—" }
            let elapsed = transmitStartedAt.map { String(format: "%.1f s", max(0, date.timeIntervalSince($0))) } ?? "— s"
            return "发射中  SWR \(swr) · \(elapsed)"
        }
        if !session.hasControl { return "先接管控制权 · 当前只读" }
        if !session.canTransmit { return "PTT 不可用 · 查看原因" }
        return "按住 PTT · \(configuredPower)"
    }

    private var configuredPower: String {
        if let capability = session.radioCapabilities.first(where: { $0.token.uppercased() == "RFPOWER" }) {
            return capability.formattedValue()
        }
        if let legacy = session.rigControls.first(where: { $0.token.uppercased() == "RFPOWER" }) {
            return legacy.displayState(isTransmitting: isTransmitting).formattedValue()
        }
        return "功率 —"
    }

    private var roundTripLabel: String {
        guard media.state == .ready, media.lastRoundTripMs.isFinite,
              media.lastRoundTripMs > 0 else { return "RTT —" }
        return "\(Int(media.lastRoundTripMs)) ms"
    }

    private func remainingLease(at date: Date) -> String {
        guard let expiry = session.controlExpiresAtMs else { return "剩余 —" }
        let seconds = max(0, Int((Double(expiry) / 1_000 - date.timeIntervalSince1970).rounded(.up)))
        return String(format: "剩余 %d:%02d", seconds / 60, seconds % 60)
    }

    private var isTransmitting: Bool {
        session.isVoicePTTHeld || session.isTuning || session.rigState?.ptt == true
    }

    private var canUseTunerAction: Bool {
        if session.isTuning { return session.hasControl }
        guard let capability = session.tunerActionCapability else { return false }
        return session.canUseInternalTuner
            && capability.displayState(
                isTransmitting: isTransmitting,
                hasControl: session.hasControl
            ).isEnabled
    }

    private var receiveMonitoringPreference: RadioLiteReceiveMonitoringPreference {
        RadioLiteReceiveMonitoringPreference(
            hasVisitedRadioPage: hasVisitedRadioPage,
            explicitUserChoice: explicitReceiveMonitoringChoice
        )
    }

    private var explicitReceiveMonitoringChoice: Bool? {
        switch receiveMonitoringChoice {
        case 0: false
        case 1: true
        default: nil
        }
    }

    private func handleRadioPageAppearance() {
        if isTransmitting { transmitStartedAt = .now }
        var preference = receiveMonitoringPreference
        let decision = preference.radioPageDidAppear()
        persistReceiveMonitoringPreference(preference)
        switch decision {
        case .start:
            Task { await session.startReceiveAudio() }
        case .stop:
            session.stopReceiveAudio()
        case .preserve:
            break
        }
    }

    private func persistReceiveMonitoringPreference(_ preference: RadioLiteReceiveMonitoringPreference) {
        hasVisitedRadioPage = preference.hasVisitedRadioPage
        receiveMonitoringChoice = preference.explicitUserChoice.map { $0 ? 1 : 0 } ?? -1
    }
}

struct RadioLiteStatusPill: View {
    let text: String
    let color: Color
    let icon: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(TX.ui(11, .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(color.opacity(0.1), in: Capsule())
            .overlay { Capsule().strokeBorder(color.opacity(0.2)) }
    }
}

private struct RadioLiteModeButtonStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(TX.data(11, .semibold))
            .foregroundStyle(selected ? TX.bg : TX.text2)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(
                selected ? TX.teal : TX.raised,
                in: RoundedRectangle(cornerRadius: TX.chipRadius)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

private struct RadioLiteHoldButton: View {
    let title: String
    let active: Bool
    let enabled: Bool
    let onPress: () -> Void
    let onRelease: () -> Void
    @State private var pressing = false

    var body: some View {
        HStack(spacing: 7) {
            if active {
                Circle()
                    .fill(TX.text1)
                    .frame(width: 6, height: 6)
                    .phaseAnimator([false, true]) { content, phase in
                        content.opacity(phase ? 1 : 0.35)
                    } animation: { _ in .easeInOut(duration: 0.7) }
            }
            Text(title)
                .font(TX.data(12.5, .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
            .foregroundStyle(active ? TX.text1 : enabled ? TX.txRed : TX.text3)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(
                active ? TX.txRed : TX.card,
                in: RoundedRectangle(cornerRadius: TX.cardRadius)
            )
            .overlay {
                RoundedRectangle(cornerRadius: TX.cardRadius)
                    .strokeBorder(enabled || active ? TX.txRed : TX.stroke)
            }
            .scaleEffect(pressing ? 0.97 : 1)
            .contentShape(RoundedRectangle(cornerRadius: TX.cardRadius))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard enabled, !pressing else { return }
                        pressing = true
                        onPress()
                    }
                    .onEnded { _ in
                        guard pressing else { return }
                        pressing = false
                        onRelease()
                    }
            )
            .onDisappear {
                if pressing { pressing = false; onRelease() }
            }
            .accessibilityAddTraits(.isButton)
    }
}
