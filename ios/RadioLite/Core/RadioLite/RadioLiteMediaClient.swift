import Combine
import Foundation

struct RadioLiteUplinkOwnership: Equatable, Sendable {
    let transmitToken: String
    let epoch: UInt64
}

struct RadioLiteMediaSubscriptionOwnership: Equatable, Sendable {
    let radioId: String
    let epoch: UInt64
}

struct RadioLiteMediaSubscriptionOwnershipState: Equatable, Sendable {
    private var epoch = RadioLiteOperationEpoch()
    private var current: RadioLiteMediaSubscriptionOwnership?

    mutating func begin(radioId: String) -> RadioLiteMediaSubscriptionOwnership {
        let ownership = RadioLiteMediaSubscriptionOwnership(
            radioId: radioId,
            epoch: epoch.begin()
        )
        current = ownership
        return ownership
    }

    func complete(_ ownership: RadioLiteMediaSubscriptionOwnership) -> Bool {
        current == ownership && epoch.owns(ownership.epoch)
    }

    mutating func invalidate() {
        epoch.invalidate()
        current = nil
    }

    func isCurrent(_ ownership: RadioLiteMediaSubscriptionOwnership) -> Bool {
        current == ownership && epoch.owns(ownership.epoch)
    }
}

struct RadioLiteUplinkOwnershipState: Equatable, Sendable {
    private var epoch = RadioLiteOperationEpoch()
    private var current: RadioLiteUplinkOwnership?
    private var bound = false

    mutating func begin(transmitToken: String) -> RadioLiteUplinkOwnership {
        let ownership = RadioLiteUplinkOwnership(
            transmitToken: transmitToken,
            epoch: epoch.begin()
        )
        current = ownership
        bound = false
        return ownership
    }

    mutating func complete(_ ownership: RadioLiteUplinkOwnership) -> Bool {
        guard current == ownership, epoch.owns(ownership.epoch) else { return false }
        bound = true
        return true
    }

    @discardableResult
    mutating func stop(transmitToken: String? = nil, epoch expectedEpoch: UInt64? = nil) -> Bool {
        if let transmitToken, current?.transmitToken != transmitToken { return false }
        if let expectedEpoch, current?.epoch != expectedEpoch { return false }
        let hadOwner = current != nil
        epoch.invalidate()
        current = nil
        bound = false
        return hadOwner
    }

    func isCurrent(_ ownership: RadioLiteUplinkOwnership) -> Bool {
        current == ownership && epoch.owns(ownership.epoch)
    }

    func isBound(_ ownership: RadioLiteUplinkOwnership) -> Bool {
        bound && isCurrent(ownership)
    }

    var currentOwnership: RadioLiteUplinkOwnership? { current }
    var isBound: Bool { bound && current != nil }
}

enum RadioLiteMediaFailurePresentation: Equatable, Sendable {
    case reconnectBanner
    case uplinkBanner
    case none

    static func route(
        wasUplinkBound: Bool,
        reconnectRequired: Bool
    ) -> Self {
        if reconnectRequired { return .reconnectBanner }
        if wasUplinkBound { return .uplinkBanner }
        return .none
    }
}

enum RadioLiteAudioFrameDisposition: Equatable, Sendable {
    case accept
    case discardAndFlush
    case discard
}

struct RadioLiteAudioFreshnessState: Equatable, Sendable {
    private let maximumExcessDelayMicroseconds: Double
    private var bestTransitMicroseconds: Double?
    private var isDiscarding = false

    init(maximumExcessDelayMicroseconds: UInt64 = 400_000) {
        self.maximumExcessDelayMicroseconds = Double(maximumExcessDelayMicroseconds)
    }

    mutating func disposition(
        timestampMicroseconds: UInt64,
        receivedAtMicroseconds: UInt64
    ) -> RadioLiteAudioFrameDisposition {
        let transit = Double(receivedAtMicroseconds) - Double(timestampMicroseconds)
        guard transit.isFinite else { return .accept }
        if bestTransitMicroseconds == nil || transit < bestTransitMicroseconds! {
            bestTransitMicroseconds = transit
            isDiscarding = false
            return .accept
        }
        guard let bestTransitMicroseconds,
              transit - bestTransitMicroseconds > maximumExcessDelayMicroseconds else {
            isDiscarding = false
            return .accept
        }
        if isDiscarding { return .discard }
        isDiscarding = true
        return .discardAndFlush
    }

