import Combine
import Foundation

@MainActor
final class RadioLiteMediaClient: ObservableObject {
    @Published private(set) var state: RadioLiteSocketState = .disconnected
    @Published private(set) var policy: RadioLiteMediaPolicy?
    @Published private(set) var spectrum: RadioLiteSpectrumFrame?
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
    private var boundTransmitToken: String?

    init(audio: RadioLiteAudioEngine? = nil) {
        self.audio = audio ?? RadioLiteAudioEngine()
        channel.onJSON = { [weak self] value in self?.handle(value) }
        channel.onBinary = { [weak self] data in self?.handle(data) }
        channel.onDisconnect = { [weak self] error in
            guard let self else { return }
            self.stopUplink()
            self.audio.stopMicrophoneCapture()
            self.state = .failed(error.localizedDescription)
            self.lastError = error.localizedDescription
            self.networkTask?.cancel()
            self.onDisconnect?(error)
        }
    }

    func connect(server: RadioLiteServer, credential: RadioLiteCredential) async throws -> RadioLiteAuthWelcome {
        state = .connecting
        do {
            let welcome = try await channel.connect(
                server: server,
                credential: credential,
                path: "/ws/media",
                expectedChannel: "media"
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
        self.spectrumVisible = spectrumVisible
        let response = try await channel.request(
            .object([
                "t": .string("media.subscribe"),
                "radioId": .string(radioId),
                "spectrumVisible": .bool(spectrumVisible),
            ]),
            expecting: ["media.subscribed"],
            requestType: "media.subscribe"
        )
        guard let slot = response["radioSlot"]?.intValue,
              let policy: RadioLiteMediaPolicy = response["policy"]?.decoded(),
              (0...255).contains(slot) else {
            throw RadioLiteSocketError.invalidWelcome
        }
        radioSlot = UInt8(slot)
        subscribedRadioId = radioId
        self.policy = policy
        audio.setOpusBitrate(policy.opusBitrate)
        if AudioRuntimePolicy.startsMonitoringOnMediaSubscription {
            try audio.startMonitoring()
        }
    }

    func unsubscribe() async {
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
        spectrum = nil
    }

    func disconnect() {
        networkTask?.cancel()
        networkTask = nil
        stopUplink()
        audio.stopAll()
        channel.disconnect()
        state = .disconnected
        subscribedRadioId = nil
        radioSlot = nil
        policy = nil
        spectrum = nil
    }

    func bindUplink(radioId: String, transmitToken: String) async throws {
        _ = try await channel.request(
            .object([
                "t": .string("media.uplink.bind"),
                "radioId": .string(radioId),
                "transmitToken": .string(transmitToken),
            ]),
            expecting: ["media.uplink.bound"],
            requestType: "media.uplink.bind"
        )
        boundTransmitToken = transmitToken
        isUplinkBound = true
        startUplinkSendLoop()
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

    func stopUplink() {
        isUplinkBound = false
        boundTransmitToken = nil
        uplinkSequence = 0
        uplinkContinuation?.finish()
        uplinkContinuation = nil
        uplinkSendTask?.cancel()
        uplinkSendTask = nil
    }

    func setSpectrumVisible(_ visible: Bool) {
        guard spectrumVisible != visible else { return }
        spectrumVisible = visible
        if !visible { spectrum = nil }
        Task { [weak self] in await self?.reportNetwork() }
    }

    private func handle(_ data: Data) {
        do {
            let frame = try RadioLiteMediaFrameCodec.decode(data)
            if let expectedSlot = radioSlot, frame.radioSlot != expectedSlot { return }
            switch frame.kind {
            case .audioDownlink:
                audio.receiveOpusPacket(frame.payload)
            case .spectrum:
                guard spectrumVisible else { return }
                spectrum = try RadioLiteMediaFrameCodec.decodeSpectrum(frame.payload)
            case .audioUplink, .statistics:
                break
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func handle(_ value: JSONValue) {
        switch value["t"]?.stringValue {
        case "media.policy":
            if let policy: RadioLiteMediaPolicy = value["policy"]?.decoded() {
                self.policy = policy
                audio.setOpusBitrate(policy.opusBitrate)
            }
        case "media.uplink.ended":
            stopUplink()
            audio.stopMicrophoneCapture()
        case "media.error":
            let error = RadioLiteSocketError.command(
                code: value["code"]?.stringValue ?? "media_error",
                message: value["message"]?.stringValue ?? "媒体通道故障"
            )
            lastError = error.localizedDescription
            if isUplinkBound {
                stopUplink()
                audio.stopMicrophoneCapture()
                onUplinkFailure?(error)
            }
            if value["reconnectRequired"]?.boolValue == true {
                onReconnectRequired?(error)
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

    private func startUplinkSendLoop() {
        uplinkContinuation?.finish()
        uplinkSendTask?.cancel()
        let stream = AsyncStream<Data>(bufferingPolicy: .bufferingNewest(12)) { continuation in
            uplinkContinuation = continuation
        }
        uplinkSendTask = Task { [weak self] in
            do {
                for await data in stream {
                    try Task.checkCancellation()
                    guard let self, self.isUplinkBound else { return }
                    try await self.channel.send(data)
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.stopUplink()
                self.audio.stopMicrophoneCapture()
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
                self.pingStartedAt = Date()
                try? await self.channel.send(.object(["t": .string("ping")]))
                await self.reportNetwork()
            }
        }
    }

    private func reportNetwork() async {
        guard state == .ready, subscribedRadioId != nil else { return }
        let fallback = lastRoundTripMs > 0 ? lastRoundTripMs : 250
        let report = JSONValue.object(
            ("t", .string("media.network")),
            ("rttMs", .number(fallback)),
            ("packetLossPercent", .number(0)),
            ("bufferedBytes", .number(0)),
            ("spectrumVisible", .bool(spectrumVisible))
        )
        try? await channel.send(report)
    }
}
