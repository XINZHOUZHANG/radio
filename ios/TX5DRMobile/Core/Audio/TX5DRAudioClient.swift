import AVFoundation
import Combine
import Foundation

enum RealtimeAudioLinkState: Equatable {
    case stopped
    case connecting
    case ready
    case streaming
    case failed(String)

    var label: String {
        switch self {
        case .stopped: "未连接"
        case .connecting: "连接中"
        case .ready: "已就绪"
        case .streaming: "传输中"
        case .failed: "故障"
        }
    }
}

enum TX5DRAudioError: LocalizedError {
    case notConfigured
    case connectionTimeout
    case missingParticipantIdentity
    case microphonePermissionDenied
    case microphoneUnavailable
    case invalidAudioBuffer

    var errorDescription: String? {
        switch self {
        case .notConfigured: "实时音频尚未配置服务器"
        case .connectionTimeout: "实时音频连接超时"
        case .missingParticipantIdentity: "服务器没有返回 PTT 所需的音频身份"
        case .microphonePermissionDenied: "未获得麦克风权限"
        case .microphoneUnavailable: "当前设备没有可用的麦克风输入"
        case .invalidAudioBuffer: "收到无法播放的音频采样"
        }
    }
}

private struct RealtimeReadyMessage: Decodable {
    let type: String
    let participantIdentity: String?
}

@MainActor
final class TX5DRAudioClient: ObservableObject {
    @Published private(set) var listeningState: RealtimeAudioLinkState = .stopped
    @Published private(set) var transmitState: RealtimeAudioLinkState = .stopped
    @Published private(set) var participantIdentity: String?
    @Published private(set) var microphoneLevel: Double = 0
    @Published private(set) var receivedFrames: UInt64 = 0
    @Published private(set) var sentFrames: UInt64 = 0
    @Published private(set) var droppedUplinkFrames: UInt64 = 0
    @Published private(set) var lastError: String?

    private var server: TX5DRServer?
    private var apiClient: TX5DRAPIClient?
    private let urlSession: URLSession
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

    private var downlinkSocket: URLSessionWebSocketTask?
    private var uplinkSocket: URLSessionWebSocketTask?
    private var downlinkReceiveTask: Task<Void, Never>?
    private var uplinkReceiveTask: Task<Void, Never>?
    private var downlinkHeartbeatTask: Task<Void, Never>?
    private var uplinkHeartbeatTask: Task<Void, Never>?
    private var uplinkSendTask: Task<Void, Never>?
    private var uplinkContinuation: AsyncStream<Data>.Continuation?
    private var downlinkGeneration = 0
    private var uplinkGeneration = 0

    private var playbackSampleRate: Double?
    private var playbackChannels: AVAudioChannelCount?
    private var scheduledPlaybackFrames = 0
    private let targetPlaybackFrames = 3
    private let maximumPlaybackFrames = 25

