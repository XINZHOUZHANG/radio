import SwiftUI

struct RadioLiteRadioView: View {
    @EnvironmentObject private var session: RadioLiteSession
    @EnvironmentObject private var media: RadioLiteMediaClient
    @EnvironmentObject private var audio: RadioLiteAudioEngine
    @AppStorage("radio-lite.receive-audio.has-visited") private var hasVisitedRadioPage = false
    @AppStorage("radio-lite.receive-audio.explicit-choice") private var receiveMonitoringChoice = -1
    @State private var frequencyMHz = "14.074000"
    @State private var pendingTunerSwitchValue: Bool?
    @State private var isTunerSwitchSubmitting = false
    @FocusState private var frequencyFocused: Bool

    private let modes = RadioLiteRigMode.allCases

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                statusStrip
                frequencyPanel
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            ScrollView {
                VStack(spacing: 14) {
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
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 18)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(RadioPalette.background.ignoresSafeArea())
        .navigationTitle(session.selectedRadio?.name ?? "Radio Lite")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            transmitDock
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { try? await session.refreshRigState() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { frequencyFocused = false }
            }
        }
        .onAppear(perform: handleRadioPageAppearance)
        .onChange(of: session.rigState?.frequencyHz) { _, _ in
            if !frequencyFocused { syncFrequency() }
        }
        .onDisappear { session.endVoicePTT(); session.cancelTuning() }
    }

    private var statusStrip: some View {
        HStack(spacing: 8) {
            RadioLiteStatusPill(
                text: session.control.state.label,
                color: session.control.state == .ready ? RadioPalette.accent : RadioPalette.warning,
                icon: "network"
            )
            RadioLiteStatusPill(
                text: session.hasControl ? "控制中" : "只读",
                color: session.hasControl ? RadioPalette.cyan : RadioPalette.warning,
                icon: session.hasControl ? "hand.raised.fill" : "hand.raised.slash"
            )
            Spacer()
            if session.radios.count > 1 { radioMenu }
        }
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
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(RadioPalette.panelRaised, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var frequencyPanel: some View {
        RadioPanel {
            VStack(spacing: 15) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    TextField("14.074000", text: $frequencyMHz)
                        .focused($frequencyFocused)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .font(.system(size: 45, weight: .medium, design: .rounded))
                        .minimumScaleFactor(0.62)
                        .foregroundStyle(isTransmitting ? RadioPalette.transmit : RadioPalette.accent)
                    Text("MHz")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(RadioPalette.muted)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(modes) { mode in
                            Button(mode.label) { Task { await session.setMode(mode) } }
                                .buttonStyle(RadioLiteModeButtonStyle(
                                    selected: mode.matches(readback: session.rigState?.mode)
                                ))
                        }
                    }
                }
                HStack {
                    Label(
                        "带宽 \(session.rigState?.passbandHz ?? 0) Hz",
                        systemImage: "arrow.left.and.right"
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(RadioPalette.muted)
                    Spacer()
                    Button("设定频率") {
                        frequencyFocused = false
                        Task { await session.setFrequency(mhzText: frequencyMHz) }
                    }
                    .buttonStyle(RadioActionButtonStyle(tint: RadioPalette.accent, prominent: true))
                    .disabled(!session.hasControl)
                }
            }
        }
    }

    private var audioPanel: some View {
        RadioPanel {
            VStack(spacing: 13) {
                HStack {
                    Label("接收音频", systemImage: "speaker.wave.2.fill")
                        .font(.headline)
                    Spacer()
                    Text(media.policy?.tier.uppercased() ?? "—")
                        .font(.caption.monospaced().weight(.bold))
                        .foregroundStyle(RadioPalette.cyan)
                }
                HStack(spacing: 12) {
                    Button(action: toggleMonitoring) {
                        Image(systemName: audio.isMonitoring ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .frame(width: 38, height: 38)
                            .background(RadioPalette.panelRaised, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    Slider(value: $audio.monitorVolume, in: 0...1)
                        .tint(RadioPalette.accent)
                    Text("\(Int(audio.monitorVolume * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(RadioPalette.muted)
                        .frame(width: 38)
                }
                HStack {
                    Label("Opus \((media.policy?.opusBitrate ?? 0) / 1_000) kb/s", systemImage: "waveform")
                    Spacer()
                    Label("RTT \(Int(media.lastRoundTripMs)) ms", systemImage: "timer")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(RadioPalette.muted)
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
        VStack(spacing: 9) {
            if !session.hasControl {
                HStack(spacing: 10) {
                    Label("需要控制权才能操作电台", systemImage: "person.2.badge.gearshape")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Button(session.isAdmin ? "接管" : "取得控制") {
                        Task { try? await session.acquireControl(force: session.isAdmin) }
                    }
                    .buttonStyle(RadioActionButtonStyle(tint: RadioPalette.warning))
                }
            }
            if let tunerSwitch {
                HStack(spacing: 10) {
                    Label("机内天调接入", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if isTunerSwitchSubmitting {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(tunerSwitchIsOn ? "已接入" : "旁路")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tunerSwitchIsOn ? RadioPalette.accent : RadioPalette.muted)
                    Toggle("机内天调接入", isOn: tunerSwitchBinding)
                        .labelsHidden()
                        .tint(RadioPalette.accent)
                        .disabled(!canSetTunerSwitch)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RadioPalette.panelRaised, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
            HStack(spacing: 12) {
                RadioLiteHoldButton(
                    title: session.isVoicePTTHeld ? "正在发射" : "按住 PTT",
                    systemImage: "mic.fill",
                    active: session.isVoicePTTHeld,
                    tint: RadioPalette.transmit,
                    enabled: session.hasControl && session.canTransmit
                ) {
                    session.beginVoicePTT()
                } onRelease: {
                    session.endVoicePTT()
                }
                Button {
                    switch RadioLiteTunerInteractionPolicy.action(
                        isTuning: session.isTuning,
                        tuneSupported: session.rigState?.supportsInternalTuner != false
                    ) {
                    case .start:
                        session.beginTuning()
                    case .stop:
                        session.endTuning()
                    case .unavailable:
                        break
                    }
                } label: {
                    Label(
                        session.rigState?.supportsInternalTuner == false
                            ? "不支持机内天调"
                            : (session.isTuning ? "停止调谐" : "开始调谐"),
                        systemImage: "tuningfork"
                    )
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(session.isTuning ? Color.white : RadioPalette.warning)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(
                        session.isTuning ? RadioPalette.warning : RadioPalette.warning.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(RadioPalette.warning.opacity(session.isTuning ? 0.8 : 0.34))
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!session.hasControl || !session.canUseInternalTuner)
            }
            if session.isVoicePTTHeld {
                ProgressView(value: audio.microphoneLevel)
                    .tint(RadioPalette.transmit)
                    .accessibilityLabel("麦克风电平")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 9)
        .padding(.bottom, 8)
        .background(RadioPalette.background.opacity(0.97))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.5)
        }
    }

    private var isTransmitting: Bool {
        session.isVoicePTTHeld || session.isTuning || session.rigState?.ptt == true
    }

    private var tunerSwitch: RadioLiteRigControl? {
        RadioLiteTunerInteractionPolicy.tunerSwitch(in: session.rigControls)
    }

    private var tunerSwitchIsOn: Bool {
        pendingTunerSwitchValue ?? ((tunerSwitch?.value ?? 0) >= 0.5)
    }

    private var canSetTunerSwitch: Bool {
        session.hasControl && !isTransmitting && !isTunerSwitchSubmitting
    }

    private var tunerSwitchBinding: Binding<Bool> {
        Binding(
            get: { tunerSwitchIsOn },
            set: { enabled in setTunerSwitch(enabled) }
        )
    }

    private func setTunerSwitch(_ enabled: Bool) {
        guard canSetTunerSwitch else { return }
        pendingTunerSwitchValue = enabled
        isTunerSwitchSubmitting = true
        Task {
            _ = await session.setRigControl("function:TUNER", value: enabled ? 1 : 0)
            pendingTunerSwitchValue = nil
            isTunerSwitchSubmitting = false
        }
    }

    private func syncFrequency() {
        guard let hz = session.rigState?.frequencyHz else { return }
        frequencyMHz = String(format: "%.6f", Double(hz) / 1_000_000)
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
        syncFrequency()
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
            .font(.caption.weight(.semibold))
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
            .font(.caption.monospaced().weight(.bold))
            .foregroundStyle(selected ? Color.black : Color.white)
            .padding(.horizontal, 13)
            .frame(minHeight: 38)
            .background(
                selected ? RadioPalette.accent : RadioPalette.panelRaised,
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

private struct RadioLiteHoldButton: View {
    let title: String
    let systemImage: String
    let active: Bool
    let tint: Color
    let enabled: Bool
    let onPress: () -> Void
    let onRelease: () -> Void
    @State private var pressing = false

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(active ? Color.white : tint)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(
                active ? tint : tint.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(tint.opacity(active ? 0.8 : 0.34))
            }
            .opacity(enabled ? 1 : 0.45)
            .scaleEffect(pressing ? 0.97 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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
