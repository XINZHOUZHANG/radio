import Combine
import Foundation

enum RadioSocketState: Equatable {
    case disconnected
    case connecting
    case authenticating
    case handshaking
    case ready
    case failed(String)

    var label: String {
        switch self {
        case .disconnected: "离线"
        case .connecting: "连接中"
        case .authenticating: "认证中"
        case .handshaking: "同步中"
        case .ready: "在线"
        case .failed: "故障"
        }
    }
}

struct WSInboundEnvelope: Decodable {
    let type: String
    let timestamp: String?
    let id: String?
    let data: JSONValue?
}

struct WSOutboundEnvelope: Encodable {
    let type: String
    let timestamp: String
    let id: String?
    let data: JSONValue?
}

@MainActor
final class RadioWebSocket: ObservableObject {
    @Published private(set) var state: RadioSocketState = .disconnected
    @Published private(set) var currentMode: ModeDescriptor = .ft8
    @Published private(set) var frequency: FrequencyState?
    @Published private(set) var ptt = PTTStatus(isTransmitting: false, operatorIds: [], phase: "idle", frameId: nil, source: nil)
    @Published private(set) var tuneTone = TuneToneStatus(active: false, toneHz: nil, startedAt: nil, maxDurationMs: 30_000, error: nil)
    @Published private(set) var meters: MeterData?
    @Published private(set) var decodedFrames: [FrameMessage] = []
    @Published private(set) var spectrumBins: [Double] = []
    @Published private(set) var spectrumRange: SpectrumFrame.FrequencyRange?
    @Published private(set) var capabilityDescriptors: [CapabilityDescriptor] = []
    @Published private(set) var capabilities: [String: CapabilityState] = [:]
    @Published private(set) var lastNotice: String?
    @Published private(set) var voiceLock: JSONValue?
    @Published private(set) var cwStatus: JSONValue?
    @Published private(set) var operatorStatuses: [String: JSONValue] = [:]
    @Published private(set) var systemStatus: JSONValue?
    @Published private(set) var radioStatus: JSONValue?
    @Published private(set) var audioStatus: JSONValue?
    @Published private(set) var tunerStatus: JSONValue?
    @Published private(set) var radioPowerState: RadioPowerStateEvent?
    @Published private(set) var voiceKeyerStatus: JSONValue?
    @Published private(set) var pluginList: JSONValue?
    @Published private(set) var latestEvents: [String: JSONValue] = [:]

    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var server: TX5DRServer?
    private var jwt: String?
    private var enabledOperatorIds: [String]?
    private var selectedOperatorId: String?
    private var reconnectAttempt = 0
    private var shouldReconnect = false
    private let instanceId: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(session: URLSession = .shared) {
        self.session = session
        let key = "tx5dr.clientInstanceId"
        if let existing = UserDefaults.standard.string(forKey: key) {
            instanceId = existing
        } else {
            let created = UUID().uuidString.lowercased()
            UserDefaults.standard.set(created, forKey: key)
            instanceId = created
        }
    }

    func configure(server: TX5DRServer, jwt: String, operatorIds: [String]?, selectedOperatorId: String?) {
        self.server = server
        self.jwt = jwt
        enabledOperatorIds = operatorIds
        self.selectedOperatorId = selectedOperatorId
    }

    func connect() {
        guard let server, task == nil else { return }
        shouldReconnect = true
        reconnectTask?.cancel()
        do {
            let socket = session.webSocketTask(with: try server.webSocketURL("/ws"))
            task = socket
            state = .connecting
            socket.resume()
            state = .authenticating
            receiveTask = Task { [weak self] in await self?.receiveLoop(socket) }
            heartbeatTask = Task { [weak self] in await self?.heartbeatLoop(socket) }
        } catch {
            state = .failed(error.localizedDescription)
            scheduleReconnect()
        }
    }

    func disconnect() {
        shouldReconnect = false
        reconnectAttempt = 0
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        state = .disconnected
    }

    func setSelectedOperator(_ id: String?) {
        selectedOperatorId = id
        send("setClientSelectedOperator", data: .object(["selectedOperatorId": id.map(JSONValue.string) ?? .null]))
    }

    func setEnabledOperators(_ ids: [String]?) {
        enabledOperatorIds = ids
        send("setClientEnabledOperators", data: .object([
            "enabledOperatorIds": ids.map { .array($0.map(JSONValue.string)) } ?? .null,
        ]))
    }

    func startEngine() { send("startEngine") }
    func stopEngine() { send("stopEngine") }
    func forceStopTransmission() { send("forceStopTransmission") }
    func retryAudio() { send("audioRetryNow") }
    func refreshCapabilities() { send("refreshRadioCapabilities") }
    func clearDecodedFrames() { decodedFrames = [] }