    mutating func reset() {
        bestTransitMicroseconds = nil
        isDiscarding = false
    }
}

enum RadioLiteMediaLivenessFailure: LocalizedError, Equatable, Sendable {
    case channelStalled
    case audioStalled

    var errorDescription: String? {
        switch self {
        case .channelStalled:
            "媒体连接长时间没有收到服务器数据，正在重新连接"
        case .audioStalled:
            "接收音频流已中断，正在重新连接"
        }
    }
}

struct RadioLiteMediaLivenessState: Equatable, Sendable {
    private let channelTimeout: TimeInterval
    private let audioTimeout: TimeInterval
    private var lastInboundAt: TimeInterval
    private var lastAudioAt: TimeInterval?
    private var subscriptionStartedAt: TimeInterval?
    private var monitoringStartedAt: TimeInterval?

    init(
        connectedAt: TimeInterval,
        channelTimeout: TimeInterval = 30,
        audioTimeout: TimeInterval = 8
    ) {
        self.channelTimeout = channelTimeout
        self.audioTimeout = audioTimeout
        self.lastInboundAt = connectedAt
    }

    mutating func subscriptionStarted(at time: TimeInterval) {
        subscriptionStartedAt = time
        lastInboundAt = max(lastInboundAt, time)
        lastAudioAt = nil
        monitoringStartedAt = nil
    }

    mutating func subscriptionEnded() {
        subscriptionStartedAt = nil
        lastAudioAt = nil
        monitoringStartedAt = nil
    }

    mutating func monitoringStarted(at time: TimeInterval) {
        monitoringStartedAt = time
        lastAudioAt = nil
    }

    mutating func receivedInbound(at time: TimeInterval) {
        lastInboundAt = time
    }

    mutating func receivedAudio(at time: TimeInterval) {
        lastAudioAt = time
        receivedInbound(at: time)
    }

    func failure(
        at time: TimeInterval,
        monitoringAudio: Bool
    ) -> RadioLiteMediaLivenessFailure? {
        guard let subscriptionStartedAt else { return nil }
        if time - max(subscriptionStartedAt, lastInboundAt) >= channelTimeout {
            return .channelStalled
        }
        let audioReference = lastAudioAt ?? monitoringStartedAt ?? subscriptionStartedAt
        if monitoringAudio, time - audioReference >= audioTimeout {
            return .audioStalled
        }
        return nil
    }
}

@MainActor
final class RadioLiteMediaClient: ObservableObject {
    @Published private(set) var state: RadioLiteSocketState = .disconnected
    @Published private(set) var policy: RadioLiteMediaPolicy?
    @Published private(set) var spectrum: RadioLiteSpectrumFrame?
    @Published private(set) var spectrumCapability: RadioLiteSpectrumCapability?
    @Published private(set) var spectrumHistory: [[UInt8]] = []
    @Published private(set) var radioSlot: UInt8?
    @Published private(set) var subscribedRadioId: String?
    @Published private(set) var isUplinkBound = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastRoundTripMs: Double = 0

    var onDisconnect: ((Error) -> Void)?
    var onUplinkFailure: ((Error) -> Void)?
    var onReconnectRequired: ((Error) -> Void)?

    let audio: RadioLiteAudioEngine

    private let channel = RadioLiteWebSocketChannel()
    private var spectrumVisible = true
    private var pingStartedAt: Date?
    private var networkTask: Task<Void, Never>?
    private var uplinkSendTask: Task<Void, Never>?
    private var uplinkContinuation: AsyncStream<Data>.Continuation?
    private var uplinkSequence: UInt32 = 0
    private var uplinkOwnershipState = RadioLiteUplinkOwnershipState()
    private var subscriptionOwnershipState = RadioLiteMediaSubscriptionOwnershipState()
    private var spectrumHistoryBuffer = RadioLiteSpectrumHistory()
    private var spectrumAGC = RadioLiteSpectrumAGC()
    private var audioFreshness = RadioLiteAudioFreshnessState()
    private var liveness = RadioLiteMediaLivenessState(
        connectedAt: ProcessInfo.processInfo.systemUptime
    )

