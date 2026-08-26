import SwiftUI

struct RadioLiteRadioView: View {
    @EnvironmentObject private var session: RadioLiteSession
    @EnvironmentObject private var media: RadioLiteMediaClient
    @EnvironmentObject private var audio: RadioLiteAudioEngine
    @AppStorage("radio-lite.receive-audio.has-visited") private var hasVisitedRadioPage = false
    @AppStorage("radio-lite.receive-audio.explicit-choice") private var receiveMonitoringChoice = -1
    @State private var frequencyMHz = "14.074000"
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
        .onDisappear { session.endVoicePTT(); session.endTuning() }
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
                RadioLiteHoldButton(
                    title: session.isTuning ? "天调工作中" : "按住机内天调",
                    systemImage: "tuningfork",
                    active: session.isTuning,
                    tint: RadioPalette.warning,
                    enabled: session.hasControl && session.canTransmit
                ) {
                    session.beginTuning()
                } onRelease: {
                    session.endTuning()
                }
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

private struct RadioLiteSpectrumView: View {
    let spectrum: RadioLiteSpectrumFrame?
    let capability: RadioLiteSpectrumCapability?
    let history: [[UInt8]]
    let policy: RadioLiteMediaPolicy?
    @State private var isExpanded = false

    var body: some View {
        RadioPanel {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Label("实时频谱", systemImage: "waveform.path")
                        .font(.headline)
                    Spacer()
                    sourceBadge
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                            .font(.caption.weight(.bold))
                            .frame(width: 30, height: 30)
                            .background(RadioPalette.panelRaised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(RadioPalette.cyan)
                    .accessibilityLabel(isExpanded ? "收起频谱" : "展开频谱")
                }
                Text(axisDescription)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(RadioPalette.muted)
                Canvas { context, size in
                    var grid = Path()
                    for division in 1..<4 {
                        let x = size.width * CGFloat(division) / 4
                        grid.move(to: CGPoint(x: x, y: 0))
                        grid.addLine(to: CGPoint(x: x, y: size.height))
                        let y = size.height * CGFloat(division) / 4
                        grid.move(to: CGPoint(x: 0, y: y))
                        grid.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    context.stroke(grid, with: .color(Color.white.opacity(0.07)), lineWidth: 0.5)
                    guard let bins = spectrum?.bins, bins.count > 1 else { return }
                    let step = size.width / CGFloat(bins.count - 1)
                    var line = Path()
                    var fill = Path()
                    for (index, value) in bins.enumerated() {
                        let x = CGFloat(index) * step
                        let y = size.height * (1 - CGFloat(value) / 255)
                        if index == 0 {
                            line.move(to: CGPoint(x: x, y: y))
                            fill.move(to: CGPoint(x: x, y: size.height))
                            fill.addLine(to: CGPoint(x: x, y: y))
                        } else {
                            line.addLine(to: CGPoint(x: x, y: y))
                            fill.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                    fill.addLine(to: CGPoint(x: size.width, y: size.height))
                    fill.closeSubpath()
                    context.fill(fill, with: .linearGradient(
                        Gradient(colors: [RadioPalette.cyan.opacity(0.55), RadioPalette.cyan.opacity(0.02)]),
                        startPoint: .zero,
                        endPoint: CGPoint(x: 0, y: size.height)
                    ))
                    context.stroke(line, with: .color(RadioPalette.cyan), lineWidth: 1.4)
                }
                .frame(height: isExpanded ? 145 : 80)
                .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 13, style: .continuous))

                if let statusMessage {
                    Label(statusMessage, systemImage: statusIcon)
                        .font(.caption)
                        .foregroundStyle(RadioPalette.muted)
                        .frame(maxWidth: .infinity)
                }

                if capability?.supportsWaterfall == true {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("瀑布图")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(RadioPalette.muted)
                        Canvas { context, size in
                            let rows = Array(history.reversed())
                            guard !rows.isEmpty else { return }
                            let rowHeight = size.height / CGFloat(rows.count)
                            for (rowIndex, bins) in rows.enumerated() where !bins.isEmpty {
                                let columnCount = bins.count
                                let columnWidth = size.width / CGFloat(columnCount)
                                for (column, level) in bins.enumerated() {
                                    let rectangle = CGRect(
                                        x: CGFloat(column) * columnWidth,
                                        y: CGFloat(rowIndex) * rowHeight,
                                        width: columnWidth + 0.5,
                                        height: rowHeight + 0.5
                                    )
                                    context.fill(Path(rectangle), with: .color(waterfallColor(level)))
                                }
                            }
                        }
                        .frame(height: isExpanded ? 112 : 70)
                        .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        HStack {
                            Text("0 Hz")
                            Spacer()
                            Text("\(displaySpanHz / 2) Hz")
                            Spacer()
                            Text("\(displaySpanHz) Hz")
                        }
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(RadioPalette.muted)
                    }
                }
            }
        }
    }

