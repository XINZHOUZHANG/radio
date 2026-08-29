import AVFoundation
import Foundation

struct VoiceKeyerRecording: Identifiable, Sendable {
    let id = UUID()
    let slotId: String
    let data: Data
    let durationMs: Int
}

enum VoiceKeyerAudioError: LocalizedError {
    case microphonePermissionDenied
    case recorderUnavailable
    case recordingTooShort
    case playbackFailed

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied: "未获得麦克风录音权限"
        case .recorderUnavailable: "录音器当前不可用"
        case .recordingTooShort: "录音时间至少需要 0.5 秒"
        case .playbackFailed: "无法播放该语音素材"
        }
    }
}

@MainActor
final class VoiceKeyerAudioController: ObservableObject {
    @Published private(set) var recordingSlotId: String?
    @Published private(set) var recordingElapsedMs = 0
    @Published private(set) var recordingLevel: Double = 0
    @Published private(set) var pendingRecording: VoiceKeyerRecording?
    @Published private(set) var previewSlotId: String?

    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var recordingStartedAt: Date?
    private var meterTimer: Timer?
    private var player: AVAudioPlayer?
    private var previewTask: Task<Void, Never>?

    var isRecording: Bool { recordingSlotId != nil }

    func startRecording(slotId: String) async throws {
        cancelRecording()
        stopPreview()
        guard await requestMicrophonePermission() else {
            throw VoiceKeyerAudioError.microphonePermissionDenied
        }

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: [.defaultToSpeaker, .allowBluetooth]
        )
        try audioSession.setPreferredSampleRate(16_000)
        try audioSession.setActive(true)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tx5dr-keyer-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.prepareToRecord(), recorder.record() else {
            throw VoiceKeyerAudioError.recorderUnavailable
        }

        self.recorder = recorder
        recordingURL = url
        recordingStartedAt = Date()
        recordingSlotId = slotId
        recordingElapsedMs = 0
        recordingLevel = 0
        pendingRecording = nil
        meterTimer = .scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateMeter() }
        }
    }

    func finishRecording() throws -> VoiceKeyerRecording {
        let recording = try stopAndBuildRecording()
        pendingRecording = nil
        return recording
    }

    func takePendingRecording() -> VoiceKeyerRecording? {
        defer { pendingRecording = nil }
        return pendingRecording
    }

    func cancelRecording() {
        recorder?.stop()
        cleanupRecorder(removeFile: true)
    }

    func playPreview(data: Data, slotId: String) throws {
        if previewSlotId == slotId {
            stopPreview()
            return
        }
        stopPreview()
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playback, mode: .spokenAudio)
        try audioSession.setActive(true)
        let player = try AVAudioPlayer(data: data)
        guard player.prepareToPlay(), player.play() else { throw VoiceKeyerAudioError.playbackFailed }
        self.player = player
        previewSlotId = slotId
        let duration = max(0.1, player.duration)
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.stopPreview()
        }
    }

    func stopPreview() {
        previewTask?.cancel()
        previewTask = nil
        player?.stop()
        player = nil
        previewSlotId = nil
    }

    private func updateMeter() {
        guard let recorder, let startedAt = recordingStartedAt else { return }
        recorder.updateMeters()
        let decibels = recorder.averagePower(forChannel: 0)
        recordingLevel = min(1, max(0, Double(decibels + 50) / 50))
        recordingElapsedMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
        if recordingElapsedMs >= 120_000 {
            do { pendingRecording = try stopAndBuildRecording() }
            catch { cancelRecording() }
        }
    }

    private func stopAndBuildRecording() throws -> VoiceKeyerRecording {
        guard let recorder, let url = recordingURL, let slotId = recordingSlotId,
              let startedAt = recordingStartedAt else {
            throw VoiceKeyerAudioError.recorderUnavailable
        }
        recorder.stop()
        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        cleanupRecorder(removeFile: true)
        guard durationMs >= 500, data.count > 44 else { throw VoiceKeyerAudioError.recordingTooShort }
        return VoiceKeyerRecording(slotId: slotId, data: data, durationMs: durationMs)
    }

    private func cleanupRecorder(removeFile: Bool) {
        meterTimer?.invalidate()
        meterTimer = nil
        recorder = nil
        if removeFile, let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
        recordingURL = nil
        recordingStartedAt = nil
        recordingSlotId = nil
        recordingElapsedMs = 0
        recordingLevel = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