    private var inputTapInstalled = false
    private var captureAccumulator: [Float] = []
    private var captureSampleRate: Double = 48_000
    private var uplinkSequence: UInt32 = 0

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
        audioEngine.attach(playerNode)
    }

    func configure(server: TX5DRServer, apiClient: TX5DRAPIClient) {
        if self.server != server {
            stopAll()
        }
        self.server = server
        self.apiClient = apiClient
    }

    func startListening() async throws {
        if listeningState == .streaming || listeningState == .ready || listeningState == .connecting { return }
        guard let server, let apiClient else { throw TX5DRAudioError.notConfigured }

        stopListening()
        downlinkGeneration += 1
        let generation = downlinkGeneration
        listeningState = .connecting
        lastError = nil

        do {
            try configureAudioSession()
            let offer = try await apiClient.realtimeSession(direction: "recv")
            let url = try server.externalizedOfferURL(offer.url, token: offer.token)
            let socket = urlSession.webSocketTask(with: url)
            downlinkSocket = socket
            socket.resume()
            downlinkReceiveTask = Task { [weak self] in
                await self?.receiveDownlink(socket, generation: generation)
            }
            downlinkHeartbeatTask = Task { [weak self] in
                await self?.heartbeat(socket, uplink: false, generation: generation)
            }
            try await waitForDownlinkReady(generation: generation)
        } catch {
            if generation == downlinkGeneration {
                listeningState = .failed(error.localizedDescription)
                lastError = error.localizedDescription
                closeDownlinkSocket()
            }
            throw error
        }
    }

    func stopListening() {
        downlinkGeneration += 1
        closeDownlinkSocket()
        playerNode.stop()
        scheduledPlaybackFrames = 0
        receivedFrames = 0
        listeningState = .stopped
    }

    func prepareUplink() async throws -> String {
        if let participantIdentity, transmitState == .ready || transmitState == .streaming {
            return participantIdentity
        }
        guard let server, let apiClient else { throw TX5DRAudioError.notConfigured }

        closeUplinkSocket()
        uplinkGeneration += 1
        let generation = uplinkGeneration
        transmitState = .connecting
        lastError = nil
        uplinkSequence = 0
        sentFrames = 0
        droppedUplinkFrames = 0

        do {
            try configureAudioSession()
            let offer = try await apiClient.realtimeSession(direction: "send")
            participantIdentity = offer.participantIdentity
            let url = try server.externalizedOfferURL(offer.url, token: offer.token)
            let socket = urlSession.webSocketTask(with: url)
            uplinkSocket = socket
            startUplinkSendLoop(socket, generation: generation)
            socket.resume()
            uplinkReceiveTask = Task { [weak self] in
                await self?.receiveUplink(socket, generation: generation)
            }
            uplinkHeartbeatTask = Task { [weak self] in
                await self?.heartbeat(socket, uplink: true, generation: generation)
            }
            try await waitForUplinkReady(generation: generation)
            guard let participantIdentity else { throw TX5DRAudioError.missingParticipantIdentity }
            return participantIdentity
        } catch {
            if generation == uplinkGeneration {
                transmitState = .failed(error.localizedDescription)
                lastError = error.localizedDescription
                closeUplinkSocket()
            }
            throw error
        }
    }

    func beginMicrophoneCapture() async throws {
        guard uplinkSocket != nil, participantIdentity != nil else { throw TX5DRAudioError.notConfigured }
        if inputTapInstalled {
            transmitState = .streaming
            return
        }
        guard await requestMicrophonePermission() else {
            throw TX5DRAudioError.microphonePermissionDenied
        }

        try configureAudioSession()
        let inputNode = audioEngine.inputNode
        let format = inputNode.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw TX5DRAudioError.microphoneUnavailable
        }

        captureAccumulator.removeAll(keepingCapacity: true)
        captureSampleRate = format.sampleRate
        let requestedFrames = AVAudioFrameCount(max(128, Int(format.sampleRate * 0.02)))
        inputNode.installTap(onBus: 0, bufferSize: requestedFrames, format: nil) { [weak self] buffer, _ in
            let samples = Self.copyMonoSamples(from: buffer)
            let sampleRate = buffer.format.sampleRate
            Task { @MainActor [weak self] in
                self?.consumeCapturedSamples(samples, sampleRate: sampleRate)
            }
        }
        inputTapInstalled = true

        do {
            try ensureEngineStarted()
            transmitState = .streaming
        } catch {
            inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
            throw error
        }
    }

    func stopMicrophoneCapture() {
        if inputTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        captureAccumulator.removeAll(keepingCapacity: true)
        microphoneLevel = 0
        if uplinkSocket != nil {
            transmitState = .ready
        } else {
            transmitState = .stopped
        }
    }

    func shutdownUplink() {
        stopMicrophoneCapture()
        uplinkGeneration += 1
        closeUplinkSocket()
        participantIdentity = nil
        transmitState = .stopped
    }

    func stopAll() {
        stopListening()
        shutdownUplink()
        audioEngine.stop()
        playbackSampleRate = nil
        playbackChannels = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func setMonitorVolume(decibels: Double) {
        let linear = pow(10, decibels / 20)
        playerNode.volume = Float(max(0, min(2, linear)))
    }

    private func receiveDownlink(_ socket: URLSessionWebSocketTask, generation: Int) async {
        do {
            while !Task.isCancelled {
                let message = try await socket.receive()
                guard generation == downlinkGeneration, downlinkSocket === socket else { return }
                switch message {
                case .string(let text):
                    handleDownlinkControl(text)
                case .data(let data):
                    try handleDownlinkAudio(data)
                @unknown default:
                    continue
                }
            }
        } catch {
            guard generation == downlinkGeneration, downlinkSocket === socket else { return }
            downlinkSocket = nil
            listeningState = .failed(error.localizedDescription)
            lastError = error.localizedDescription
        }
    }

    private func receiveUplink(_ socket: URLSessionWebSocketTask, generation: Int) async {
        do {
            while !Task.isCancelled {
                let message = try await socket.receive()
                guard generation == uplinkGeneration, uplinkSocket === socket else { return }
                if case .string(let text) = message {
                    handleUplinkControl(text)
                }
            }
        } catch {
            guard generation == uplinkGeneration, uplinkSocket === socket else { return }
            stopMicrophoneCapture()
            uplinkSocket = nil
            transmitState = .failed(error.localizedDescription)
            lastError = error.localizedDescription
        }
    }

    private func handleDownlinkControl(_ text: String) {
        guard let data = text.data(using: .utf8),
              let message = try? JSONDecoder().decode(RealtimeReadyMessage.self, from: data) else { return }
        if message.type == "ready" {
            listeningState = .streaming
        }
    }

    private func handleUplinkControl(_ text: String) {
        guard let data = text.data(using: .utf8),
              let message = try? JSONDecoder().decode(RealtimeReadyMessage.self, from: data) else { return }
        if message.type == "ready" {
            participantIdentity = message.participantIdentity ?? participantIdentity
            transmitState = .ready
        }
    }

    private func handleDownlinkAudio(_ data: Data) throws {
        let frame = try RealtimeAudioFrameCodec.decode(data)
        guard scheduledPlaybackFrames < maximumPlaybackFrames else { return }
        guard let buffer = makePlaybackBuffer(frame) else { throw TX5DRAudioError.invalidAudioBuffer }
        try ensurePlaybackFormat(buffer.format)

        scheduledPlaybackFrames += 1
        receivedFrames &+= 1
        playerNode.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.scheduledPlaybackFrames = max(0, self.scheduledPlaybackFrames - 1)
            }
        }
        if !playerNode.isPlaying, scheduledPlaybackFrames >= targetPlaybackFrames {
            playerNode.play()
        }
    }

    private func makePlaybackBuffer(_ frame: RealtimePCMFrame) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(frame.sampleRate),
            channels: AVAudioChannelCount(frame.channels),
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frame.samplesPerChannel)
        ), let channelData = buffer.floatChannelData else { return nil }

        buffer.frameLength = AVAudioFrameCount(frame.samplesPerChannel)
        let channels = Int(frame.channels)
        let frames = Int(frame.samplesPerChannel)
        for frameIndex in 0..<frames {
            for channel in 0..<channels {
                channelData[channel][frameIndex] = Float(frame.samples[frameIndex * channels + channel]) / 32_768
            }
        }
        return buffer
    }

    private func ensurePlaybackFormat(_ format: AVAudioFormat) throws {
        let changed = playbackSampleRate != format.sampleRate || playbackChannels != format.channelCount
        if changed {
            playerNode.stop()
            scheduledPlaybackFrames = 0
            if audioEngine.isRunning { audioEngine.stop() }
            audioEngine.disconnectNodeOutput(playerNode)
            audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)
            playbackSampleRate = format.sampleRate
            playbackChannels = format.channelCount
        }
        try ensureEngineStarted()
    }

    private func ensureEngineStarted() throws {
        guard !audioEngine.isRunning else { return }
        audioEngine.prepare()
        try audioEngine.start()
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetooth]
        )
        try session.setPreferredSampleRate(48_000)
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    nonisolated private static func copyMonoSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channels = buffer.floatChannelData else { return [] }
        let frameCount = Int(buffer.frameLength)
        let channelCount = max(1, Int(buffer.format.channelCount))
        var result = [Float](repeating: 0, count: frameCount)
        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += channels[channel][frame]
            }
            result[frame] = sum / Float(channelCount)
        }
        return result
    }

    private func consumeCapturedSamples(_ samples: [Float], sampleRate: Double) {
        guard inputTapInstalled, !samples.isEmpty, uplinkSocket != nil else { return }
        if abs(captureSampleRate - sampleRate) > 0.5 {
            captureAccumulator.removeAll(keepingCapacity: true)
            captureSampleRate = sampleRate
        }
        captureAccumulator.append(contentsOf: samples)

        let frameLength = max(1, Int((captureSampleRate * 0.02).rounded()))
        while captureAccumulator.count >= frameLength {
            let chunk = Array(captureAccumulator.prefix(frameLength))
            captureAccumulator.removeFirst(frameLength)
            enqueueUplinkFrame(chunk, sampleRate: captureSampleRate)
        }
    }

    private func enqueueUplinkFrame(_ samples: [Float], sampleRate: Double) {
        let rms = sqrt(samples.reduce(0) { $0 + Double($1 * $1) } / Double(max(1, samples.count)))
        microphoneLevel = min(1, rms * 4)
        let pcm = samples.map { sample -> Int16 in
            let clipped = max(-1, min(1, sample))
            return clipped < 0
                ? Int16((clipped * 32_768).rounded())
                : Int16((clipped * 32_767).rounded())
        }
        guard let sampleRateValue = UInt32(exactly: Int(sampleRate.rounded())),
              let samplesPerChannel = UInt16(exactly: pcm.count) else {
            droppedUplinkFrames &+= 1
            return
        }

        let timestamp = UInt32(truncatingIfNeeded: UInt64(Date().timeIntervalSince1970 * 1_000))
        let frame = RealtimePCMFrame(
            sequence: uplinkSequence,
            timestampMilliseconds: timestamp,
            serverSentAtMilliseconds: nil,
            sampleRate: sampleRateValue,
            channels: 1,
            samplesPerChannel: samplesPerChannel,
            samples: pcm
        )
        uplinkSequence &+= 1
        guard let data = try? RealtimeAudioFrameCodec.encode(frame) else {
            droppedUplinkFrames &+= 1
            return
        }
        switch uplinkContinuation?.yield(data) {
        case .dropped:
            droppedUplinkFrames &+= 1
        case .enqueued:
            sentFrames &+= 1
        case .terminated, .none:
            droppedUplinkFrames &+= 1
        @unknown default:
            droppedUplinkFrames &+= 1
        }
    }

    private func startUplinkSendLoop(_ socket: URLSessionWebSocketTask, generation: Int) {
        let stream = AsyncStream<Data>(bufferingPolicy: .bufferingNewest(20)) { continuation in
            uplinkContinuation = continuation
        }
        uplinkSendTask = Task { [weak self] in
            do {
                for await data in stream {
                    try Task.checkCancellation()
                    try await socket.send(.data(data))
                }
            } catch {
                guard let self, generation == self.uplinkGeneration, self.uplinkSocket === socket else { return }
                self.stopMicrophoneCapture()
                self.transmitState = .failed(error.localizedDescription)
                self.lastError = error.localizedDescription
            }
        }
    }

    private func heartbeat(_ socket: URLSessionWebSocketTask, uplink: Bool, generation: Int) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            if uplink {
                guard generation == uplinkGeneration, uplinkSocket === socket else { return }
            } else {
                guard generation == downlinkGeneration, downlinkSocket === socket else { return }
            }
            socket.sendPing { _ in }
        }
    }

    private func waitForDownlinkReady(generation: Int) async throws {
        for _ in 0..<120 {
            try Task.checkCancellation()
            guard generation == downlinkGeneration else { throw CancellationError() }
            if listeningState == .streaming || listeningState == .ready { return }
            if case .failed(let message) = listeningState {
                throw NSError(domain: "TX5DRAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw TX5DRAudioError.connectionTimeout
    }

    private func waitForUplinkReady(generation: Int) async throws {
        for _ in 0..<120 {
            try Task.checkCancellation()
            guard generation == uplinkGeneration else { throw CancellationError() }
            if transmitState == .ready || transmitState == .streaming { return }
            if case .failed(let message) = transmitState {
                throw NSError(domain: "TX5DRAudio", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw TX5DRAudioError.connectionTimeout
    }

    private func closeDownlinkSocket() {
        downlinkReceiveTask?.cancel()
        downlinkReceiveTask = nil
        downlinkHeartbeatTask?.cancel()
        downlinkHeartbeatTask = nil
        downlinkSocket?.cancel(with: .goingAway, reason: nil)
        downlinkSocket = nil
    }

    private func closeUplinkSocket() {
        uplinkContinuation?.finish()
        uplinkContinuation = nil
        uplinkSendTask?.cancel()
        uplinkSendTask = nil
        uplinkReceiveTask?.cancel()
        uplinkReceiveTask = nil
        uplinkHeartbeatTask?.cancel()
        uplinkHeartbeatTask = nil
        uplinkSocket?.cancel(with: .goingAway, reason: nil)
        uplinkSocket = nil
    }
}
