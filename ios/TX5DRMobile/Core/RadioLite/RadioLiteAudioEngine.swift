import AVFoundation
import Combine
import Foundation

enum RadioLiteAudioError: LocalizedError {
    case codecUnavailable(String)
    case playbackUnavailable(String)
    case microphonePermissionDenied
    case microphoneUnavailable
    case microphoneStartFailed(String)

    var errorDescription: String? {
        switch self {
        case .codecUnavailable(let message): message
        case .playbackUnavailable(let message): "无法启动接收音频：\(message)"
        case .microphonePermissionDenied: "未获得麦克风权限"
        case .microphoneUnavailable: "当前设备没有可用的麦克风输入"
        case .microphoneStartFailed(let message): "无法启动麦克风：\(message)"
        }
    }
}

struct RadioLiteMicrophoneCaptureOwnership: Equatable, Sendable {
    let epoch: UInt64
}

enum RadioLiteCaptureStopResult: Equatable, Sendable {
    case notOwner
    case invalidatedPending
    case stoppedActive
}

struct RadioLiteCaptureEpochState: Equatable, Sendable {
    private var epoch = RadioLiteOperationEpoch()
    private var current: RadioLiteMicrophoneCaptureOwnership?
    private var active = false

    mutating func begin() -> RadioLiteMicrophoneCaptureOwnership {
        let ownership = RadioLiteMicrophoneCaptureOwnership(epoch: epoch.begin())
        current = ownership
        active = false
        return ownership
    }

    mutating func activate(_ ownership: RadioLiteMicrophoneCaptureOwnership) -> Bool {
        guard current == ownership, epoch.owns(ownership.epoch) else { return false }
        active = true
        return true
    }

    mutating func stop(epoch expectedEpoch: UInt64? = nil) -> RadioLiteCaptureStopResult {
        if let expectedEpoch, current?.epoch != expectedEpoch { return .notOwner }
        let result: RadioLiteCaptureStopResult
        if current == nil {
            result = .notOwner
        } else {
            result = active ? .stoppedActive : .invalidatedPending
        }
        epoch.invalidate()
        current = nil
        active = false
        return result
    }

    func isCurrent(_ ownership: RadioLiteMicrophoneCaptureOwnership) -> Bool {
        current == ownership && epoch.owns(ownership.epoch)
    }

    func isActive(_ ownership: RadioLiteMicrophoneCaptureOwnership) -> Bool {
        active && isCurrent(ownership)
    }

    var currentOwnership: RadioLiteMicrophoneCaptureOwnership? { current }
}

@MainActor
final class RadioLiteAudioEngine: ObservableObject {
    @Published private(set) var isMonitoring = false
    @Published private(set) var isCapturingMicrophone = false
    @Published private(set) var microphoneLevel: Double = 0
    @Published private(set) var receivedPackets: UInt64 = 0
    @Published private(set) var sentPackets: UInt64 = 0
    @Published private(set) var droppedPackets: UInt64 = 0
    @Published private(set) var lastError: String?
    @Published var monitorVolume: Double = 0.8 {
        didSet { player.volume = Float(min(1, max(0, monitorVolume))) }
    }

    // Keep playback and recording on separate graphs. Once an AVAudioEngine's
    // input node has been activated, restarting that same graph under a
    // playback-only AVAudioSession can fail with OSStatus '!rec'. Separate
    // graphs also let PTT release the microphone without tearing down the
    // optional receive-audio player.
    private let playbackEngine = AVAudioEngine()
    private let captureEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var codec: RadioLiteOpusCodec?
    private var inputTapInstalled = false
    private var captureAccumulator: [Float] = []
    private var captureSampleRate: Double = 48_000
    private var packetHandler: ((Data) -> Void)?
    private var captureEpochState = RadioLiteCaptureEpochState()
    private var microphoneTelemetryLimiter = AudioTelemetryLimiter(minimumInterval: 0.1)
    private var scheduledBuffers = 0
    private let targetBuffers = 3
    private let maximumBuffers = 25

    init() {
        playbackEngine.attach(player)
        do {
            let codec = try RadioLiteOpusCodec()
            self.codec = codec
            playbackEngine.connect(player, to: playbackEngine.mainMixerNode, format: codec.pcmFormat)
        } catch {
            lastError = error.localizedDescription
        }
        player.volume = Float(monitorVolume)
    }