    private var sourceBadge: some View {
        let text: String
        let color: Color
        if capability?.available == false {
            text = "不可用"
            color = RadioPalette.warning
        } else if capability?.simulated == true {
            text = "模拟数据"
            color = RadioPalette.warning
        } else if capability?.available == true {
            text = "真实声卡 FFT"
            color = RadioPalette.accent
        } else {
            text = "协商中"
            color = RadioPalette.muted
        }
        return Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule())
    }

    private var displaySpanHz: UInt32 {
        spectrum?.spanHz ?? UInt32(max(0, capability?.spanHz ?? 0))
    }

    private var axisDescription: String {
        let points = spectrum?.bins.count ?? policy?.spectrumBins ?? 0
        guard let spectrum, spectrum.centerFrequencyHz > 0 else {
            return "接收音频 0–\(displaySpanHz) Hz · \(points) 点"
        }
        return String(
            format: "RX %.6f MHz · 音频 0–%.1f kHz · %d 点",
            Double(spectrum.centerFrequencyHz) / 1_000_000,
            Double(displaySpanHz) / 1_000,
            points
        )
    }

    private var statusMessage: String? {
        if capability?.available == false {
            return "服务端没有可用的频谱源，请检查接收音频输入设备"
        }
        if policy?.spectrumBins == 0 {
            return "弱网或后台策略已暂停频谱传输"
        }
        if spectrum == nil {
            return "等待接收声卡 FFT 数据…"
        }
        return nil
    }

    private var statusIcon: String {
        capability?.available == false ? "exclamationmark.triangle" : "hourglass"
    }

    private func waterfallColor(_ value: UInt8) -> Color {
        let level = pow(Double(value) / 255, 0.72)
        if level < 0.22 {
            return interpolateColor(
                from: (0, 0, 0),
                to: (0.01, 0.05, 0.38),
                progress: level / 0.22
            )
        }
        if level < 0.52 {
            return interpolateColor(
                from: (0.01, 0.05, 0.38),
                to: (0, 0.82, 0.92),
                progress: (level - 0.22) / 0.30
            )
        }
        if level < 0.80 {
            return interpolateColor(
                from: (0, 0.82, 0.92),
                to: (1, 0.88, 0.08),
                progress: (level - 0.52) / 0.28
            )
        }
        return interpolateColor(
            from: (1, 0.88, 0.08),
            to: (1, 1, 1),
            progress: (level - 0.80) / 0.20
        )
    }

    private func interpolateColor(
        from lower: (Double, Double, Double),
        to upper: (Double, Double, Double),
        progress: Double
    ) -> Color {
        let amount = min(1, max(0, progress))
        return Color(
            red: lower.0 + (upper.0 - lower.0) * amount,
            green: lower.1 + (upper.1 - lower.1) * amount,
            blue: lower.2 + (upper.2 - lower.2) * amount
        )
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