    init(audio: RadioLiteAudioEngine? = nil) {
        self.audio = audio ?? RadioLiteAudioEngine()
        self.audio.onReceivePlaybackStarted = { [weak self] in
            guard let self, self.subscribedRadioId != nil else { return }
            self.liveness.monitoringStarted(at: ProcessInfo.processInfo.systemUptime)
        }
        channel.onJSON = { [weak self] value in self?.handle(value) }
        channel.onBinary = { [weak self] data in self?.handle(data) }
        channel.onDisconnect = { [weak self] error in
            guard let self else { return }
            self.stopUplink()
            self.subscriptionOwnershipState.invalidate()
            self.audio.stopMicrophoneCapture(resumeMonitoringAfterCapture: false)
            self.subscribedRadioId = nil
            self.radioSlot = nil
            self.audioFreshness.reset()
            self.liveness.subscriptionEnded()
            self.clearSpectrum(keepingCapability: false)
            self.state = .failed(error.localizedDescription)
            self.lastError = error.localizedDescription
            self.networkTask?.cancel()
            self.onDisconnect?(error)
        }
    }

    func connect(server: RadioLiteServer, credential: RadioLiteCredential) async throws -> RadioLiteAuthWelcome {
        subscriptionOwnershipState.invalidate()
        subscribedRadioId = nil
        radioSlot = nil
        audioFreshness.reset()
        state = .connecting
        do {
            let welcome = try await channel.connect(
                server: server,
                credential: credential,
                path: "/ws/media",
                expectedChannel: "media"
            )
            liveness = RadioLiteMediaLivenessState(
                connectedAt: ProcessInfo.processInfo.systemUptime
            )
            state = .ready
            startNetworkReports()
            return welcome
        } catch {
            state = .failed(error.localizedDescription)
            lastError = error.localizedDescription
            throw error
        }
    }

    func subscribe(radioId: String, spectrumVisible: Bool = true) async throws {
        let ownership = subscriptionOwnershipState.begin(radioId: radioId)
        self.spectrumVisible = spectrumVisible
        let response: JSONValue
        do {
            response = try await channel.request(
                .object([
                    "t": .string("media.subscribe"),
                    "radioId": .string(radioId),
                    "spectrumVisible": .bool(spectrumVisible),
                ]),
                expecting: ["media.subscribed"],
                requestType: "media.subscribe"
            )
        } catch {
            guard subscriptionOwnershipState.isCurrent(ownership) else {
                throw CancellationError()
            }
            throw error
        }
        guard subscriptionOwnershipState.isCurrent(ownership) else {
            throw CancellationError()
        }
        guard let slot = response["radioSlot"]?.intValue,
              let policy: RadioLiteMediaPolicy = response["policy"]?.decoded(),
              let spectrumCapability: RadioLiteSpectrumCapability = response["spectrum"]?.decoded(),
              (0...255).contains(slot) else {
            throw RadioLiteSocketError.invalidWelcome
        }
        guard subscriptionOwnershipState.complete(ownership) else {
            throw CancellationError()
        }
        radioSlot = UInt8(slot)
        subscribedRadioId = radioId
        audioFreshness.reset()
        liveness.subscriptionStarted(at: ProcessInfo.processInfo.systemUptime)
        self.policy = policy
        self.spectrumCapability = spectrumCapability
        clearSpectrum(keepingCapability: true)
        audio.setOpusBitrate(policy.opusBitrate)
        if AudioRuntimePolicy.startsMonitoringOnMediaSubscription {
            try audio.startMonitoring()
        }
    }

    func unsubscribe() async {
        subscriptionOwnershipState.invalidate()
        stopUplink()
        audio.stopAll()
        if state == .ready {
            _ = try? await channel.request(
                .object(["t": .string("media.unsubscribe")]),
                expecting: ["media.unsubscribed"],
                requestType: "media.unsubscribe"
            )
        }
        subscribedRadioId = nil
        radioSlot = nil
        audioFreshness.reset()
        liveness.subscriptionEnded()
        clearSpectrum(keepingCapability: false)
    }

    func disconnect() {
        subscriptionOwnershipState.invalidate()
        networkTask?.cancel()
        networkTask = nil
        stopUplink()
        audio.stopAll()
        channel.disconnect()
        state = .disconnected
        subscribedRadioId = nil
        radioSlot = nil
        audioFreshness.reset()
        liveness.subscriptionEnded()
        policy = nil
        clearSpectrum(keepingCapability: false)
    }