    func setMode(_ mode: ModeDescriptor) {
        guard let encoded = jsonValue(mode) else { return }
        send("setMode", data: .object(["mode": encoded]))
    }

    func subscribeSpectrum(kind: String?) {
        send("subscribeSpectrum", data: .object(["kind": kind.map(JSONValue.string) ?? .null]))
    }

    func invokeSpectrumControl(id: String, action: String) {
        send("invokeSpectrumControl", data: .object([
            "id": .string(id),
            "action": .string(action),
        ]))
    }

    func writeCapability(id: String, value: JSONValue? = nil, action: Bool? = nil) {
        var payload: [String: JSONValue] = ["id": .string(id)]
        if let value { payload["value"] = value }
        if let action { payload["action"] = .bool(action) }
        send("writeRadioCapability", data: .object(payload))
    }

    func requestVoicePTT(audioClientId: String, operatorId: String?) {
        var payload: [String: JSONValue] = ["voiceAudioClientId": .string(audioClientId)]
        if let operatorId { payload["operatorId"] = .string(operatorId) }
        send("voicePttRequest", data: .object(payload))
    }

    func releaseVoicePTT() { send("voicePttRelease") }
    func setVoiceRadioMode(_ mode: String) { send("voiceSetRadioMode", data: .object(["radioMode": .string(mode)])) }
    func startTuneTone(operatorId: String?, toneHz: Double = 1_000) {
        var payload: [String: JSONValue] = ["toneHz": .number(toneHz)]
        if let operatorId { payload["operatorId"] = .string(operatorId) }
        send("startTuneTone", data: .object(payload))
    }
    func stopTuneTone() { send("stopTuneTone") }

    func requestCall(operatorId: String, callsign: String) {
        send("operatorRequestCall", data: .object([
            "operatorId": .string(operatorId),
            "callsign": .string(callsign.uppercased()),
        ]))
    }

    func startOperator(_ operatorId: String) {
        send("startOperator", data: .object(["operatorId": .string(operatorId)]))
    }

    func stopOperator(_ operatorId: String) {
        send("stopOperator", data: .object(["operatorId": .string(operatorId)]))
    }

    func setOperatorTransmitCycles(_ cycles: [Double], operatorId: String) {
        send("setOperatorTransmitCycles", data: .object([
            "operatorId": .string(operatorId),
            "transmitCycles": .array(cycles.map(JSONValue.number)),
        ]))
    }

    func setOperatorRuntimeState(_ state: String, operatorId: String) {
        send("setOperatorRuntimeState", data: .object([
            "operatorId": .string(operatorId),
            "state": .string(state),
        ]))
    }

    func setOperatorRuntimeSlotContent(_ content: String, slot: String, operatorId: String) {
        send("setOperatorRuntimeSlotContent", data: .object([
            "operatorId": .string(operatorId),
            "slot": .string(slot),
            "content": .string(content),
        ]))
    }

    func enqueueOperatorTarget(_ callsign: String, operatorId: String, startIfIdle: Bool = true) {
        send("operatorQueueEnqueue", data: .object([
            "operatorId": .string(operatorId),
            "callsign": .string(callsign.uppercased()),
            "startIfIdle": .bool(startIfIdle),
        ]))
    }

    func reorderOperatorTarget(operatorId: String, entryId: String, beforeEntryId: String?, version: Int) {
        send("operatorQueueReorder", data: .object([
            "operatorId": .string(operatorId),
            "entryId": .string(entryId),
            "beforeEntryId": beforeEntryId.map(JSONValue.string) ?? .null,
            "expectedVersion": .number(Double(version)),
        ]))
    }

    func retryOperatorTarget(operatorId: String, entryId: String, version: Int) {
        send("operatorQueueRetry", data: .object([
            "operatorId": .string(operatorId),
            "entryId": .string(entryId),
            "expectedVersion": .number(Double(version)),
        ]))
    }

    func removeOperatorTarget(operatorId: String, entryId: String, version: Int) {
        send("operatorQueueRemove", data: .object([
            "operatorId": .string(operatorId),
            "entryId": .string(entryId),
            "expectedVersion": .number(Double(version)),
        ]))
    }

    func clearOperatorQueue(operatorId: String, version: Int) {
        send("operatorQueueClear", data: .object([
            "operatorId": .string(operatorId),
            "expectedVersion": .number(Double(version)),
        ]))
    }

    func removeOperatorFromTransmission(_ operatorId: String) {
        send("removeOperatorFromTransmission", data: .object(["operatorId": .string(operatorId)]))
    }

