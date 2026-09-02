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

enum RadioLiteAudioInterruptionAction: Equatable, Sendable {
    case stopCaptureAndTransmit
    case resumeReceiveOnly
    case reconfigureAudio(RadioLiteAudioReconfiguration)
    case ignore
}

enum RadioLiteAudioRouteChangeKind: Equatable, Sendable {
    case newDeviceAvailable
    case oldDeviceUnavailable
    case categoryChange
    case wakeFromSleep
    case noSuitableRouteForCategory
    case routeConfigurationChange
}

enum RadioLiteAudioReconfiguration: Equatable, Sendable {
    case route(RadioLiteAudioRouteChangeKind)
    case engine
}

enum RadioLiteAudioInterruptionPolicy {
    static func action(for notification: Notification) -> RadioLiteAudioInterruptionAction {
        if notification.name == .AVAudioEngineConfigurationChange {
            return .reconfigureAudio(.engine)
        }
        if let routeChange = routeChangeKind(for: notification) {
            return .reconfigureAudio(.route(routeChange))
        }
        if notification.name == AVAudioSession.mediaServicesWereLostNotification
            || notification.name == AVAudioSession.mediaServicesWereResetNotification {
            return .stopCaptureAndTransmit
        }
        guard let type = interruptionType(for: notification) else {
            return .ignore
        }
        return type == .began ? .stopCaptureAndTransmit : .resumeReceiveOnly
    }

    static func interruptionType(for notification: Notification) -> AVAudioSession.InterruptionType? {
        guard notification.name == AVAudioSession.interruptionNotification,
              let rawValue = interruptionTypeRawValue(
                notification.userInfo?[AVAudioSessionInterruptionTypeKey]
              ) else {
            return nil
        }
        return AVAudioSession.InterruptionType(rawValue: rawValue)
    }

    static func routeChangeKind(for notification: Notification) -> RadioLiteAudioRouteChangeKind? {
        guard notification.name == AVAudioSession.routeChangeNotification,
              let rawValue = unsignedInteger(
                  notification.userInfo?[AVAudioSessionRouteChangeReasonKey]
              ),
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawValue) else {
            return nil
        }
        switch reason {
        case .newDeviceAvailable: return .newDeviceAvailable
        case .oldDeviceUnavailable: return .oldDeviceUnavailable
        case .categoryChange: return .categoryChange
        case .wakeFromSleep: return .wakeFromSleep
        case .noSuitableRouteForCategory: return .noSuitableRouteForCategory
        case .routeConfigurationChange: return .routeConfigurationChange
        default: return nil
        }
    }

    private static func interruptionTypeRawValue(_ value: Any?) -> UInt? {
        unsignedInteger(value)
    }

    private static func unsignedInteger(_ value: Any?) -> UInt? {
        if let rawValue = value as? UInt { return rawValue }
        return (value as? NSNumber)?.uintValue
    }
}

private final class RadioLiteNotificationObservationBag {
    private let notificationCenter: NotificationCenter
    private var observers: [NSObjectProtocol] = []

    init(notificationCenter: NotificationCenter) {
        self.notificationCenter = notificationCenter
    }

    func insert(_ observer: NSObjectProtocol) {
        observers.append(observer)
    }

    deinit {
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
    }
}

private struct RadioLiteAudioReconfigurationGate {
    // iOS commonly emits route and engine notifications for one hardware change.
    static let cooldown: TimeInterval = 0.25

    private var lastDeliveryUptime: TimeInterval?

    func isCoolingDown(at uptime: TimeInterval) -> Bool {
        guard let lastDeliveryUptime else { return false }
        return uptime < lastDeliveryUptime + Self.cooldown
    }

    mutating func recordDelivery(at uptime: TimeInterval) {
        lastDeliveryUptime = uptime
    }
}

