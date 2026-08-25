import AVFoundation
import Combine
import Foundation

enum RadioLiteAudioError: LocalizedError {
    case codecUnavailable(String)
    case playbackUnavailable(String)
    case microphonePermissionDenied
    case microphoneUnavailable

    var errorDescription: String? {
        switch self {
        case .codecUnavailable(let message): message
        case .playbackUnavailable(let message): "无法启动接收音频：\(message)"
        case .microphonePermissionDenied: "未获得麦克风权限"
        case .microphoneUnavailable: "当前设备没有可用的麦克风输入"
        }
    }
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

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var codec: RadioLiteOpusCodec?
    private var inputTapInstalled = false
    private var captureAccumulator: [Float] = []
    private var captureSampleRate: Double = 48_000
    private var packetHandler: ((Data) -> Void)?
    private var scheduledBuffers = 0
    private let targetBuffers = 3
    private let maximumBuffers = 25

    init() {
        engine.attach(player)
        do {
            let codec = try RadioLiteOpusCodec()
            self.codec = codec
            engine.connect(player, to: engine.mainMixerNode, format: codec.pcmFormat)
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
            try configureAudioSession(capturing: isCapturingMicrophone)
            try ensureEngineStarted()
            isMonitoring = true
            lastError = nil
        } catch {
            isMonitoring = false
            player.stop()
            engine.stop()
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
        if !isCapturingMicrophone {
            engine.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func receiveOpusPacket(_ packet: Data) {
        guard isMonitoring, scheduledBuffers < maximumBuffers, let codec else { return }
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
            if !engine.isRunning { try ensureEngineStarted() }
            if !player.isPlaying, scheduledBuffers >= targetBuffers { player.play() }
        } catch {
            droppedPackets &+= 1
            lastError = error.localizedDescription
        }
    }

    func beginMicrophoneCapture(onPacket: @escaping (Data) -> Void) async throws {
        guard let codec else {
            throw RadioLiteAudioError.codecUnavailable(lastError ?? "系统 Opus 编码器不可用")
        }
        if isCapturingMicrophone {
            packetHandler = onPacket
            return
        }
        guard await requestMicrophonePermission() else {
            throw RadioLiteAudioError.microphonePermissionDenied
        }

        engine.stop()
        try configureAudioSession(capturing: true)
        let input = engine.inputNode
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
                self?.consumeMicrophone(samples, sampleRate: sampleRate)
            }
        }
        inputTapInstalled = true
        isCapturingMicrophone = true
        do {
            try ensureEngineStarted()
            if isMonitoring, !player.isPlaying { player.play() }
            codec.reset()
        } catch {
            input.removeTap(onBus: 0)
            inputTapInstalled = false
            isCapturingMicrophone = false
            packetHandler = nil
            throw error
        }
    }

    /// Synchronous by design: release the hardware microphone before any network await.
    func stopMicrophoneCapture() {
        if inputTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        isCapturingMicrophone = false
        packetHandler = nil
        captureAccumulator.removeAll(keepingCapacity: true)
        microphoneLevel = 0
        codec?.reset()

        engine.stop()
        if isMonitoring {
            do {
                try configureAudioSession(capturing: false)
                try ensureEngineStarted()
                if scheduledBuffers > 0 { player.play() }
            } catch {
                isMonitoring = false
                player.stop()
                engine.stop()
                lastError = RadioLiteAudioError.playbackUnavailable(Self.diagnostic(error)).localizedDescription
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        } else {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func stopAll() {
        isMonitoring = false
        stopMicrophoneCapture()
        player.stop()
        scheduledBuffers = 0
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func consumeMicrophone(_ samples: [Float], sampleRate: Double) {
        guard isCapturingMicrophone, !samples.isEmpty else { return }
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
            microphoneLevel = min(1, rms * 4)
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

    private func configureAudioSession(capturing: Bool) throws {
        let session = AVAudioSession.sharedInstance()
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

    private func ensureEngineStarted() throws {
        guard !engine.isRunning else { return }
        engine.prepare()
        try engine.start()
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
    }

    private static func diagnostic(_ error: Error) -> String {
        let value = error as NSError
        if value.domain == NSOSStatusErrorDomain {
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