    func bindUplink(
        radioId: String,
        transmitToken: String
    ) async throws -> RadioLiteUplinkOwnership {
        stopUplink()
        let ownership = uplinkOwnershipState.begin(transmitToken: transmitToken)
        do {
            _ = try await channel.request(
                .object([
                    "t": .string("media.uplink.bind"),
                    "radioId": .string(radioId),
                    "transmitToken": .string(transmitToken),
                ]),
                expecting: ["media.uplink.bound"],
                requestType: "media.uplink.bind"
            )
            try Task.checkCancellation()
            guard uplinkOwnershipState.complete(ownership) else {
                throw CancellationError()
            }
            isUplinkBound = true
            startUplinkSendLoop(ownership: ownership)
            return ownership
        } catch {
            stopUplink(transmitToken: ownership.transmitToken, epoch: ownership.epoch)
            throw error
        }
    }

    func enqueueMicrophonePacket(_ opus: Data) {
        guard isUplinkBound, let slot = radioSlot, opus.count <= 1_500 else {
            return
        }
        let timestamp = UInt64(max(0, Date().timeIntervalSince1970 * 1_000_000))
        let frame = RadioLiteMediaFrame(
            kind: .audioUplink,
            flags: 0,
            radioSlot: slot,
            sequence: uplinkSequence,
            timestampMicroseconds: timestamp,
            payload: opus
        )
        uplinkSequence &+= 1
        guard let encoded = try? RadioLiteMediaFrameCodec.encode(frame) else { return }
        _ = uplinkContinuation?.yield(encoded)
    }

    @discardableResult
    func stopUplink(transmitToken: String? = nil, epoch: UInt64? = nil) -> Bool {
        let unconditional = transmitToken == nil && epoch == nil
        let stopped = uplinkOwnershipState.stop(transmitToken: transmitToken, epoch: epoch)
        guard stopped || unconditional else { return false }
        isUplinkBound = false
        uplinkSequence = 0
        uplinkContinuation?.finish()
        uplinkContinuation = nil
        uplinkSendTask?.cancel()
        uplinkSendTask = nil
        return stopped
    }