    func setVolumeGain(decibels: Double) {
        send("setVolumeGainDb", data: .object(["gainDb": .number(decibels)]))
    }

    func setSplitFrequency(_ transmitFrequency: Double) {
        send("setSplitFrequency", data: .object(["txFrequency": .number(transmitFrequency)]))
    }

    func reconnectRadio() { send("radioManualReconnect") }
    func stopRadioReconnect() { send("radioStopReconnect") }

    func playVoiceKeyer(callsign: String, slotId: String, repeatPlayback: Bool = false, operatorId: String? = nil) {
        var payload: [String: JSONValue] = [
            "callsign": .string(callsign),
            "slotId": .string(slotId),
            "repeat": .bool(repeatPlayback),
            "startImmediately": .bool(true),
        ]
        if let operatorId { payload["operatorId"] = .string(operatorId) }
        send("voiceKeyerPlay", data: .object(payload))
    }

    func stopVoiceKeyer() { send("voiceKeyerStop") }

    func sendCWText(_ text: String, operatorId: String, callsign: String? = nil) {
        var payload: [String: JSONValue] = ["text": .string(text), "operatorId": .string(operatorId)]
        if let callsign { payload["callsign"] = .string(callsign) }
        send("cwTextInput", data: .object(payload))
    }

    func setCWKey(down: Bool, operatorId: String) {
        send("cwKeyAction", data: .object([
            "action": .string(down ? "key-down" : "key-up"),
            "operatorId": .string(operatorId),
        ]))
    }

    func playCWMessage(callsign: String, slotId: String, repeatPlayback: Bool = false, operatorId: String) {
        let payload: [String: JSONValue] = [
            "callsign": .string(callsign),
            "slotId": .string(slotId),
            "operatorId": .string(operatorId),
            "repeat": .bool(repeatPlayback),
            "startImmediately": .bool(true),
        ]
        send("cwPlayMessage", data: .object(payload))
    }

    func stopCWMessage() { send("cwStopMessage") }

    /// Escape hatch for TX-5DR commands added after this app version. Authentication
    /// and the server handshake are still enforced before a command is emitted.
    func sendCommand(_ type: String, data: JSONValue? = nil, id: String? = nil) {
        guard state == .ready else {
            lastNotice = "控制通道尚未就绪"
            return
        }
        send(type, data: data, id: id)
    }

    private func receiveLoop(_ socket: URLSessionWebSocketTask) async {
        do {
            while !Task.isCancelled {
                let message = try await socket.receive()
                switch message {
                case .string(let text):
                    guard let data = text.data(using: .utf8) else { continue }
                    try await handle(decoder.decode(WSInboundEnvelope.self, from: data))
                case .data(let data):
                    try await handle(decoder.decode(WSInboundEnvelope.self, from: data))
                @unknown default:
                    continue
                }
            }
        } catch {
            guard task === socket else { return }
            task = nil
            receiveTask = nil
            heartbeatTask?.cancel()
            heartbeatTask = nil
            if shouldReconnect {
                state = .failed(error.localizedDescription)
                scheduleReconnect()
            } else {
                state = .disconnected
            }
        }
    }

