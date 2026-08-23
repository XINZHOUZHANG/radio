import SwiftUI

struct RadioControlView: View {
    @EnvironmentObject private var session: TX5DRSession
    @EnvironmentObject private var radio: RadioWebSocket
    @EnvironmentObject private var audio: TX5DRAudioClient
    @State private var frequencyMHz = "14.074000"
    @State private var voiceRadioMode = "USB"
    @State private var tunerEnabled = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                statusStrip
                frequencyPanel
                SpectrumPanelView()
                meterGrid
                primaryControls
                if !surfaceCapabilities.isEmpty {
                    RadioPanel {
                        VStack(alignment: .leading, spacing: 14) {
                            Label("电台能力", systemImage: "slider.horizontal.3")
                                .font(.headline)
                            ForEach(surfaceCapabilities) { descriptor in
                                CapabilityControlRow(
                                    descriptor: descriptor,
                                    state: radio.capabilities[descriptor.id]
                                )
                                if descriptor.id != surfaceCapabilities.last?.id { Divider().opacity(0.25) }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 24)
        }
        .background(RadioPalette.background.ignoresSafeArea())
        .navigationTitle("TX-5DR")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await session.refreshPrimaryData() }
                    radio.refreshCapabilities()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .onAppear(perform: syncFrequency)
        .onChange(of: radio.frequency) { _, _ in syncFrequency() }
        .onDisappear { session.endVoicePTT() }
    }

    private var statusStrip: some View {
        HStack(spacing: 10) {
            StatusPill(
                text: radio.state.label,
                color: radio.state == .ready ? RadioPalette.accent : RadioPalette.warning,
                icon: "network"
            )
            StatusPill(
                text: audio.listeningState.label,
                color: audio.listeningState == .streaming ? RadioPalette.cyan : RadioPalette.muted,
                icon: "speaker.wave.2.fill"
            )
            Spacer()
            operatorMenu
        }
    }

    private var operatorMenu: some View {
        Menu {
            ForEach(session.operators) { item in
                Button {
                    session.selectOperator(item.id)
                } label: {
                    if item.id == session.selectedOperatorId {
                        Label(item.myCallsign, systemImage: "checkmark")
                    } else {
                        Text(item.myCallsign)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(session.selectedOperator?.myCallsign ?? "选择操作员")
                    .font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.down")
                    .font(.caption2.bold())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RadioPalette.panelRaised, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var frequencyPanel: some View {
        RadioPanel {
            VStack(spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    TextField("14.074000", text: $frequencyMHz)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .font(.system(size: 45, weight: .medium, design: .rounded))
                        .minimumScaleFactor(0.62)
                        .foregroundStyle(radio.ptt.isTransmitting ? RadioPalette.transmit : RadioPalette.accent)
                    Text("MHz")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(RadioPalette.muted)
                }

                HStack(spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            ForEach(session.availableModes.isEmpty ? fallbackModes : session.availableModes) { mode in
                                ModeChip(mode: mode, selected: mode.name == radio.currentMode.name) {
                                    Task { await session.switchMode(mode) }
                                }
                            }
                        }
                    }
                    Button("设定") {
                        Task { await session.setFrequency(mhzText: frequencyMHz, radioMode: effectiveRadioMode) }
                    }
                    .buttonStyle(RadioActionButtonStyle(tint: RadioPalette.accent, prominent: true))
                }

                if radio.currentMode.name == "VOICE" {
                    Picker("调制", selection: $voiceRadioMode) {
                        ForEach(["USB", "LSB", "FM", "AM"], id: \.self) { Text($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
    }

    private var meterGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            MeterCard(
                title: "信号",
                value: radio.meters?.level?.formatted ?? "—",
                progress: (radio.meters?.level?.percent ?? 0) / 100,
                tint: RadioPalette.cyan
            )
            MeterCard(
                title: "功率",
                value: radio.meters?.power?.watts.map { String(format: "%.1f W", $0) } ?? "—",
                progress: (radio.meters?.power?.percent ?? 0) / 100,
                tint: RadioPalette.transmit
            )
            MeterCard(
                title: "SWR",
                value: radio.meters?.swr.map { String(format: "%.2f", $0.swr) } ?? "—",
                progress: min(1, max(0, ((radio.meters?.swr?.swr ?? 1) - 1) / 3)),
                tint: radio.meters?.swr?.alert == true ? RadioPalette.transmit : RadioPalette.warning
            )
            MeterCard(
                title: "ALC",
                value: radio.meters?.alc.map { String(format: "%.0f%%", $0.percent) } ?? "—",
                progress: (radio.meters?.alc?.percent ?? 0) / 100,
                tint: RadioPalette.accent
            )
        }
    }

    private var primaryControls: some View {
        RadioPanel {
            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    Button {
                        Task { await session.toggleListening() }
                    } label: {
                        Label(
                            audio.listeningState == .streaming ? "停止收听" : "开始收听",
                            systemImage: audio.listeningState == .streaming ? "speaker.slash.fill" : "speaker.wave.2.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(RadioActionButtonStyle(tint: RadioPalette.cyan))

                    Toggle("天调", isOn: $tunerEnabled)
                        .toggleStyle(.button)
                        .tint(RadioPalette.warning)
                        .onChange(of: tunerEnabled) { _, enabled in
                            Task { await session.setTuner(enabled: enabled) }
                        }

                    Button("调谐") { Task { await session.startTuning() } }
                        .buttonStyle(RadioActionButtonStyle(tint: RadioPalette.warning))
                }

                HoldPTTButton()

                if radio.ptt.isTransmitting {
                    Button(role: .destructive) {
                        session.forceStopTransmission()
                    } label: {
                        Label("紧急停止发射", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(RadioActionButtonStyle(tint: RadioPalette.transmit))
                }
            }
        }
    }

    private var effectiveRadioMode: String? {
        radio.currentMode.name == "VOICE" ? voiceRadioMode : nil
    }

    private var surfaceCapabilities: [CapabilityDescriptor] {
        radio.capabilityDescriptors.filter {
            $0.hasSurfaceControl && $0.writable && radio.capabilities[$0.id]?.supported == true
        }
    }

    private var fallbackModes: [ModeDescriptor] { [.ft8, .ft4, .voice, .cw] }

    private func syncFrequency() {
        guard let hz = radio.frequency?.frequency else { return }
        frequencyMHz = String(format: "%.6f", hz / 1_000_000)
    }
}

struct HoldPTTButton: View {
    @EnvironmentObject private var session: TX5DRSession
    @EnvironmentObject private var radio: RadioWebSocket
    @EnvironmentObject private var audio: TX5DRAudioClient
    @State private var touching = false

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(active ? RadioPalette.transmit : RadioPalette.panelRaised)
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(active ? Color.white.opacity(0.35) : RadioPalette.accent.opacity(0.3), lineWidth: 1)
                HStack(spacing: 12) {
                    Image(systemName: active ? "waveform.circle.fill" : "mic.fill")
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(active ? "正在发射" : "按住 PTT")
                            .font(.headline)
                        Text(audio.transmitState.label)
                            .font(.caption)
                            .opacity(0.72)
                    }
                    Spacer()
                    if active {
                        LevelBars(level: audio.microphoneLevel)
                            .frame(width: 52, height: 28)
                    }
                }
                .padding(.horizontal, 20)
            }
            .frame(height: 76)
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .scaleEffect(touching ? 0.985 : 1)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !touching else { return }
                        touching = true
                        session.beginVoicePTT()
                    }
                    .onEnded { _ in
                        touching = false
                        session.endVoicePTT()
                    }
            )
            .accessibilityLabel("按住语音 PTT")
            .accessibilityAddTraits(.isButton)
            .onDisappear {
                touching = false
                session.endVoicePTT()
            }
        }
    }

    private var active: Bool { session.isVoicePTTHeld || radio.ptt.isTransmitting }
}

private struct LevelBars: View {
    let level: Double

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<7, id: \.self) { index in
                Capsule()
                    .fill(Double(index) / 7 < level ? Color.white : Color.white.opacity(0.25))
                    .frame(width: 4, height: CGFloat(8 + index * 3))
            }
        }
    }
}

