import SwiftUI

struct RadioShellView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var session: TX5DRSession
    @EnvironmentObject private var radio: RadioWebSocket
    @EnvironmentObject private var audio: TX5DRAudioClient

    var body: some View {
        TabView {
            NavigationStack { RadioControlView() }
                .tabItem { Label("电台", systemImage: "dot.radiowaves.left.and.right") }

            NavigationStack { FT8View() }
                .tabItem { Label("FT8", systemImage: "waveform.path.ecg.rectangle") }

            NavigationStack { VoiceCWView() }
                .tabItem { Label("语音 / CW", systemImage: "mic.and.signal.meter") }

            NavigationStack { LogbookView() }
                .tabItem { Label("日志", systemImage: "book.closed") }

            NavigationStack { SettingsView() }
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
        .tint(RadioPalette.accent)
        .background(RadioPalette.background)
        .onAppear { applyAudioMonitorGate(audioMonitorGate) }
        .onChange(of: audioMonitorGate) { _, gate in
            applyAudioMonitorGate(gate)
        }
        .onChange(of: radio.transmissionInterruption) { _, interruption in
            guard let interruption else { return }
            session.endVoicePTT()
            session.noticeMessage = "发射期间电台断开：\(interruption.message) \(interruption.recommendation)"
            radio.clearTransmissionInterruption()
        }
        .onChange(of: radio.state) { _, state in
            if case .failed(let message) = state {
                session.endVoicePTT()
                session.noticeMessage = "控制通道：\(message)"
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            session.endVoicePTT()
            audio.stopMicrophoneCapture()
        }
    }

    private var audioMonitorGate: AudioMonitorGateState {
        AudioMonitorGateState(
            engineMode: radio.currentMode.name,
            ptt: radio.ptt,
            localVoicePTTHeld: session.isVoicePTTHeld,
            squelch: radio.squelch,
            voiceLock: radio.voiceLock
        )
    }

    private func applyAudioMonitorGate(_ gate: AudioMonitorGateState) {
        audio.setMonitorMuted(gate.shouldMute)
    }
}
