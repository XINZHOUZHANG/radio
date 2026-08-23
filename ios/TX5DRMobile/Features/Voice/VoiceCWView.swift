import SwiftUI

private enum VoiceCWPage: String, CaseIterable, Identifiable {
    case voice = "语音"
    case cw = "CW"
    var id: String { rawValue }
}

struct VoiceCWView: View {
    @EnvironmentObject private var session: TX5DRSession
    @EnvironmentObject private var radio: RadioWebSocket
    @EnvironmentObject private var audio: TX5DRAudioClient
    @State private var page: VoiceCWPage = .voice

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Picker("模式", selection: $page) {
                    ForEach(VoiceCWPage.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if page == .voice { voicePanel }
                else { CWPanel() }
            }
            .padding(14)
        }
        .background(RadioPalette.background.ignoresSafeArea())
        .navigationTitle("语音 / CW")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            session.endVoicePTT()
            radio.stopTuneTone()
            session.setCWKey(down: false)
        }
    }

    private var voicePanel: some View {
        VStack(spacing: 14) {
            RadioPanel {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label("实时音频", systemImage: "waveform")
                            .font(.headline)
                        Spacer()
                        Text(audio.listeningState.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(audio.listeningState == .streaming ? RadioPalette.accent : RadioPalette.muted)
                    }

                    HStack {
                        Button(audio.listeningState == .streaming ? "停止收听" : "开始收听") {
                            Task { await session.toggleListening() }
                        }
                        .buttonStyle(RadioActionButtonStyle(tint: RadioPalette.cyan))
                        Spacer()
                        Text("RX \(audio.receivedFrames) 帧")
                        Text("TX \(audio.sentFrames) 帧")
                        if audio.droppedUplinkFrames > 0 {
                            Text("丢弃 \(audio.droppedUplinkFrames)")
                                .foregroundStyle(RadioPalette.warning)
                        }
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(RadioPalette.muted)
                }
            }

            RadioPanel {
                VStack(spacing: 14) {
                    Text("电台调制模式")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(RadioPalette.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 8) {
                        ForEach(["USB", "LSB", "FM", "AM"], id: \.self) { mode in
                            Button(mode) { radio.setVoiceRadioMode(mode) }
                                .buttonStyle(RadioActionButtonStyle(tint: RadioPalette.accent))
                        }
                    }
                    HoldPTTButton()
                    HoldTuneToneButton()
                }
            }

            if let lock = radio.voiceLock {
                RadioPanel {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("PTT 锁状态").font(.headline)
                        Text(lock.prettyPrinted)
                            .font(.caption.monospaced())
                            .foregroundStyle(RadioPalette.muted)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
private struct HoldTuneToneButton: View {
    @EnvironmentObject private var session: TX5DRSession
    @EnvironmentObject private var radio: RadioWebSocket
    @State private var held = false

    var body: some View {
        Label(held || radio.tuneTone.active ? "正在发送 1 kHz 调谐音" : "按住发送调谐音", systemImage: "tuningfork")
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(RadioPalette.warning.opacity(held ? 0.75 : 0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(RadioPalette.warning.opacity(0.32))
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !held else { return }
                        held = true
                        radio.startTuneTone(operatorId: session.selectedOperatorId)
                    }
                    .onEnded { _ in
                        held = false
                        radio.stopTuneTone()
                    }
            )
            .onDisappear { radio.stopTuneTone() }
    }
}

private struct CWPanel: View {
    @EnvironmentObject private var session: TX5DRSession
    @EnvironmentObject private var radio: RadioWebSocket
    @State private var text = "CQ CQ DE "
    @State private var callsign = ""
    @State private var keyHeld = false

    var body: some View {
        VStack(spacing: 14) {
            RadioPanel {
                VStack(alignment: .leading, spacing: 12) {
                    Label("文字键控", systemImage: "text.cursor")
                        .font(.headline)
                    TextField("目标呼号（可选）", text: $callsign)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .padding(12)
                        .background(RadioPalette.panelRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    TextEditor(text: $text)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 110)
                        .padding(8)
                        .background(RadioPalette.panelRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Button {
                        session.sendCW(text, callsign: callsign.isEmpty ? nil : callsign.uppercased())
                    } label: {
                        Label("发送 CW", systemImage: "paperplane.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(RadioActionButtonStyle(tint: RadioPalette.accent, prominent: true))
                }
            }

            RadioPanel {
                VStack(spacing: 10) {
                    Text("手键")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(RadioPalette.muted)
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(keyHeld ? RadioPalette.transmit : RadioPalette.panelRaised)
                        .frame(height: 90)
                        .overlay {
                            Label(keyHeld ? "KEY DOWN" : "按住键控", systemImage: "hand.tap.fill")
                                .font(.headline)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { _ in
                                    guard !keyHeld else { return }
                                    keyHeld = true
                                    session.setCWKey(down: true)
                                }
                                .onEnded { _ in
                                    keyHeld = false
                                    session.setCWKey(down: false)
                                }
                        )
                }
            }

            RadioPanel {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("CW 状态").font(.headline)
                        Spacer()
                        Button("停止") { radio.stopCWMessage() }
                            .buttonStyle(RadioActionButtonStyle(tint: RadioPalette.warning))
                    }
                    Text(radio.cwStatus?.prettyPrinted ?? "等待服务端状态")
                        .font(.caption.monospaced())
                        .foregroundStyle(RadioPalette.muted)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