private struct ModeChip: View {
    let mode: ModeDescriptor
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(mode.name, action: action)
            .font(.caption.weight(.bold))
            .foregroundStyle(selected ? Color.black : Color.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(selected ? RadioPalette.accent : RadioPalette.panelRaised, in: Capsule())
            .buttonStyle(.plain)
    }
}

private struct MeterCard: View {
    let title: String
    let value: String
    let progress: Double
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(RadioPalette.muted)
                Spacer()
                Text(value)
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
            }
            ProgressView(value: min(1, max(0, progress)))
                .tint(tint)
        }
        .padding(13)
        .background(RadioPalette.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct StatusPill: View {
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
    }
}

struct CapabilityControlRow: View {
    @EnvironmentObject private var radio: RadioWebSocket
    let descriptor: CapabilityDescriptor
    let state: CapabilityState?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.subheadline.weight(.medium))
                Text(descriptor.id)
                    .font(.caption2.monospaced())
                    .foregroundStyle(RadioPalette.muted)
            }
            Spacer()
            control
                .frame(maxWidth: 210)
        }
        .opacity(state?.availability == "unavailable" ? 0.45 : 1)
    }

    @ViewBuilder
    private var control: some View {
        if descriptor.valueType == "boolean" || state?.value?.boolValue != nil {
            Toggle("", isOn: Binding(
                get: { state?.value?.boolValue ?? false },
                set: { radio.writeCapability(id: descriptor.id, value: .bool($0)) }
            ))
            .labelsHidden()
            .tint(RadioPalette.accent)
        } else if descriptor.valueType == "action" {
            Button("执行") { radio.writeCapability(id: descriptor.id, action: true) }
                .buttonStyle(RadioActionButtonStyle())
        } else if descriptor.valueType == "enum", let options = descriptor.options {
            Menu {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    Button(option.label ?? option.value.displayString) {
                        radio.writeCapability(id: descriptor.id, value: option.value)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(state?.value?.displayString ?? "选择")
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RadioPalette.panelRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        } else if let range = descriptor.range {
            HStack {
                Slider(value: Binding(
                    get: { state?.value?.doubleValue ?? range.min },
                    set: { radio.writeCapability(id: descriptor.id, value: .number($0)) }
                ), in: range.min...range.max)
                Text(String(format: "%.0f", state?.value?.doubleValue ?? range.min))
                    .font(.caption.monospacedDigit())
                    .frame(width: 38, alignment: .trailing)
            }
        } else {
            Text(state?.value?.displayString ?? "—")
                .font(.caption.monospaced())
                .foregroundStyle(RadioPalette.muted)
        }
    }

    private var label: String {
        descriptor.labelI18nKey.split(separator: ".").last.map(String.init) ?? descriptor.id
    }
}

private extension JSONValue {
    var displayString: String {
        switch self {
        case .string(let value): value
        case .number(let value): String(format: "%.2f", value)
        case .bool(let value): value ? "ON" : "OFF"
        case .null: "—"
        case .array(let value): "[\(value.count)]"
        case .object(let value): "{\(value.count)}"
        }
    }
}
