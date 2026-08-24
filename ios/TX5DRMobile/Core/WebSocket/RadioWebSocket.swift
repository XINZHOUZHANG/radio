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
    @Published private(set) var squelch = SquelchStatus(supported: false, open: nil, muted: false, source: "unsupported", updatedAt: 0)
    @Published private(set) var transmitGainDecibels = -10.0
    @Published private(set) var transmissionInterruption: RadioTransmissionInterruption?
    @Published private(set) var meters: MeterData?
    @Published private(set) var decodedFrames: [FrameMessage] = []
    @Published private(set) var spectrumBins: [Double] = []
    @Published private(set) var spectrumHistory: [SpectrumWaterfallRow] = []
    @Published private(set) var spectrumRange: SpectrumFrame.FrequencyRange?
    @Published private(set) var spectrumKind: SpectrumKind?
    @Published private(set) var spectrumCapabilities: SpectrumCapabilities?
    @Published private(set) var selectedSpectrumKind: SpectrumKind?
    @Published private(set) var requestedSpectrumKind: SpectrumKind?
    @Published private(set) var subscribedSpectrumKind: SpectrumKind?
    @Published private(set) var spectrumSubscription: SpectrumSubscriptionChange?
    @Published private(set) var spectrumSessionState: SpectrumSessionState?
    @Published private(set) var spectrumSelectionIsAutomatic = true
    @Published private(set) var openWebRXListenStatus: OpenWebRXListenStatus?
    @Published private(set) var openWebRXProfileRequest: OpenWebRXProfileSelectRequest?
    @Published private(set) var openWebRXProfileVerifyResult: OpenWebRXProfileVerifyResult?
    @Published private(set) var openWebRXClientCount = 0
    @Published private(set) var openWebRXCooldownUntil: Date?
    @Published private(set) var capabilityDescriptors: [CapabilityDescriptor] = []
    @Published private(set) var capabilities: [String: CapabilityState] = [:]
    @Published private(set) var lastNotice: String?
    @Published private(set) var voiceLock: JSONValue?
    @Published private(set) var cwStatus: JSONValue?
    @Published private(set) var cwKeyerStatus: JSONValue?
    @Published private(set) var cwDecoderStatus: JSONValue?
    @Published private(set) var cwDecoder: CWDecoderStatus?
    @Published private(set) var cwDecoderSegments: [CWDecoderTranscriptSegment] = []
    @Published private(set) var cwDecoderPending: CWDecoderPendingSegment?
    @Published private(set) var cwDecoderError: String?
    @Published private(set) var operatorStatuses: [String: JSONValue] = [:]
    @Published private(set) var systemStatus: JSONValue?
    @Published private(set) var rigctldStatus: RigctldStatus?
    @Published private(set) var radioStatus: JSONValue?
    @Published private(set) var audioStatus: JSONValue?
    @Published private(set) var tunerStatus: JSONValue?
    @Published private(set) var radioPowerState: RadioPowerStateEvent?
    @Published private(set) var voiceKeyerStatus: JSONValue?
    @Published private(set) var voiceRadioMode: JSONValue?
    @Published private(set) var pluginList: JSONValue?
    @Published private(set) var pluginSnapshot: TX5DRPluginSystemSnapshot?
    @Published private(set) var pluginPanelData: [String: JSONValue] = [:]
    @Published private(set) var pluginLogs: [TX5DRPluginLogEntry] = []
    @Published private(set) var pluginRuntimeLogs: [TX5DRPluginRuntimeLogEntry] = []
    @Published private(set) var latestEvents: [String: JSONValue] = [:]

    var onLogbookEvent: ((LogbookRealtimeEvent) -> Void)?

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
    private var spectrumHistoryBuffer = SpectrumHistoryBuffer(maxRows: 120)

    init(session: URLSession = TX5DRNetworkPolicy.session) {
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
        if self.server != server {
            resetSpectrumState()
            resetLiveControlState()
            resetPluginState()
            transmissionInterruption = nil
            transmitGainDecibels = -10
        }
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
            let url = try server.webSocketURL("/ws")
            let socket = TX5DRNetworkPolicy.webSocketTask(session: session, url: url)
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
        resetSpectrumState()
        resetLiveControlState()
        resetPluginState()
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

    func applyCWDecoderSnapshot(_ status: CWDecoderStatus) {
        cwDecoder = status
        cwDecoderError = status.lastError
    }

    func clearCWDecoderTranscript() {
        cwDecoderSegments = []
        cwDecoderPending = nil
    }

    func setMode(_ mode: ModeDescriptor) {
        guard let encoded = jsonValue(mode) else { return }
        send("setMode", data: .object(["mode": encoded]))
    }

    func selectSpectrumSource(_ kind: SpectrumKind) {
        guard spectrumCapabilities?.source(for: kind)?.available == true else {
            lastNotice = spectrumCapabilities?.source(for: kind)?.reason ?? "该频谱源当前不可用"
            return
        }
        saveSpectrumPreference(kind)
        spectrumSelectionIsAutomatic = false
        selectedSpectrumKind = kind
        requestSpectrumSubscription(kind)
    }

    func selectAutomaticSpectrumSource() {
        removeSpectrumPreference()
        spectrumSelectionIsAutomatic = true
        guard let spectrumCapabilities,
              let kind = SpectrumSourceSelector.pick(capabilities: spectrumCapabilities, preferred: nil) else {
            selectedSpectrumKind = nil
            requestSpectrumSubscription(nil)
            return
        }
        selectedSpectrumKind = kind
        requestSpectrumSubscription(kind)
    }

    func clearSpectrumHistory() {
        spectrumHistoryBuffer.reset()
        publishSpectrumHistory()
    }

    func respondToOpenWebRXProfileRequest(profileId: String) {
        guard let request = openWebRXProfileRequest else { return }
        openWebRXProfileVerifyResult = nil
        send("openwebrxProfileSelectResponse", data: .object([
            "requestId": .string(request.requestId),
            "profileId": .string(profileId),
            "targetFrequency": .number(request.targetFrequency),
        ]))
    }

    func dismissOpenWebRXProfileRequest() {
        openWebRXProfileRequest = nil
        openWebRXProfileVerifyResult = nil
    }

    func dismissLastNotice() {
        lastNotice = nil
    }

    func clearTransmissionInterruption() {
        transmissionInterruption = nil
    }

    func invokeSpectrumControl(id: SpectrumSessionControlID, action: SpectrumSessionControlAction) {
        send("invokeSpectrumControl", data: .object([
            "id": .string(id.rawValue),
            "action": .string(action.rawValue),
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

    func setOperatorContext(_ context: [String: JSONValue], operatorId: String) {
        send("setOperatorContext", data: .object([
            "operatorId": .string(operatorId),
            "context": .object(context),
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
        let value = AudioGain.clampedDecibels(decibels)
        transmitGainDecibels = value
        send("setVolumeGainDb", data: .object(["gainDb": .number(value)]))
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

    func invokePluginAction(
        pluginName: String,
        actionId: String,
        operatorId: String? = nil,
        payload: JSONValue? = nil
    ) {
        var data: [String: JSONValue] = [
            "pluginName": .string(pluginName),
            "actionId": .string(actionId),
        ]
        if let operatorId { data["operatorId"] = .string(operatorId) }
        if let payload { data["payload"] = payload }
        send("pluginUserAction", data: .object(data))
    }

    func requestPluginRuntimeLogHistory(limit: Int = 500) {
        send("getPluginRuntimeLogHistory", data: .object([
            "limit": .number(Double(min(5_000, max(1, limit)))),
        ]))
    }

    func clearPluginLogs() {
        pluginLogs = []
        pluginRuntimeLogs = []
    }

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
            resetSpectrumState()
            resetLiveControlState()
            resetPluginState()
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
            if let spectrumCapabilities {
                applySpectrumCapabilities(spectrumCapabilities)
            }
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
        case "squelchStatusChanged":
            if let value: SquelchStatus = decode(envelope.data) { squelch = value }
        case "volumeGainChanged":
            applyVolumeGain(envelope.data)
        case "meterData":
            if let value: MeterData = decode(envelope.data) { meters = value }
        case "slotPackUpdated":
            if let pack: SlotPack = decode(envelope.data) { mergeFrames(pack.frames) }
        case "slotPacksReset":
            if envelope.data?["phase"]?.stringValue == "start" { decodedFrames = [] }
        case "spectrumCapabilities":
            if let value: SpectrumCapabilities = decode(envelope.data) {
                applySpectrumCapabilities(value)
            }
        case "spectrumSubscriptionChanged":
            if let value: SpectrumSubscriptionChange = decode(envelope.data) {
                applySpectrumSubscriptionChange(value)
            }
        case "spectrumFrame":
            if let frame: SpectrumFrame = decode(envelope.data) { applySpectrumFrame(frame) }
        case "spectrumSessionStateChanged":
            if let value: SpectrumSessionState = decode(envelope.data) {
                spectrumSessionState = value
            }
        case "openwebrxListenStatus":
            openWebRXListenStatus = decode(envelope.data)
        case "openwebrxProfileSelectRequest":
            openWebRXProfileRequest = decode(envelope.data)
            openWebRXProfileVerifyResult = nil
        case "openwebrxProfileVerifyResult":
            openWebRXProfileVerifyResult = decode(envelope.data)
        case "openwebrxClientCount":
            openWebRXClientCount = envelope.data?["count"]?.intValue ?? 0
        case "openwebrxCooldownNotice":
            let waitMs = envelope.data?["waitMs"]?.doubleValue ?? 0
            openWebRXCooldownUntil = Date().addingTimeInterval(max(0, waitMs) / 1_000)
            lastNotice = "OpenWebRX 正在等待服务器冷却（约 \(Int(ceil(waitMs / 1_000))) 秒）"
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
        case "qsoRecordAdded", "qsoRecordUpdated", "logbookUpdated",
             "logbookHealthChanged", "logbookWriteFailed":
            if let event = LogbookRealtimeEvent(envelope: envelope) {
                onLogbookEvent?(event)
            }
        case "systemStatus":
            systemStatus = envelope.data
            applyVolumeGain(envelope.data)
        case "bootstrapStatusChanged", "clockStatusChanged":
            systemStatus = envelope.data
        case "rigctldStatus":
            rigctldStatus = decode(envelope.data)
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
        case "voiceKeyerStatusChanged":
            voiceKeyerStatus = envelope.data
        case "voiceRadioModeChanged":
            voiceRadioMode = envelope.data
        case "radioDisconnectedDuringTransmission":
            if let interruption: RadioTransmissionInterruption = decode(envelope.data) {
                transmissionInterruption = interruption
                lastNotice = "发射期间电台断开：\(interruption.message) \(interruption.recommendation)"
            }
        case "decodeError":
            let message = envelope.data?["error"]?["message"]?.stringValue ?? "未知解码错误"
            lastNotice = "数字模式解码失败：\(message)"
        case "accessDenied":
            let reason = envelope.data?["reason"]?.stringValue ?? "unknown"
            lastNotice = accessDeniedMessage(reason: reason, data: envelope.data)
        case "cwKeyerStatus":
            cwKeyerStatus = envelope.data
            cwStatus = envelope.data
        case "cwDecoderStatus":
            cwDecoderStatus = envelope.data
            if let status: CWDecoderStatus = decode(envelope.data) { applyCWDecoderSnapshot(status) }
            cwStatus = envelope.data
        case "cwDecoderEvent":
            cwDecoderStatus = envelope.data
            handleCWDecoderEvent(envelope.data)
            cwStatus = envelope.data
        case "pluginList":
            pluginList = envelope.data
            pluginSnapshot = decode(envelope.data)
        case "pluginStatusChanged":
            pluginList = envelope.data
            if let change: TX5DRPluginStatusChange = decode(envelope.data) {
                mergePluginStatus(change)
            }
        case "pluginData":
            if let payload: TX5DRPluginDataPayload = decode(envelope.data) {
                pluginPanelData[payload.key] = payload.data
            }
        case "pluginLog":
            if let entry: TX5DRPluginLogEntry = decode(envelope.data) {
                pluginLogs.append(entry)
                if pluginLogs.count > 500 { pluginLogs.removeFirst(pluginLogs.count - 500) }
            }
        case "pluginRuntimeLog":
            if let entry: TX5DRPluginRuntimeLogEntry = decode(envelope.data) {
                pluginRuntimeLogs.append(entry)
                if pluginRuntimeLogs.count > 500 { pluginRuntimeLogs.removeFirst(pluginRuntimeLogs.count - 500) }
            }
        case "pluginRuntimeLogHistory":
            applyPluginLogHistory(envelope.data)
        case "pluginPanelMeta", "pluginPanelContributionsChanged":
            pluginList = envelope.data
        case "pluginPagePush":
            break
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

    private func mergePluginStatus(_ change: TX5DRPluginStatusChange) {
        guard let snapshot = pluginSnapshot else { return }
        var plugins = snapshot.plugins
        if let index = plugins.firstIndex(where: { $0.name == change.plugin.name }) {
            plugins[index] = change.plugin
        } else {
            plugins.append(change.plugin)
        }
        pluginSnapshot = TX5DRPluginSystemSnapshot(
            state: snapshot.state,
            generation: change.generation,
            plugins: plugins.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            panelMeta: snapshot.panelMeta,
            panelContributions: snapshot.panelContributions,
            lastError: snapshot.lastError
        )
    }

    private func applyPluginLogHistory(_ payload: JSONValue?) {
        guard let entries = payload?["entries"]?.arrayValue else { return }
        var pluginEntries: [TX5DRPluginLogEntry] = []
        var runtimeEntries: [TX5DRPluginRuntimeLogEntry] = []
        for entry in entries {
            if entry["source"]?.stringValue == "system",
               let decoded: TX5DRPluginRuntimeLogEntry = decode(entry) {
                runtimeEntries.append(decoded)
            } else if let decoded: TX5DRPluginLogEntry = decode(entry) {
                pluginEntries.append(decoded)
            }
        }
        pluginLogs = Array(pluginEntries.suffix(500))
        pluginRuntimeLogs = Array(runtimeEntries.suffix(500))
    }

    private func applySpectrumCapabilities(_ value: SpectrumCapabilities) {
        let profileChanged = spectrumCapabilities == nil || spectrumCapabilities?.profileId != value.profileId
        spectrumCapabilities = value

        if profileChanged {
            selectedSpectrumKind = nil
            requestedSpectrumKind = nil
            subscribedSpectrumKind = nil
            spectrumSubscription = nil
            spectrumSessionState = nil
            clearSpectrumHistory()
            spectrumSelectionIsAutomatic = loadSpectrumPreference(profileId: value.profileId) == nil
        }

        let savedPreference = loadSpectrumPreference(profileId: value.profileId)
        let preferred = spectrumSelectionIsAutomatic ? nil : savedPreference
        guard let selected = SpectrumSourceSelector.pick(capabilities: value, preferred: preferred) else {
            selectedSpectrumKind = nil
            if state == .ready { requestSpectrumSubscription(nil) }
            return
        }

        selectedSpectrumKind = selected
        guard state == .ready else { return }
        if spectrumSubscription?.ok == false || selected != requestedSpectrumKind {
            requestSpectrumSubscription(selected)
        }
    }

    private func applySpectrumSubscriptionChange(_ value: SpectrumSubscriptionChange) {
        spectrumSubscription = value
        requestedSpectrumKind = value.requestedKind
        subscribedSpectrumKind = value.effectiveKind

        if value.ok {
            if let effectiveKind = value.effectiveKind {
                selectedSpectrumKind = effectiveKind
            }
        } else {
            requestedSpectrumKind = nil
            lastNotice = spectrumSubscriptionReason(value.reason)
        }

        if spectrumKind != value.effectiveKind {
            clearSpectrumHistory()
        }
        if let capabilities = value.capabilities {
            applySpectrumCapabilities(capabilities)
        }
    }

    private func applySpectrumFrame(_ frame: SpectrumFrame) {
        if let subscribedSpectrumKind, frame.kind != subscribedSpectrumKind { return }
        if subscribedSpectrumKind == nil,
           let selectedSpectrumKind,
           frame.kind != selectedSpectrumKind { return }
        spectrumHistoryBuffer.append(frame: frame)
        publishSpectrumHistory()
    }

    private func publishSpectrumHistory() {
        spectrumBins = spectrumHistoryBuffer.latestBins
        spectrumHistory = spectrumHistoryBuffer.rows
        spectrumRange = spectrumHistoryBuffer.frequencyRange
        spectrumKind = spectrumHistoryBuffer.kind
    }

    private func requestSpectrumSubscription(_ kind: SpectrumKind?) {
        if spectrumKind != kind { clearSpectrumHistory() }
        requestedSpectrumKind = kind
        spectrumSubscription = nil
        send("subscribeSpectrum", data: .object(["kind": kind.map { .string($0.rawValue) } ?? .null]))
    }

    private func resetSpectrumState() {
        spectrumCapabilities = nil
        selectedSpectrumKind = nil
        requestedSpectrumKind = nil
        subscribedSpectrumKind = nil
        spectrumSubscription = nil
        spectrumSessionState = nil
        spectrumSelectionIsAutomatic = true
        clearSpectrumHistory()
        openWebRXListenStatus = nil
        openWebRXProfileRequest = nil
        openWebRXProfileVerifyResult = nil
        openWebRXClientCount = 0
        openWebRXCooldownUntil = nil
    }

    private func resetLiveControlState() {
        ptt = PTTStatus(
            isTransmitting: false,
            operatorIds: [],
            phase: "idle",
            frameId: nil,
            source: nil
        )
        tuneTone = TuneToneStatus(
            active: false,
            toneHz: nil,
            startedAt: nil,
            maxDurationMs: 30_000,
            error: nil
        )
        squelch = SquelchStatus(
            supported: false,
            open: nil,
            muted: false,
            source: "unsupported",
            updatedAt: 0
        )
        meters = nil
        voiceLock = nil
    }

    private func resetPluginState() {
        pluginList = nil
        pluginSnapshot = nil
        pluginPanelData = [:]
    }

    private func applyVolumeGain(_ payload: JSONValue?) {
        if let decibels = AudioGain.decibels(from: payload) {
            transmitGainDecibels = decibels
        }
    }

    private func accessDeniedMessage(reason: String, data: JSONValue?) -> String {
        switch reason {
        case "capacity_reached":
            let current = data?["current"]?.intValue
            let limit = data?["limit"]?.intValue
            if let current, let limit { return "服务器连接数已满（\(current)/\(limit)）" }
            return "服务器连接数已满"
        case "origin_not_allowed": return "服务器拒绝了此客户端来源"
        case "authentication_timeout": return "WebSocket 认证超时"
        case "handshake_timeout": return "客户端握手超时"
        case "ip_limit_reached": return "当前地址的连接数已达到上限"
        default: return "服务器拒绝访问：\(reason)"
        }
    }

    private func spectrumPreferenceKey(profileId: String?) -> String {
        let serverKey = server?.displayAddress ?? "unconfigured"
        return "tx5dr.spectrum.preferred.\(serverKey).\(profileId ?? "default")"
    }

    private func loadSpectrumPreference(profileId: String?) -> SpectrumKind? {
        guard let raw = UserDefaults.standard.string(forKey: spectrumPreferenceKey(profileId: profileId)) else {
            return nil
        }
        return SpectrumKind(rawValue: raw)
    }

    private func saveSpectrumPreference(_ kind: SpectrumKind) {
        UserDefaults.standard.set(kind.rawValue, forKey: spectrumPreferenceKey(profileId: spectrumCapabilities?.profileId))
    }

    private func removeSpectrumPreference() {
        UserDefaults.standard.removeObject(forKey: spectrumPreferenceKey(profileId: spectrumCapabilities?.profileId))
    }

    private func spectrumSubscriptionReason(_ reason: String?) -> String {
        switch reason {
        case "radio_disconnected": "电台未连接，无法启用电台 SDR"
        case "openwebrx_disconnected": "OpenWebRX 未连接"
        case "capabilities_timeout": "读取频谱能力超时"
        case "subscription_failed": "切换频谱源失败"
        case "not_authenticated_or_handshake_pending": "频谱控制通道尚未就绪"
        case .some(let reason): "频谱源不可用：\(reason)"
        case nil: "频谱源不可用"
        }
    }

    private func handleCWDecoderEvent(_ data: JSONValue?) {
        guard let data else { return }
        let kind = data["kind"]?.stringValue ?? data["type"]?.stringValue ?? ""
        switch kind {
        case "status":
            if let status: CWDecoderStatus = decode(data["status"]) { applyCWDecoderSnapshot(status) }
        case "transcript_reset":
            clearCWDecoderTranscript()
        case "transcript_pending":
            cwDecoderPending = decode(data["pending"])
        case "transcript", "transcript_commit":
            if let segment: CWDecoderTranscriptSegment = decode(data["segment"]) {
                mergeCWDecoderSegment(segment)
                cwDecoderPending = nil
            }
        case "commit":
            if let segment: CWDecoderTranscriptSegment = decode(data["segment"]) {
                mergeCWDecoderSegment(segment)
            } else if let text = data["text"]?.stringValue, !text.isEmpty {
                mergeCWDecoderSegment(legacyCWDecoderSegment(text: text, data: data))
            }
            cwDecoderPending = nil
        case "pending", "partial":
            let text = data["text"]?.stringValue
                ?? data["pendingText"]?.stringValue
                ?? data["partial"]?.stringValue
                ?? ""
            cwDecoderPending = legacyCWDecoderPending(text: text, data: data)
        case "error":
            cwDecoderError = data["message"]?.stringValue ?? "CW 解码器错误"
        default:
            break
        }
    }

    private func mergeCWDecoderSegment(_ segment: CWDecoderTranscriptSegment) {
        if let index = cwDecoderSegments.firstIndex(where: { $0.id == segment.id }) {
            cwDecoderSegments[index] = segment
        } else {
            cwDecoderSegments.append(segment)
        }
        cwDecoderSegments.sort {
            if $0.sessionId == $1.sessionId { return $0.sequence < $1.sequence }
            return $0.updatedAt < $1.updatedAt
        }
        if cwDecoderSegments.count > 500 {
            cwDecoderSegments.removeFirst(cwDecoderSegments.count - 500)
        }
    }

    private func legacyCWDecoderSegment(text: String, data: JSONValue) -> CWDecoderTranscriptSegment {
        let timestamp = data["timestamp"]?.doubleValue ?? Date().timeIntervalSince1970 * 1_000
        return CWDecoderTranscriptSegment(
            id: data["id"]?.stringValue ?? "legacy-\(Int(timestamp))-\(cwDecoderSegments.count)",
            sessionId: "legacy",
            sequence: cwDecoderSegments.count,
            text: text,
            plainText: nil,
            finalized: true,
            prependSpace: true,
            confidence: data["confidence"]?.doubleValue,
            targetFreqHz: nil,
            filterWidthHz: nil,
            characterSpans: nil,
            wordSpaceSpans: nil,
            startedAt: nil,
            endedAt: nil,
            updatedAt: timestamp,
            wpm: nil
        )
    }

    private func legacyCWDecoderPending(text: String, data: JSONValue) -> CWDecoderPendingSegment? {
        guard !text.isEmpty else { return nil }
        let timestamp = data["timestamp"]?.doubleValue ?? Date().timeIntervalSince1970 * 1_000
        return CWDecoderPendingSegment(
            sessionId: "legacy",
            version: Int(timestamp),
            text: text,
            plainText: nil,
            finalized: false,
            confidence: data["confidence"]?.doubleValue,
            targetFreqHz: nil,
            filterWidthHz: nil,
            characterSpans: nil,
            wordSpaceSpans: nil,
            updatedAt: timestamp
        )
    }

    private func sendHandshake() {
        send("clientHandshake", data: .object([
            "enabledOperatorIds": enabledOperatorIds.map { .array($0.map(JSONValue.string)) } ?? .null,
            "selectedOperatorId": selectedOperatorId.map(JSONValue.string) ?? .null,
            "clientInstanceId": .string(instanceId),
            "clientVersion": .string("0.1.3-ios"),
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