@MainActor
final class RadioLiteAudioInterruptionObserver {
    private let observationBag: RadioLiteNotificationObservationBag
    private let monotonicTime: @MainActor () -> TimeInterval
    private let onStopCaptureAndTransmit: @MainActor () -> Void
    private let onMediaServicesReset: @MainActor () -> Void
    private let onAudioReconfiguration: @MainActor (RadioLiteAudioReconfiguration) -> Bool
    private let onReceiveMayResume: @MainActor () -> Void
    private var stopDeliveredForCurrentEpisode = false
    private var audioReconfigurationGate = RadioLiteAudioReconfigurationGate()

    init(
        notificationCenter: NotificationCenter = .default,
        monotonicTime: @escaping @MainActor () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        onStopCaptureAndTransmit: @escaping @MainActor () -> Void,
        onMediaServicesReset: @escaping @MainActor () -> Void,
        onAudioReconfiguration: @escaping @MainActor (RadioLiteAudioReconfiguration) -> Bool,
        onReceiveMayResume: @escaping @MainActor () -> Void
    ) {
        let observationBag = RadioLiteNotificationObservationBag(
            notificationCenter: notificationCenter
        )
        self.observationBag = observationBag
        self.monotonicTime = monotonicTime
        self.onStopCaptureAndTransmit = onStopCaptureAndTransmit
        self.onMediaServicesReset = onMediaServicesReset
        self.onAudioReconfiguration = onAudioReconfiguration
        self.onReceiveMayResume = onReceiveMayResume
        for name in [
            AVAudioSession.interruptionNotification,
            AVAudioSession.mediaServicesWereLostNotification,
            AVAudioSession.mediaServicesWereResetNotification,
            AVAudioSession.routeChangeNotification,
            .AVAudioEngineConfigurationChange,
        ] {
            let observer = notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    self?.receive(notification)
                }
            }
            observationBag.insert(observer)
        }
    }

    func rearm() {
        stopDeliveredForCurrentEpisode = false
    }

    private func receive(_ notification: Notification) {
        let action = RadioLiteAudioInterruptionPolicy.action(for: notification)
        switch action {
        case .resumeReceiveOnly:
            rearm()
            onReceiveMayResume()
            return
        case .stopCaptureAndTransmit:
            if !stopDeliveredForCurrentEpisode {
                stopDeliveredForCurrentEpisode = true
                onStopCaptureAndTransmit()
            }
        case .reconfigureAudio(let change):
            let uptime = monotonicTime()
            guard !audioReconfigurationGate.isCoolingDown(at: uptime) else { return }
            if onAudioReconfiguration(change) {
                audioReconfigurationGate.recordDelivery(at: uptime)
            }
            return
        case .ignore:
            return
        }
        if notification.name == AVAudioSession.mediaServicesWereResetNotification {
            onMediaServicesReset()
            onReceiveMayResume()
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

struct RadioLitePlaybackQueueState: Equatable, Sendable {
    let targetBuffers: Int
    let maximumBuffers: Int
    private(set) var scheduledBuffers = 0
    private(set) var generation: UInt64 = 1

    init(targetBuffers: Int, maximumBuffers: Int) {
        precondition(targetBuffers > 0 && maximumBuffers >= targetBuffers)
        self.targetBuffers = targetBuffers
        self.maximumBuffers = maximumBuffers
    }

    mutating func enqueue() -> UInt64? {
        guard scheduledBuffers < maximumBuffers else { return nil }
        scheduledBuffers += 1
        return generation
    }

    mutating func complete(generation completedGeneration: UInt64) {
        guard completedGeneration == generation else { return }
        scheduledBuffers = max(0, scheduledBuffers - 1)
    }

    mutating func flush() {
        generation &+= 1
        if generation == 0 { generation = 1 }
        scheduledBuffers = 0
    }

    func requiresRecovery(engineRunning _: Bool, playerPlaying _: Bool) -> Bool {
        scheduledBuffers >= maximumBuffers
    }

    func shouldStartPlayback(playerPlaying: Bool) -> Bool {
        !playerPlaying && scheduledBuffers >= targetBuffers
    }
}

struct RadioLitePlaybackSuspensionState: Equatable, Sendable {
    private(set) var isSuspended = false

    mutating func captureStarted() {
        isSuspended = true
    }

    mutating func captureStopped(resumeImmediately: Bool) {
        isSuspended = !resumeImmediately
    }

    mutating func resumeAfterLocalTransmitRelease() {
        isSuspended = false
    }

    mutating func monitoringStarted() {
        isSuspended = false
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
    @Published var microphoneProcessingMode: RadioLiteMicrophoneProcessingMode {
        didSet { persistMicrophonePreferences() }
    }
    @Published var microphoneGain: RadioLiteMicrophoneGain {
        didSet { persistMicrophonePreferences() }
    }
    @Published var monitorVolume: Double = 0.8 {
        didSet { player.volume = Float(min(1, max(0, monitorVolume))) }
    }

    var onCaptureInterrupted: (@MainActor () -> Void)?
    var onAudioReconfigurationDetected: (@MainActor (_ microphoneWasCapturing: Bool) -> Void)?
    var onReceiveMayResume: (@MainActor () -> Void)?
    var onReceivePlaybackStarted: (@MainActor () -> Void)?

    var isPlaybackSuspended: Bool { playbackSuspension.isSuspended }

    // Keep playback and recording on separate graphs. Once an AVAudioEngine's
    // input node has been activated, restarting that same graph under a
    // playback-only AVAudioSession can fail with OSStatus '!rec'. Separate
    // graphs also let PTT release the microphone without tearing down the
    // optional receive-audio player.
    private var playbackEngine = AVAudioEngine()
    private var captureEngine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var audioSessionInterruptionObserver: RadioLiteAudioInterruptionObserver?
    private var isHandlingAudioReconfiguration = false
    private var codec: RadioLiteOpusCodec?
    private var configuredOpusBitrate = 20_000
    private var inputTapInstalled = false
    private var captureAccumulator: [Float] = []
    private var captureSampleRate: Double = 48_000
    private var packetHandler: ((Data) -> Void)?
    private var captureEpochState = RadioLiteCaptureEpochState()
    private var microphoneProcessor = RadioLiteMicrophoneProcessor()
    private var microphoneTelemetryLimiter = AudioTelemetryLimiter(minimumInterval: 0.1)
    private var playbackQueue = RadioLitePlaybackQueueState(targetBuffers: 3, maximumBuffers: 12)
    private var playbackSuspension = RadioLitePlaybackSuspensionState()

    init(notificationCenter: NotificationCenter = .default) {
        let microphonePreferences = RadioLiteMicrophonePreferences.load()
        microphoneProcessingMode = microphonePreferences.processingMode
        microphoneGain = microphonePreferences.gain
        configureAudioResources()
        audioSessionInterruptionObserver = RadioLiteAudioInterruptionObserver(
            notificationCenter: notificationCenter,
            onStopCaptureAndTransmit: { [weak self] in
                self?.handleAudioSessionInterruption()
            },
            onMediaServicesReset: { [weak self] in
                self?.rebuildAudioResourcesAfterMediaServicesReset()
            },
            onAudioReconfiguration: { [weak self] change in
                self?.handleAudioReconfiguration(change) ?? false
            },
            onReceiveMayResume: { [weak self] in
                self?.onReceiveMayResume?()
            }
        )
    }

    func setOpusBitrate(_ bitrate: Int) {
        configuredOpusBitrate = bitrate
        do {
            try codec?.setBitrate(bitrate)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func startMonitoring() throws {
        audioSessionInterruptionObserver?.rearm()
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
            playbackSuspension.monitoringStarted()
            lastError = nil
            onReceivePlaybackStarted?()
        } catch {
            isMonitoring = false
            flushPlaybackQueue()
            playbackEngine.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            let wrapped = RadioLiteAudioError.playbackUnavailable(Self.diagnostic(error))
            lastError = wrapped.localizedDescription
            throw wrapped
        }
    }

    func stopMonitoring() {
        isMonitoring = false
        flushPlaybackQueue()
        playbackEngine.stop()
        if !isCapturingMicrophone {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func discardBufferedPlayback() {
        guard isMonitoring else { return }
        flushPlaybackQueue()
    }

    @discardableResult
    func receiveOpusPacket(_ packet: Data) -> Bool {
        guard isMonitoring, !isCapturingMicrophone,
              !playbackSuspension.isSuspended, let codec else { return false }
        if playbackQueue.requiresRecovery(
            engineRunning: playbackEngine.isRunning,
            playerPlaying: player.isPlaying
        ) {
            flushPlaybackQueue()
        }
        guard playbackQueue.scheduledBuffers < playbackQueue.maximumBuffers else {
            droppedPackets &+= 1
            return false
        }
        do {
            try ensurePlaybackEngineStarted()
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
            guard let queueGeneration = playbackQueue.enqueue() else {
                droppedPackets &+= 1
                return false
            }
            receivedPackets &+= 1
            player.scheduleBuffer(buffer) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.playbackQueue.complete(generation: queueGeneration)
                }
            }
            if playbackQueue.shouldStartPlayback(playerPlaying: player.isPlaying) { player.play() }
            lastError = nil
            return true
        } catch {
            droppedPackets &+= 1
            lastError = error.localizedDescription
            if !playbackEngine.isRunning {
                flushPlaybackQueue()
            }
            return false
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
        armPTTInterruptionFailSafe()
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
            try input.setVoiceProcessingEnabled(
                microphoneProcessingMode.configuration.voiceProcessingEnabled
            )
            let format = input.outputFormat(forBus: 0)
            guard format.channelCount > 0, format.sampleRate > 0 else {
                throw RadioLiteAudioError.microphoneUnavailable
            }
            captureAccumulator.removeAll(keepingCapacity: true)
            captureSampleRate = format.sampleRate
            microphoneProcessor.reset()
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
    func stopMicrophoneCapture(
        epoch: UInt64? = nil,
        resumeMonitoringAfterCapture: Bool = true
    ) -> Bool {
        let result = captureEpochState.stop(epoch: epoch)
        guard result == .stoppedActive else { return false }
        cleanupCaptureGraph()
        playbackSuspension.captureStopped(
            resumeImmediately: resumeMonitoringAfterCapture && isMonitoring
        )

        if resumeMonitoringAfterCapture, isMonitoring {
            resumePlaybackAfterCaptureIfNeeded()
        } else if !isMonitoring {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        return true
    }

    func resumeAfterLocalTransmitRelease() {
        guard !isCapturingMicrophone else { return }
        playbackSuspension.resumeAfterLocalTransmitRelease()
        resumePlaybackAfterCaptureIfNeeded()
    }

    func armPTTInterruptionFailSafe() {
        audioSessionInterruptionObserver?.rearm()
    }

    func stopAll() {
        isMonitoring = false
        let stoppedCapture = stopMicrophoneCapture()
        flushPlaybackQueue()
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
            let processed = microphoneProcessor.processFrame(resampled, gain: microphoneGain)
            if microphoneTelemetryLimiter.shouldPublish(at: ProcessInfo.processInfo.systemUptime) {
                microphoneLevel = processed.level
            }
            do {
                guard let packet = try codec?.encode(processed.samples) else {
                    throw RadioLiteOpusError.emptyPacket
                }
                sentPackets &+= 1
                packetHandler?(packet)
            } catch {
                droppedPackets &+= 1
                lastError = error.localizedDescription
            }
        }
    }

    private func activateAudioSession(capturing _: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        // Keep one play-and-record route while monitoring and transmitting.
        // Switching playback/A2DP to record/HFP on every PTT release can take
        // seconds; a stable radio-voice route makes receive resume immediately.
        let mode = microphoneProcessingMode.configuration.audioSessionMode
        do {
            try session.setCategory(
                .playAndRecord,
                mode: mode,
                options: [.defaultToSpeaker, .allowBluetooth]
            )
        } catch {
            try session.setCategory(.playAndRecord, mode: mode, options: [.defaultToSpeaker])
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
        playbackSuspension.captureStarted()
        flushPlaybackQueue()
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
        microphoneProcessor.reset()
        microphoneTelemetryLimiter.reset()
        microphoneLevel = 0
        codec?.reset()
    }

    private func resumePlaybackAfterCaptureIfNeeded() {
        guard !isCapturingMicrophone else { return }
        guard !playbackSuspension.isSuspended else { return }
        guard isMonitoring else {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            return
        }
        do {
            // Capture and playback share one stable play-and-record session.
            // Reconfiguring/activating it again on every release can block for
            // seconds on Bluetooth and is unnecessary after local capture stops.
            try ensurePlaybackEngineStarted()
            lastError = nil
            onReceivePlaybackStarted?()
        } catch {
            isMonitoring = false
            flushPlaybackQueue()
            playbackEngine.stop()
            lastError = RadioLiteAudioError.playbackUnavailable(Self.diagnostic(error)).localizedDescription
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func persistMicrophonePreferences() {
        RadioLiteMicrophonePreferences(
            processingMode: microphoneProcessingMode,
            gain: microphoneGain
        ).save()
    }

    private func configureAudioResources() {
        playbackEngine.attach(player)
        do {
            let codec = try RadioLiteOpusCodec(bitrate: configuredOpusBitrate)
            self.codec = codec
            playbackEngine.connect(
                player,
                to: playbackEngine.mainMixerNode,
                format: codec.pcmFormat
            )
            lastError = nil
        } catch {
            codec = nil
            lastError = error.localizedDescription
        }
        player.volume = Float(monitorVolume)
    }

    private func flushPlaybackQueue() {
        playbackQueue.flush()
        player.stop()
    }

    private func rebuildAudioResourcesAfterMediaServicesReset() {
        // Apple invalidates every AVAudioEngine node and AudioConverter after
        // a media-services reset. Release the orphaned graph and codec instead
        // of attempting to restart them.
        _ = captureEpochState.stop()
        isMonitoring = false
        isCapturingMicrophone = false
        inputTapInstalled = false
        packetHandler = nil
        captureAccumulator.removeAll(keepingCapacity: true)
        captureSampleRate = 48_000
        microphoneProcessor.reset()
        microphoneTelemetryLimiter.reset()
        microphoneLevel = 0
        playbackQueue.flush()
        codec = nil
        playbackEngine = AVAudioEngine()
        captureEngine = AVAudioEngine()
        player = AVAudioPlayerNode()
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        configureAudioResources()
    }

    private func handleAudioSessionInterruption() {
        // Stop the hardware before asking the session to perform any
        // asynchronous remote cleanup. Never restart capture on .ended.
        _ = stopMicrophoneCapture(resumeMonitoringAfterCapture: false)
        stopMonitoring()
        onCaptureInterrupted?()
    }

    private func handleAudioReconfiguration(_ change: RadioLiteAudioReconfiguration) -> Bool {
        guard !isHandlingAudioReconfiguration else { return false }
        if change == .route(.categoryChange) {
            let session = AVAudioSession.sharedInstance()
            let expectedMode = microphoneProcessingMode.configuration.audioSessionMode
            guard session.category != .playAndRecord || session.mode != expectedMode else {
                return false
            }
        }

        isHandlingAudioReconfiguration = true
        defer { isHandlingAudioReconfiguration = false }
        let interruptedTransmit = isCapturingMicrophone
        onAudioReconfigurationDetected?(interruptedTransmit)
        handleAudioSessionInterruption()
        onReceiveMayResume?()
        return true
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
