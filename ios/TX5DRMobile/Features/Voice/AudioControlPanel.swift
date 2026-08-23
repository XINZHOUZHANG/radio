import SwiftUI

struct AudioControlPanel: View {
    @EnvironmentObject private var session: TX5DRSession
    @EnvironmentObject private var radio: RadioWebSocket
    @EnvironmentObject private var audio: TX5DRAudioClient

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("音频电平", systemImage: "slider.horizontal.3")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                squelchIndicator
            }

            gainControl(
                title: "监听音量",
                systemImage: "speaker.wave.2.fill",
                value: Binding(
                    get: { audio.monitorVolumeDecibels },
                    set: { audio.setMonitorVolume(decibels: $0) }
                ),
                disabled: false
            )

            gainControl(
                title: "发射增益",
                systemImage: "mic.fill",
                value: Binding(
                    get: { radio.transmitGainDecibels },
                    set: { radio.setVolumeGain(decibels: $0) }
                ),
                disabled: radio.state != .ready
            )

            if let reason = monitorGate.muteReason {
                Label(reason.label, systemImage: "speaker.slash.fill")
                    .font(.caption)
                    .foregroundStyle(RadioPalette.warning)
            }

            if let error = audio.lastError {
                Label("实时音频：\(error)", systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(RadioPalette.transmit)
            }
        }
    }

    private func gainControl(
        title: String,
        systemImage: String,
        value: Binding<Double>,
        disabled: Bool
    ) -> some View {
        VStack(spacing: 7) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.caption)
                    .foregroundStyle(RadioPalette.muted)
                Spacer()
                Text(formatDecibels(value.wrappedValue))
                    .font(.caption.monospacedDigit().weight(.semibold))
            }
            Slider(
                value: value,
                in: AudioGain.minimumDecibels...AudioGain.maximumDecibels,
                step: 0.5
            )
            .tint(title == "监听音量" ? RadioPalette.cyan : RadioPalette.accent)
            .disabled(disabled)
            .accessibilityLabel(title)
            .accessibilityValue(formatDecibels(value.wrappedValue))
        }
    }

    @ViewBuilder
    private var squelchIndicator: some View {
        if radio.squelch.supported {
            Label(squelchLabel, systemImage: squelchSystemImage)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(squelchColor)
        } else {
            Text("无静噪反馈")
                .font(.caption2)
                .foregroundStyle(RadioPalette.muted)
        }
    }

    private var monitorGate: AudioMonitorGateState {
        AudioMonitorGateState(
            engineMode: radio.currentMode.name,
            ptt: radio.ptt,
            localVoicePTTHeld: session.isVoicePTTHeld,
            squelch: radio.squelch,
            voiceLock: radio.voiceLock
        )
    }

    private var squelchLabel: String {
        switch radio.squelch.open {
        case true: "静噪门打开"
        case false: "静噪门关闭"
        case nil: "静噪状态未知"
        }
    }

    private var squelchSystemImage: String {
        radio.squelch.open == true ? "waveform" : "speaker.slash.fill"
    }

    private var squelchColor: Color {
        radio.squelch.open == true ? RadioPalette.accent : RadioPalette.muted
    }

    private func formatDecibels(_ value: Double) -> String {
        String(format: "%+.1f dB", value)
    }
}