    func setSpectrumVisible(_ visible: Bool) {
        guard spectrumVisible != visible else { return }
        spectrumVisible = visible
        if !visible { clearSpectrum(keepingCapability: true) }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.reportNetwork()
            } catch {
                self.failMediaConnectionIfReady(error)
            }
        }
    }

    private func handle(_ data: Data) {
        liveness.receivedInbound(at: ProcessInfo.processInfo.systemUptime)
        do {
            let frame = try RadioLiteMediaFrameCodec.decode(data)
            if let expectedSlot = radioSlot, frame.radioSlot != expectedSlot { return }
            switch frame.kind {
            case .audioDownlink:
                let receivedAtMicroseconds = UInt64(
                    ProcessInfo.processInfo.systemUptime * 1_000_000
                )
                switch audioFreshness.disposition(
                    timestampMicroseconds: frame.timestampMicroseconds,
                    receivedAtMicroseconds: receivedAtMicroseconds
                ) {
                case .discardAndFlush:
                    audio.discardBufferedPlayback()
                    return
                case .discard:
                    return
                case .accept:
                    break
                }
                if audio.receiveOpusPacket(frame.payload) {
                    liveness.receivedAudio(at: ProcessInfo.processInfo.systemUptime)
                }
            case .spectrum:
                guard spectrumVisible else { return }
                let decoded = try RadioLiteMediaFrameCodec.decodeSpectrum(frame.payload)
                let displayFrame = RadioLiteSpectrumFrame(
                    centerFrequencyHz: decoded.centerFrequencyHz,
                    spanHz: decoded.spanHz,
                    noiseFloorTenthsDBm: decoded.noiseFloorTenthsDBm,
                    bins: spectrumAGC.normalize(decoded.bins)
                )
                spectrum = displayFrame
                spectrumHistoryBuffer.append(displayFrame)
                spectrumHistory = spectrumHistoryBuffer.rows
            case .audioUplink, .statistics:
                break
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func handle(_ value: JSONValue) {
        liveness.receivedInbound(at: ProcessInfo.processInfo.systemUptime)
        switch value["t"]?.stringValue {
        case "media.policy":
            if let policy: RadioLiteMediaPolicy = value["policy"]?.decoded() {
                self.policy = policy
                audio.setOpusBitrate(policy.opusBitrate)
            }
        case "media.uplink.ended":
            let stopped: Bool
            if let transmitToken = value["transmitToken"]?.stringValue {
                stopped = stopUplink(transmitToken: transmitToken)
            } else if isUplinkBound {
                // Compatibility with an older server. Never let its
                // uncorrelated event cancel a replacement that is still binding.
                stopped = stopUplink()
            } else {
                stopped = false
            }
            if stopped { audio.stopMicrophoneCapture() }
        case "media.error":
            let code = value["code"]?.stringValue ?? "media_error"
            let reconnectRequired = value["reconnectRequired"]?.boolValue == true
                || code == "media_worker_failed"
            if let advertised: RadioLiteSpectrumCapability = value["spectrum"]?.decoded() {
                spectrumCapability = advertised
            } else if reconnectRequired {
                spectrumCapability = RadioLiteSpectrumCapability.unavailable(reason: code)
            }
            if reconnectRequired {
                if let advertised: RadioLiteMediaPolicy = value["policy"]?.decoded() {
                    policy = advertised
                } else if let current = policy {
                    policy = RadioLiteMediaPolicy(
                        tier: current.tier,
                        opusBitrate: current.opusBitrate,
                        opusFrameMs: current.opusFrameMs,
                        spectrumBins: 0,
                        spectrumFps: 0
                    )
                }
                clearSpectrum(keepingCapability: true)
            }
            let error = RadioLiteSocketError.command(
                code: code,
                message: value["message"]?.stringValue ?? "媒体通道故障"
            )
            lastError = error.localizedDescription
            let presentation = RadioLiteMediaFailurePresentation.route(
                wasUplinkBound: isUplinkBound,
                reconnectRequired: reconnectRequired
            )
            if isUplinkBound {
                stopUplink()
                audio.stopMicrophoneCapture(resumeMonitoringAfterCapture: false)
            }
            switch presentation {
            case .none:
                break
            case .reconnectBanner:
                onReconnectRequired?(error)
            case .uplinkBanner:
                onUplinkFailure?(error)
            }
        case "pong":
            if let started = pingStartedAt {
                lastRoundTripMs = max(0, Date().timeIntervalSince(started) * 1_000)
                pingStartedAt = nil
            }
        default:
            break
        }
    }

    private func startUplinkSendLoop(ownership: RadioLiteUplinkOwnership) {
        uplinkContinuation?.finish()
        uplinkSendTask?.cancel()
        let stream = AsyncStream<Data>(bufferingPolicy: .bufferingNewest(12)) { continuation in
            uplinkContinuation = continuation
        }
        uplinkSendTask = Task { [weak self] in
            do {
                for await data in stream {
                    try Task.checkCancellation()
                    guard let self, self.uplinkOwnershipState.isBound(ownership) else { return }
                    try await self.channel.send(data)
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                guard self.stopUplink(
                    transmitToken: ownership.transmitToken,
                    epoch: ownership.epoch
                ) else { return }
                self.audio.stopMicrophoneCapture(resumeMonitoringAfterCapture: false)
                self.lastError = error.localizedDescription
                self.onUplinkFailure?(error)
            }
        }
    }

    private func startNetworkReports() {
        networkTask?.cancel()
        networkTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self, self.state == .ready else { return }
                do {
                    self.pingStartedAt = Date()
                    try await self.channel.send(.object(["t": .string("ping")]))
                    try await self.reportNetwork()
                    let failure = self.liveness.failure(
                        at: ProcessInfo.processInfo.systemUptime,
                        monitoringAudio: self.audio.isMonitoring
                            && !self.audio.isCapturingMicrophone
                            && !self.audio.isPlaybackSuspended
                    )
                    if let failure {
                        self.failMediaConnectionIfReady(failure)
                        return
                    }
                } catch {
                    self.failMediaConnectionIfReady(error)
                    return
                }
            }
        }
    }

    private func reportNetwork() async throws {
        guard state == .ready, subscribedRadioId != nil else { return }
        let fallback = lastRoundTripMs > 0 ? lastRoundTripMs : 250
        let report = JSONValue.object(
            ("t", .string("media.network")),
            ("rttMs", .number(fallback)),
            ("packetLossPercent", .number(0)),
            ("bufferedBytes", .number(0)),
            ("spectrumVisible", .bool(spectrumVisible))
        )
        try await channel.send(report)
    }

    private func failMediaConnectionIfReady(_ error: Error) {
        guard state == .ready else { return }
        lastError = error.localizedDescription
        channel.disconnect(notify: true, reason: error)
    }

    private func clearSpectrum(keepingCapability: Bool) {
        spectrum = nil
        spectrumHistoryBuffer.reset()
        spectrumAGC.reset()
        spectrumHistory = []
        if !keepingCapability {
            spectrumCapability = nil
        }
    }
}
