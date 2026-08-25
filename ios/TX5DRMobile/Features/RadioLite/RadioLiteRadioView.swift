import SwiftUI

struct RadioLiteRadioView: View {
    @EnvironmentObject private var session: RadioLiteSession
    @EnvironmentObject private var media: RadioLiteMediaClient
    @EnvironmentObject private var audio: RadioLiteAudioEngine
    @State private var frequencyMHz = "14.074000"
    @FocusState private var frequencyFocused: Bool

    private let modes = ["USB", "LSB", "CW", "CWR", "AM", "FM", "DIGU", "DIGL"]

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                statusStrip
                frequencyPanel
                RadioLiteSpectrumView(spectrum: media.spectrum)
                audioPanel
                transmitPanel
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 28)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(RadioPalette.background.ignoresSafeArea())
        .navigationTitle(session.selectedRadio?.name ?? "Radio Lite")
        .navigationBarTitleDisplayMode(.inline)
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
        .onAppear(perform: syncFrequency)
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
                        ForEach(modes, id: \.self) { mode in
                            Button(mode) { Task { await session.setMode(mode) } }
                                .buttonStyle(RadioLiteModeButtonStyle(selected: session.rigState?.mode == mode))
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
        if audio.isMonitoring {
            audio.stopMonitoring()
            return
        }
        do {
            try audio.startMonitoring()
        } catch {
            session.errorMessage = error.localizedDescription
        }
    }

    private var transmitPanel: some View {
        RadioPanel {
            VStack(spacing: 14) {
                if !session.hasControl {
                    HStack {
                        Label("需要控制权才能操作电台", systemImage: "person.2.badge.gearshape")
                            .font(.subheadline)
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
                }
                Text("松开按钮立即撤销发射并关闭麦克风；连续语音最多 3 分钟，天调最多 30 秒。")
                    .font(.caption)
                    .foregroundStyle(RadioPalette.muted)
            }
        }
    }

    private var isTransmitting: Bool {
        session.isVoicePTTHeld || session.isTuning || session.rigState?.ptt == true
    }

    private func syncFrequency() {
        guard let hz = session.rigState?.frequencyHz else { return }
        frequencyMHz = String(format: "%.6f", Double(hz) / 1_000_000)
    }
}

private struct RadioLiteSpectrumView: View {
    let spectrum: RadioLiteSpectrumFrame?

    var body: some View {
        RadioPanel {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Label("实时频谱", systemImage: "waveform.path")
                        .font(.headline)
                    Spacer()
                    if let spectrum {
                        Text("±\(spectrum.spanHz / 2) Hz · \(spectrum.bins.count) 点")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(RadioPalette.muted)
                    }
                }
                Canvas { context, size in
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
                    context.stroke(Path { path in
                        path.move(to: CGPoint(x: size.width / 2, y: 0))
                        path.addLine(to: CGPoint(x: size.width / 2, y: size.height))
                    }, with: .color(RadioPalette.accent.opacity(0.65)), lineWidth: 1)
                }
                .frame(height: 170)
                .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                if spectrum == nil {
                    Text("等待媒体通道频谱数据…")
                        .font(.caption)
                        .foregroundStyle(RadioPalette.muted)
                        .frame(maxWidth: .infinity)
                }
            }
        }
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