    func setOpusBitrate(_ bitrate: Int) {
        do {
            try codec?.setBitrate(bitrate)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func startMonitoring() throws {
        guard codec != nil else {
            throw RadioLiteAudioError.codecUnavailable(lastError ?? "系统 Opus 编解码器不可用")
        }
        do {
            guard !isCapturingMicrophone else {
                isMonitoring = true
                lastError = nil
                return
            }
            try activateAudioSession(capturing: false)
            try ensurePlaybackEngineStarted()
            isMonitoring = true
            lastError = nil
        } catch {
            isMonitoring = false
            player.stop()
            playbackEngine.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            let wrapped = RadioLiteAudioError.playbackUnavailable(Self.diagnostic(error))
            lastError = wrapped.localizedDescription
            throw wrapped
        }
    }

    func stopMonitoring() {
        isMonitoring = false
        player.stop()
        scheduledBuffers = 0
        playbackEngine.stop()
        if !isCapturingMicrophone {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func receiveOpusPacket(_ packet: Data) {
        guard isMonitoring, !isCapturingMicrophone,
              scheduledBuffers < maximumBuffers, let codec else { return }
        do {
            let samples = try codec.decode(packet)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: codec.pcmFormat,
                frameCapacity: AVAudioFrameCount(samples.count)
            ), let channel = buffer.floatChannelData?[0] else {
                throw RadioLiteAudioError.codecUnavailable("无法分配播放缓冲区")
            }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { pointer in
                channel.update(from: pointer.baseAddress!, count: samples.count)
            }
            scheduledBuffers += 1
            receivedPackets &+= 1
            player.scheduleBuffer(buffer) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.scheduledBuffers = max(0, (self?.scheduledBuffers ?? 1) - 1)
                }
            }
            if !playbackEngine.isRunning { try ensurePlaybackEngineStarted() }
            if !player.isPlaying, scheduledBuffers >= targetBuffers { player.play() }
        } catch {
            droppedPackets &+= 1
            lastError = error.localizedDescription
        }
    }

    func beginMicrophoneCapture(
        onPacket: @escaping (Data) -> Void
    ) async throws -> RadioLiteMicrophoneCaptureOwnership {
        guard let codec else {
            throw RadioLiteAudioError.codecUnavailable(lastError ?? "系统 Opus 编码器不可用")
        }
        if isCapturingMicrophone, let ownership = captureEpochState.currentOwnership {
            packetHandler = onPacket
            return ownership
        }
        let ownership = captureEpochState.begin()
        guard await requestMicrophonePermission() else {
            _ = captureEpochState.stop(epoch: ownership.epoch)
            throw RadioLiteAudioError.microphonePermissionDenied
        }
        do {
            try Task.checkCancellation()
        } catch {
            _ = captureEpochState.stop(epoch: ownership.epoch)
            throw error
        }
        guard captureEpochState.isCurrent(ownership), captureEpochState.activate(ownership) else {
            throw CancellationError()
        }

        suspendPlaybackForCapture()
        do {
            try activateAudioSession(capturing: true)
            let input = captureEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.channelCount > 0, format.sampleRate > 0 else {
                throw RadioLiteAudioError.microphoneUnavailable
            }
            captureAccumulator.removeAll(keepingCapacity: true)
            captureSampleRate = format.sampleRate
            packetHandler = onPacket
            let frames = AVAudioFrameCount(max(128, Int(format.sampleRate * 0.02)))
            input.installTap(onBus: 0, bufferSize: frames, format: format) { [weak self] buffer, _ in
                let samples = Self.copyMonoSamples(buffer)
                let sampleRate = buffer.format.sampleRate
                Task { @MainActor [weak self] in
                    self?.consumeMicrophone(
                        samples,
                        sampleRate: sampleRate,
                        ownership: ownership
                    )
                }
            }
            inputTapInstalled = true
            isCapturingMicrophone = true
            try ensureCaptureEngineStarted()
            codec.reset()
            return ownership
        } catch {
            _ = stopMicrophoneCapture(epoch: ownership.epoch)
            let wrapped = error as? RadioLiteAudioError
                ?? RadioLiteAudioError.microphoneStartFailed(Self.diagnostic(error))
            lastError = wrapped.localizedDescription
            throw wrapped
        }
    }

    /// Synchronous by design: release the hardware microphone before any network await.
    @discardableResult
    func stopMicrophoneCapture(epoch: UInt64? = nil) -> Bool {
        let result = captureEpochState.stop(epoch: epoch)
        guard result == .stoppedActive else { return false }
        cleanupCaptureGraph()

        if isMonitoring {
            resumePlaybackAfterCaptureIfNeeded()
        } else {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        return true
    }

    func stopAll() {
        isMonitoring = false
        let stoppedCapture = stopMicrophoneCapture()
        player.stop()
        scheduledBuffers = 0
        playbackEngine.stop()
        captureEngine.stop()
        if !stoppedCapture {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func consumeMicrophone(
        _ samples: [Float],
        sampleRate: Double,
        ownership: RadioLiteMicrophoneCaptureOwnership
    ) {
        guard captureEpochState.isActive(ownership),
              isCapturingMicrophone,
              !samples.isEmpty else { return }
        if abs(sampleRate - captureSampleRate) > 0.5 {
            captureAccumulator.removeAll(keepingCapacity: true)
            captureSampleRate = sampleRate
        }
        captureAccumulator.append(contentsOf: samples)
        let sourceFrameCount = max(1, Int((captureSampleRate * 0.02).rounded()))
        while captureAccumulator.count >= sourceFrameCount {
            let source = Array(captureAccumulator.prefix(sourceFrameCount))
            captureAccumulator.removeFirst(sourceFrameCount)
            let resampled = Self.resample(source, count: RadioLiteOpusCodec.samplesPerFrame)
            let rms = sqrt(resampled.reduce(0) { $0 + Double($1 * $1) } / Double(resampled.count))
            if microphoneTelemetryLimiter.shouldPublish(at: ProcessInfo.processInfo.systemUptime) {
                microphoneLevel = min(1, rms * 4)
            }
            do {
                guard let packet = try codec?.encode(resampled) else { throw RadioLiteOpusError.emptyPacket }
                sentPackets &+= 1
                packetHandler?(packet)
            } catch {
                droppedPackets &+= 1
                lastError = error.localizedDescription
            }
        }
    }

    private func activateAudioSession(capturing: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        // Both audio graphs are stopped before changing category. Deactivating
        // first prevents iOS from retaining an incompatible input/output graph.
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        if capturing {
            do {
                try session.setCategory(
                    .playAndRecord,
                    mode: .voiceChat,
                    options: [.defaultToSpeaker, .allowBluetooth]
                )
            } catch {
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker])
            }
        } else {
            do {
                try session.setCategory(.playback, mode: .default, options: [.allowBluetoothA2DP])
            } catch {
                try session.setCategory(.playback, mode: .default)
            }
        }
        // These are preferences, not correctness requirements. Some routes
        // reject one of them with OSStatus even though playback itself works.
        try? session.setPreferredSampleRate(48_000)
        try? session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)
    }

    private func ensurePlaybackEngineStarted() throws {
        guard !playbackEngine.isRunning else { return }
        playbackEngine.prepare()
        try playbackEngine.start()
    }

    private func ensureCaptureEngineStarted() throws {
        guard !captureEngine.isRunning else { return }
        captureEngine.prepare()
        try captureEngine.start()
    }

    private func suspendPlaybackForCapture() {
        player.stop()
        playbackEngine.stop()
        scheduledBuffers = 0
    }

    private func cleanupCaptureGraph() {
        if inputTapInstalled {
            captureEngine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        captureEngine.stop()
        captureEngine.reset()
        isCapturingMicrophone = false
        packetHandler = nil
        captureAccumulator.removeAll(keepingCapacity: true)
        microphoneTelemetryLimiter.reset()
        microphoneLevel = 0
        codec?.reset()
    }

    private func resumePlaybackAfterCaptureIfNeeded() {
        guard isMonitoring else {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            return
        }
        do {
            try activateAudioSession(capturing: false)
            try ensurePlaybackEngineStarted()
            lastError = nil
        } catch {
            isMonitoring = false
            player.stop()
            playbackEngine.stop()
            lastError = RadioLiteAudioError.playbackUnavailable(Self.diagnostic(error)).localizedDescription
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
    }

    nonisolated static func diagnostic(_ error: Error) -> String {
        let value = error as NSError
        if value.domain == NSOSStatusErrorDomain {
            if value.code == 561_145_187 {
                return "iOS 无法启动录音通道（!rec）；请确认麦克风权限，关闭占用麦克风的其他应用后重试"
            }
            return "系统音频错误 OSStatus \(value.code)"
        }
        return "\(value.localizedDescription)（\(value.domain) \(value.code)）"
    }

    nonisolated private static func copyMonoSamples(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channels = buffer.floatChannelData else { return [] }
        let frames = Int(buffer.frameLength)
        let channelCount = max(1, Int(buffer.format.channelCount))
        var output = [Float](repeating: 0, count: frames)
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channelCount { sum += channels[channel][frame] }
            output[frame] = sum / Float(channelCount)
        }
        return output
    }

    nonisolated private static func resample(_ source: [Float], count: Int) -> [Float] {
        guard !source.isEmpty, count > 0 else { return [] }
        guard source.count > 1, count > 1 else { return [Float](repeating: source[0], count: count) }
        let scale = Double(source.count - 1) / Double(count - 1)
        return (0..<count).map { index in
            let position = Double(index) * scale
            let left = Int(position)
            let right = min(source.count - 1, left + 1)
            let fraction = Float(position - Double(left))
            return source[left] + (source[right] - source[left]) * fraction
        }
    }
}
