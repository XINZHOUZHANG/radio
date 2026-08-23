import SwiftUI

struct VoiceKeyerPanelView: View {
    @EnvironmentObject private var session: TX5DRSession
    @EnvironmentObject private var radio: RadioWebSocket
    @ObservedObject var audioController: VoiceKeyerAudioController

    var body: some View {
        RadioPanel {
            VStack(alignment: .leading, spacing: 12) {
                header
                if session.keyerCallsign == nil {
                    ContentUnavailableView(
                        "请选择操作员",
                        systemImage: "person.crop.circle.badge.questionmark",
                        description: Text("语音素材按操作员呼号分别保存。")
                    )
                    .frame(minHeight: 180)
                } else if let panel = session.voiceKeyerPanel {
                    ForEach(Array(panel.slots.prefix(panel.slotCount))) { slot in
                        VoiceKeyerSlotCard(
                            slot: slot,
                            activeSlotId: activeSlotId,
                            statusMode: statusMode,
                            audioController: audioController
                        )
                        .id("\(slot.id)-\(slot.label)-\(slot.repeatEnabled)-\(slot.repeatIntervalSec)-\(slot.hasAudio)")
                    }
                } else {
                    ProgressView("读取语音素材")
                        .frame(maxWidth: .infinity, minHeight: 120)
                }
            }
        }
        .onChange(of: audioController.pendingRecording?.id) { _, id in
            guard id != nil, let recording = audioController.takePendingRecording() else { return }
            Task { _ = await session.uploadVoiceKeyerAudio(slotId: recording.slotId, wavData: recording.data) }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Label("语音键控素材", systemImage: "waveform.badge.mic")
                    .font(.headline)
                Text(session.keyerCallsign ?? "未选择呼号")
                    .font(.caption.monospaced())
                    .foregroundStyle(RadioPalette.muted)
            }
            Spacer()
            if let panel = session.voiceKeyerPanel {
                Button {
                    Task { await session.updateVoiceKeyerSlotCount(panel.slotCount - 1) }
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(RadioActionButtonStyle(tint: RadioPalette.muted))
                .disabled(panel.slotCount <= 3 || session.isWorking)

                Text("\(panel.slotCount)")
                    .font(.caption.monospacedDigit().weight(.bold))

                Button {
                    Task { await session.updateVoiceKeyerSlotCount(panel.slotCount + 1) }
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(RadioActionButtonStyle(tint: RadioPalette.accent))
                .disabled(panel.slotCount >= min(12, panel.maxSlotCount) || session.isWorking)
            }
            Button {
                Task { await session.loadKeyerPanels() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(RadioActionButtonStyle(tint: RadioPalette.cyan))
            .disabled(session.isWorking)
        }
    }

    private var activeSlotId: String? { radio.voiceKeyerStatus?["slotId"]?.stringValue }
    private var statusMode: String { radio.voiceKeyerStatus?["mode"]?.stringValue ?? "idle" }
}

private struct VoiceKeyerSlotCard: View {
    @EnvironmentObject private var session: TX5DRSession
    @EnvironmentObject private var radio: RadioWebSocket
    @EnvironmentObject private var realtimeAudio: TX5DRAudioClient

    let slot: VoiceKeyerSlot
    let activeSlotId: String?
    let statusMode: String
    @ObservedObject var audioController: VoiceKeyerAudioController

    @State private var label: String
    @State private var repeatEnabled: Bool
    @State private var repeatIntervalSec: Int
    @State private var confirmingDelete = false
    @State private var previewLoading = false

    init(
        slot: VoiceKeyerSlot,
        activeSlotId: String?,
        statusMode: String,
        audioController: VoiceKeyerAudioController
    ) {
        self.slot = slot
        self.activeSlotId = activeSlotId
        self.statusMode = statusMode
        self.audioController = audioController
        _label = State(initialValue: slot.label)
        _repeatEnabled = State(initialValue: slot.repeatEnabled)
        _repeatIntervalSec = State(initialValue: slot.repeatIntervalSec)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("V\(slot.index)")
                    .font(.caption.monospaced().weight(.bold))
                    .foregroundStyle(isActive ? RadioPalette.transmit : RadioPalette.accent)
                TextField("槽位名称", text: $label)
                    .textFieldStyle(.plain)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(slot.hasAudio ? durationText(slot.durationMs) : "未录音")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(RadioPalette.muted)
            }

            HStack(spacing: 8) {
                Button(isActive ? "停止发射" : "发射") {
                    if isActive { radio.stopVoiceKeyer() }
                    else { session.playVoiceKeyerSlot(slot) }
                }
                .buttonStyle(RadioActionButtonStyle(tint: isActive ? RadioPalette.transmit : RadioPalette.accent, prominent: isActive))
                .disabled(!slot.hasAudio || (activeSlotId != nil && !isActive))

                Button(audioController.previewSlotId == slot.id ? "停止试听" : "试听") {
                    preview()
                }
                .buttonStyle(RadioActionButtonStyle(tint: RadioPalette.cyan))
                .disabled(!slot.hasAudio || previewLoading || isActive)

                Button(isRecordingThisSlot ? "完成录音" : "录音") {
                    toggleRecording()
                }
                .buttonStyle(RadioActionButtonStyle(tint: RadioPalette.warning, prominent: isRecordingThisSlot))
                .disabled((audioController.isRecording && !isRecordingThisSlot) || isActive || session.isWorking)

                if isRecordingThisSlot {
                    Button("取消", role: .cancel) { audioController.cancelRecording() }
                        .buttonStyle(RadioActionButtonStyle(tint: RadioPalette.muted))
                }
            }

            if isRecordingThisSlot {
                HStack(spacing: 8) {
                    ProgressView(value: audioController.recordingLevel)
                        .tint(RadioPalette.warning)
                    Text(elapsedText(audioController.recordingElapsedMs))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(RadioPalette.warning)
                }
            }

            HStack(spacing: 10) {
                Toggle("循环", isOn: $repeatEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                Text("循环")
                    .font(.caption)
                Stepper("\(repeatIntervalSec) 秒", value: $repeatIntervalSec, in: 1...300)
                    .font(.caption.monospacedDigit())
                Spacer()
                Button("保存") { saveMetadata() }
                    .buttonStyle(RadioActionButtonStyle(tint: RadioPalette.accent))
                    .disabled(!hasMetadataChanges || session.isWorking)
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(RadioActionButtonStyle(tint: RadioPalette.transmit))
                .disabled(!slot.hasAudio || isActive)
            }
        }
        .padding(12)
        .background(
            isActive ? RadioPalette.transmit.opacity(0.10) : RadioPalette.panelRaised,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isActive ? RadioPalette.transmit.opacity(0.5) : Color.white.opacity(0.06))
        }
        .confirmationDialog("删除 V\(slot.index) 的语音录音？", isPresented: $confirmingDelete) {
            Button("删除录音", role: .destructive) {
                Task { await session.deleteVoiceKeyerAudio(slotId: slot.id) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("标签和循环设置会保留，仅删除服务器上的 WAV 素材。")
        }
    }

    private var isActive: Bool { activeSlotId == slot.id && statusMode != "idle" }
    private var isRecordingThisSlot: Bool { audioController.recordingSlotId == slot.id }
    private var hasMetadataChanges: Bool {
        label != slot.label || repeatEnabled != slot.repeatEnabled || repeatIntervalSec != slot.repeatIntervalSec
    }

    private func saveMetadata() {
        let cleanLabel = String(label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
        Task {
            await session.updateVoiceKeyerSlot(
                slot.id,
                update: VoiceKeyerSlotUpdate(
                    label: cleanLabel,
                    repeatEnabled: repeatEnabled,
                    repeatIntervalSec: repeatIntervalSec
                )
            )
        }
    }

    private func toggleRecording() {
        Task {
            do {
                if isRecordingThisSlot {
                    let recording = try audioController.finishRecording()
                    _ = await session.uploadVoiceKeyerAudio(slotId: recording.slotId, wavData: recording.data)
                } else {
                    realtimeAudio.stopAll()
                    try await audioController.startRecording(slotId: slot.id)
                }
            } catch {
                session.errorMessage = error.localizedDescription
            }
        }
    }

    private func preview() {
        if audioController.previewSlotId == slot.id {
            audioController.stopPreview()
            return
        }
        previewLoading = true
        Task {
            defer { previewLoading = false }
            do {
                let data = try await session.downloadVoiceKeyerAudio(slotId: slot.id)
                try audioController.playPreview(data: data, slotId: slot.id)
            } catch {
                session.errorMessage = error.localizedDescription
            }
        }
    }

    private func durationText(_ milliseconds: Int) -> String {
        let seconds = Int((Double(milliseconds) / 1_000).rounded())
        return seconds >= 60 ? "\(seconds / 60):\(String(format: "%02d", seconds % 60))" : "\(seconds) 秒"
    }

    private func elapsedText(_ milliseconds: Int) -> String {
        let seconds = milliseconds / 1_000
        let centiseconds = (milliseconds % 1_000) / 10
        return String(format: "%d:%02d.%02d", seconds / 60, seconds % 60, centiseconds)
    }
}