    private func heartbeatLoop(_ socket: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(25))
            guard task === socket, !Task.isCancelled else { return }
            send("ping")
        }
    }

    private func handle(_ envelope: WSInboundEnvelope) async throws {
        if let data = envelope.data {
            latestEvents[envelope.type] = data
        }
        switch envelope.type {
        case "authRequired":
            guard let jwt else {
                state = .failed("缺少登录凭据")
                return
            }
            send("authToken", data: .object(["jwt": .string(jwt)]))
        case "authResult":
            guard envelope.data?["success"]?.boolValue == true else {
                state = .failed(envelope.data?["error"]?.stringValue ?? "认证失败")
                return
            }
            state = .handshaking
            sendHandshake()
        case "serverHandshakeComplete":
            reconnectAttempt = 0
            state = .ready
            send("getStatus")
            send("getOperators")
            subscribeSpectrum(kind: "audio")
        case "authExpired":
            state = .failed("登录已过期，请重新登录")
            shouldReconnect = false
            task?.cancel(with: .policyViolation, reason: nil)
        case "connectionReplaced":
            state = .failed("此设备连接已被新的会话替换")
            shouldReconnect = false
        case "modeChanged":
            if let mode: ModeDescriptor = decode(envelope.data) { currentMode = mode }
        case "frequencyChanged":
            if let value: FrequencyState = decode(envelope.data) { frequency = value }
        case "pttStatusChanged":
            if let value: PTTStatus = decode(envelope.data) { ptt = value }
        case "tuneToneStatusChanged":
            if let value: TuneToneStatus = decode(envelope.data) { tuneTone = value }
        case "meterData":
            if let value: MeterData = decode(envelope.data) { meters = value }
        case "slotPackUpdated":
            if let pack: SlotPack = decode(envelope.data) { mergeFrames(pack.frames) }
        case "slotPacksReset":
            if envelope.data?["phase"]?.stringValue == "start" { decodedFrames = [] }
        case "spectrumFrame":
            if let frame: SpectrumFrame = decode(envelope.data) {
                spectrumBins = frame.normalizedBins
                spectrumRange = frame.frequencyRange
            }
        case "radioCapabilityList":
            if let list: CapabilityList = decode(envelope.data) {
                capabilityDescriptors = list.descriptors
                capabilities = Dictionary(uniqueKeysWithValues: list.capabilities.map { ($0.id, $0) })
            }
        case "radioCapabilityChanged":
            if let value: CapabilityState = decode(envelope.data) { capabilities[value.id] = value }
        case "operatorStatusUpdate":
            if let id = envelope.data?["id"]?.stringValue ?? envelope.data?["operatorId"]?.stringValue,
               let data = envelope.data {
                operatorStatuses[id] = data
            }
        case "operatorsList":
            if let values = envelope.data?["operators"]?.arrayValue {
                operatorStatuses = Dictionary(uniqueKeysWithValues: values.compactMap { value in
                    let id = value["id"]?.stringValue ?? value["operatorId"]?.stringValue
                    return id.map { ($0, value) }
                })
            }
        case "systemStatus", "bootstrapStatusChanged", "clockStatusChanged", "rigctldStatus":
            systemStatus = envelope.data
        case "radioPowerState":
            radioPowerState = decode(envelope.data)
            radioStatus = envelope.data
        case "radioStatusChanged", "profileChanged", "profileListUpdated":
            radioStatus = envelope.data
        case "audioSidecarStatusChanged":
            audioStatus = envelope.data
        case "tunerStatusChanged":
            tunerStatus = envelope.data
        case "voicePttLockChanged":
            voiceLock = envelope.data
        case "voiceKeyerStatusChanged", "voiceRadioModeChanged":
            voiceKeyerStatus = envelope.data
        case "cwKeyerStatus", "cwDecoderStatus", "cwDecoderEvent":
            cwStatus = envelope.data
        case "pluginList", "pluginStatusChanged", "pluginPanelMeta", "pluginPanelContributionsChanged":
            pluginList = envelope.data
        case "textMessage", "error", "radioError":
            lastNotice = envelope.data?["text"]?.stringValue
                ?? envelope.data?["message"]?.stringValue
                ?? envelope.data?["userMessage"]?.stringValue
                ?? envelope.type
        default:
            break
        }
    }

    private func mergeFrames(_ newFrames: [FrameMessage]) {
        var merged = newFrames + decodedFrames
        var seen = Set<String>()
        merged = merged.filter { seen.insert($0.id).inserted }
        decodedFrames = Array(merged.prefix(200))
    }

    private func sendHandshake() {
        send("clientHandshake", data: .object([
            "enabledOperatorIds": enabledOperatorIds.map { .array($0.map(JSONValue.string)) } ?? .null,
            "selectedOperatorId": selectedOperatorId.map(JSONValue.string) ?? .null,
            "clientInstanceId": .string(instanceId),
            "clientVersion": .string("0.1.0-ios"),
            "clientCapabilities": .array([
                .string("operatorFiltering"),
                .string("handshakeProtocol"),
                .string("selectedOperatorScopedAnalysis"),
            ]),
        ]))
    }

    private func send(_ type: String, data: JSONValue? = nil, id: String? = nil) {
        guard let task else { return }
        let envelope = WSOutboundEnvelope(
            type: type,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            id: id,
            data: data
        )
        guard let encoded = try? encoder.encode(envelope), let text = String(data: encoded, encoding: .utf8) else { return }
        Task { try? await task.send(.string(text)) }
    }

    private func jsonValue<Value: Encodable>(_ value: Value) -> JSONValue? {
        guard let data = try? encoder.encode(value) else { return nil }
        return try? decoder.decode(JSONValue.self, from: data)
    }

    private func decode<Value: Decodable>(_ value: JSONValue?) -> Value? {
        guard let value, let data = try? encoder.encode(value) else { return nil }
        return try? decoder.decode(Value.self, from: data)
    }

    private func scheduleReconnect() {
        guard shouldReconnect, reconnectTask == nil else { return }
        reconnectAttempt += 1
        let delay = min(pow(2, Double(reconnectAttempt - 1)), 8)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            self.connect()
        }
    }
}
