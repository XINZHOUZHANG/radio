import Combine
import Foundation
import UIKit

enum RadioLiteSessionPhase: Equatable {
    case launching
    case signedOut
    case authenticating
    case ready
    case failed(String)
}

enum RadioLiteSessionError: LocalizedError {
    case notConnected
    case radioUnavailable
    case controlRequired
    case transmitNotAllowed
    case invalidFrequency
    case rigControlUnavailable
    case invalidRigControlValue
    case rigControlLocked(String)
    case administratorRequired

    var errorDescription: String? {
        switch self {
        case .notConnected: "尚未连接 Radio Lite 服务器"
        case .radioUnavailable: "没有可用电台"
        case .controlRequired: "请先取得电台控制权"
        case .transmitNotAllowed: "当前账户或电台不允许发射"
        case .invalidFrequency: "请输入有效频率"
        case .rigControlUnavailable: "该 Hamlib 控件当前不可用"
        case .invalidRigControlValue: "控件数值超出电台允许范围"
        case .rigControlLocked(let reason): reason
        case .administratorRequired: "此操作需要管理员账户"
        }
    }
}

@MainActor
final class RadioLiteSession: ObservableObject {
    @Published private(set) var phase: RadioLiteSessionPhase = .launching
    @Published var serverAddress: String
    @Published private(set) var loginServerReachable = false
    @Published private(set) var setupRequired = false
    @Published private(set) var principal: RadioLitePrincipal?
    @Published private(set) var username: String?
    @Published private(set) var radios: [RadioLiteRadioProfile] = []
    @Published private(set) var selectedRadioId: String?
    @Published private(set) var controlToken: String?
    @Published private(set) var controlExpiresAtMs: Int64?
    @Published private(set) var rigState: RadioLiteRigState?
    @Published private(set) var rigControls: [RadioLiteRigControl] = []
    @Published private(set) var decodeBatches: [RadioLiteDigitalDecodeBatch] = []
    @Published private(set) var callQueue: RadioLiteCallQueueSnapshot?
    @Published private(set) var automaticQSO: RadioLiteAutoQSO?
    @Published private(set) var qsos: [RadioLiteQSORecord] = []
    @Published private(set) var qsoTotal = 0
    @Published private(set) var grids: [RadioLiteGridSummary] = []
    @Published private(set) var users: [RadioLiteUser] = []
    @Published private(set) var issuedPairingCode: RadioLiteIssuedCode?
    @Published private(set) var isVoicePTTHeld = false
    @Published private(set) var isTuning = false
    @Published private(set) var isWorking = false
    @Published private(set) var digitalActionStatus: String?
    @Published var errorMessage: String?
    @Published private(set) var noticeMessage: String?

    let control = RadioLiteControlClient()
    let media: RadioLiteMediaClient
    let audio: RadioLiteAudioEngine

    private let credentialStore = RadioLiteCredentialStore()
    private var server: RadioLiteServer?
    private var credential: RadioLiteCredential?
    private var http: RadioLiteHTTPClient?
    private var intentionalDisconnect = false
    private var controlHeartbeatTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var transmitHeartbeatTask: Task<Void, Never>?
    private var credentialRefreshTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var mediaRetryTask: Task<Void, Never>?
    private var voicePTTStartupTask: Task<Void, Never>?
    private var tuningStartupTask: Task<Void, Never>?
    private var receiveAudioStartupTask: Task<Void, Never>?
    private var activeTransmitToken: String?
    private var activeCaptureOwnership: RadioLiteMicrophoneCaptureOwnership?
    private var activeUplinkOwnership: RadioLiteUplinkOwnership?
    private var transmitEpoch = RadioLiteOperationEpoch()
    private var receiveAudioEpoch = RadioLiteOperationEpoch()
    private var noticeState = RadioLiteNoticeState()

    private static let addressDefaultsKey = "radio-lite.server-address"
    private static let radioDefaultsKey = "radio-lite.selected-radio"

    init() {
        let audio = RadioLiteAudioEngine()
        self.audio = audio
        self.media = RadioLiteMediaClient(audio: audio)
        self.serverAddress = UserDefaults.standard.string(forKey: Self.addressDefaultsKey)
            ?? "http://localhost:8787"

        control.onEvent = { [weak self] value in self?.handleControlEvent(value) }
        control.onDisconnect = { [weak self] error in self?.handleConnectionLoss(error) }
        media.onDisconnect = { [weak self] error in self?.handleConnectionLoss(error) }
        media.onUplinkFailure = { [weak self] error in
            guard let self else { return }
            self.endVoicePTT()
            self.presentMediaNotice(error)
        }
        media.onReconnectRequired = { [weak self] error in
            guard let self, !self.intentionalDisconnect, self.phase == .ready else { return }
            if self.isVoicePTTHeld { self.endVoicePTT() }
            self.presentMediaNotice(error)
            self.scheduleMediaRetry()
        }
    }

    var isAuthenticated: Bool { phase == .ready }
    var hasControl: Bool { controlToken != nil }
    var isAdmin: Bool { principal?.role == .admin }
    var canTransmit: Bool {
        principal?.canTransmit == true && (selectedRadio?.hardwareTxEnabled == true || selectedRadio?.hamlibModelId == 1)
    }
    var selectedRadio: RadioLiteRadioProfile? {
        guard let selectedRadioId else { return nil }
        return radios.first { $0.id == selectedRadioId }
    }
    var displayIdentity: String {
        username ?? selectedRadio?.station.callsign ?? principal?.userId ?? "操作员"
    }

    func dismissNotice() {
        noticeState.dismiss()
        noticeMessage = noticeState.message
    }

    func probeServer() async {
        do {
            let server = try RadioLiteServer(address: serverAddress)
            let client = RadioLiteHTTPClient(server: server)
            async let health = client.health()
            async let setup = client.setupStatus()
            let (healthValue, setupValue) = try await (health, setup)
            guard healthValue.service == "radio-lite", healthValue.protocolVersion == 1 else {
                throw RadioLiteHTTPError.invalidResponse
            }
            loginServerReachable = true
            setupRequired = setupValue.initializationRequired
        } catch {
            loginServerReachable = false
            setupRequired = false
        }
    }

    func restoreSession() async {
        phase = .launching
        errorMessage = nil
        do {
            guard var stored = try credentialStore.load() else {
                phase = .signedOut
                return
            }
            serverAddress = stored.serverAddress
            var parsedServer = try RadioLiteServer(address: stored.serverAddress)
            var restoredCredential = stored.credential
            var restoredUsername = stored.username
            if case .device(let device) = restoredCredential,
               device.accessExpiresAtMs <= nowMs() + 30_000 {
                guard device.refreshExpiresAtMs > nowMs() else {
                    throw RadioLiteHTTPError.http(status: 401, code: "refresh_expired", message: "设备配对已过期，请重新配对")
                }
                let refreshed = try await RadioLiteHTTPClient(server: parsedServer).refreshDevice(device)
                restoredCredential = .device(refreshed)
                stored = RadioLiteStoredLogin(
                    serverAddress: parsedServer.displayAddress,
                    credential: restoredCredential,
                    username: restoredUsername
                )
                try credentialStore.save(stored)
            } else if case .browser = restoredCredential {
                let restored = try await RadioLiteHTTPClient(
                    server: parsedServer,
                    credential: restoredCredential
                ).currentSession()
                restoredCredential = restored.credential
                restoredUsername = restored.user.username
                parsedServer = try RadioLiteServer(address: stored.serverAddress)
            }
            try await finishAuthentication(
                server: parsedServer,
                credential: restoredCredential,
                username: restoredUsername
            )
        } catch {
            try? credentialStore.delete()
            phase = .signedOut
            errorMessage = "登录恢复失败：\(error.localizedDescription)"
        }
    }

    func initializeServer(setupCode: String, username: String, password: String) async {
        await authenticate {
            let server = try RadioLiteServer(address: self.serverAddress)
            let client = RadioLiteHTTPClient(server: server)
            _ = try await client.initialize(setupCode: setupCode, username: username, password: password)
            let login = try await client.login(username: username, password: password)
            try await self.persistAndFinish(server: server, credential: login.credential, username: login.user.username)
        }
    }

    func login(username: String, password: String) async {
        await authenticate {
            let server = try RadioLiteServer(address: self.serverAddress)
            let login = try await RadioLiteHTTPClient(server: server).login(
                username: username,
                password: password
            )
            try await self.persistAndFinish(server: server, credential: login.credential, username: login.user.username)
        }
    }

    func login(pairingCode: String) async {
        await authenticate {
            let code = pairingCode.filter(\.isNumber)
            guard code.count == 6 else {
                throw RadioLiteHTTPError.http(status: 400, code: "invalid_code", message: "配对码必须是 6 位数字")
            }
            let server = try RadioLiteServer(address: self.serverAddress)
            let credentials = try await RadioLiteHTTPClient(server: server).redeemPairingCode(
                code,
                deviceName: UIDevice.current.name
            )
            try await self.persistAndFinish(server: server, credential: .device(credentials), username: nil)
        }
    }

    func logout() {
        intentionalDisconnect = true
        endVoicePTT()
        endTuning()
        cancelRuntimeTasks()
        let logoutClient = http
        if case .browser = credential {
            Task { try? await logoutClient?.logout() }
        }
        control.disconnect()
        media.disconnect()
        try? credentialStore.delete()
        server = nil
        credential = nil
        http = nil
        principal = nil
        username = nil
        radios = []
        selectedRadioId = nil
        controlToken = nil
        controlExpiresAtMs = nil
        rigState = nil
        rigControls = []
        decodeBatches = []
        callQueue = nil
        automaticQSO = nil
        qsos = []
        qsoTotal = 0
        grids = []
        users = []
        issuedPairingCode = nil
        resetNotices()
        phase = .signedOut
        intentionalDisconnect = false
    }

    func acquireControl(force: Bool = false) async throws {
        guard let radioId = selectedRadioId else { throw RadioLiteSessionError.radioUnavailable }
        var fields: [String: JSONValue] = [
            "t": .string("control.acquire"),
            "radioId": .string(radioId),
        ]
        if force { fields["force"] = .bool(true) }
        let reply = try await control.request(.object(fields), expecting: ["control.acquired"])
        guard let token = reply["controlToken"]?.stringValue else {
            throw RadioLiteSocketError.invalidWelcome
        }
        controlToken = token
        controlExpiresAtMs = reply["expiresAtMs"]?.int64Value
        startControlHeartbeat()
    }

    func releaseControl() async {
        endVoicePTT()
        endTuning()
        guard let radioId = selectedRadioId, let token = controlToken else { return }
        controlHeartbeatTask?.cancel()
        controlHeartbeatTask = nil
        _ = try? await control.request(
            .object([
                "t": .string("control.release"),
                "radioId": .string(radioId),
                "controlToken": .string(token),
            ]),
            expecting: ["control.released"]
        )
        controlToken = nil
        controlExpiresAtMs = nil
    }

    func selectRadio(_ radioId: String) async {
        guard radioId != selectedRadioId, radios.contains(where: { $0.id == radioId }) else { return }
        isWorking = true
        defer { isWorking = false }
        endVoicePTT()
        endTuning()
        stopReceiveAudio()
        await releaseControl()
        await media.unsubscribe()
        selectedRadioId = radioId
        UserDefaults.standard.set(radioId, forKey: Self.radioDefaultsKey)
        clearRadioState()
        var mediaReady = true
        do {
            do {
                try await media.subscribe(radioId: radioId)
                resolveMediaNotices()
            } catch {
                mediaReady = false
                presentMediaNotice(error)
            }
            do {
                try await acquireControl()
            } catch {
                presentNotice("电台当前由其他操作员控制，可稍后接管")
            }
            try await refreshRigState()
            try? await refreshRigControls()
            try await refreshDigitalSnapshot()
        } catch {
            errorMessage = error.localizedDescription
        }
        if !mediaReady {
            scheduleMediaRetry()
        }
    }

    func setFrequency(mhzText: String) async {
        let normalized = mhzText.replacingOccurrences(of: ",", with: ".")
        guard let mhz = Double(normalized), mhz.isFinite, mhz > 0 else {
            errorMessage = RadioLiteSessionError.invalidFrequency.localizedDescription
            return
        }
        await setFrequency(hz: Int64((mhz * 1_000_000).rounded()))
    }

    func setFrequency(hz: Int64) async {
        await performControlCommand { radioId, token in
            guard (100_000...9_000_000_000).contains(hz) else { throw RadioLiteSessionError.invalidFrequency }
            let commandId = UUID().uuidString
            let reply = try await self.control.request(
                .object([
                    "t": .string("rig.frequency.set"),
                    "radioId": .string(radioId),
                    "controlToken": .string(token),
                    "frequencyHz": .number(Double(hz)),
                    "commandId": .string(commandId),
                ]),
                expecting: ["rig.frequency.confirmed"],
                commandId: commandId
            )
            if let frequency = reply["frequencyHz"]?.int64Value {
                self.replaceRigState(frequencyHz: frequency)
            }
        }
    }

    func setMode(_ mode: RadioLiteRigMode, passbandHz: Int = 0) async {
        guard let radioId = selectedRadioId, let token = controlToken else {
            errorMessage = RadioLiteSessionError.controlRequired.localizedDescription
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let commandId = UUID().uuidString
            let reply = try await self.control.request(
                .object([
                    "t": .string("rig.mode.set"),
                    "radioId": .string(radioId),
                    "controlToken": .string(token),
                    "mode": .string(mode.hamlibMode),
                    "passbandHz": .number(Double(passbandHz)),
                    "commandId": .string(commandId),
                ]),
                expecting: ["rig.mode.confirmed"],
                commandId: commandId
            )
            self.replaceRigState(
                mode: reply["mode"]?.stringValue ?? mode.hamlibMode,
                passbandHz: reply["passbandHz"]?.intValue ?? passbandHz
            )
            resolveModeNotices()
        } catch {
            if let socketError = error as? RadioLiteSocketError,
               case .command(let code, _) = socketError,
               let notice = RadioLiteRigMode.failureNotice(code: code, requested: mode) {
                presentNotice(
                    notice,
                    deduplicationKey: "rig.mode.\(mode.rawValue).\(code)"
                )
                try? await refreshRigState()
                return
            }
            errorMessage = error.localizedDescription
        }
    }

    func refreshRigState() async throws {
        guard let radioId = selectedRadioId else { throw RadioLiteSessionError.radioUnavailable }
        let commandId = UUID().uuidString
        let reply = try await control.request(
            .object([
                "t": .string("rig.state.get"),
                "radioId": .string(radioId),
                "commandId": .string(commandId),
            ]),
            expecting: ["rig.state"],
            commandId: commandId
        )
        guard let state: RadioLiteRigState = reply["state"]?.decoded() else {
            throw RadioLiteHTTPError.invalidResponse
        }
        rigState = state
    }

    func refreshRigControls() async throws {
        guard let radioId = selectedRadioId else { throw RadioLiteSessionError.radioUnavailable }
        let commandId = UUID().uuidString
        let reply = try await control.request(
            RadioLiteRigControlProtocol.getRequest(radioId: radioId, commandId: commandId),
            expecting: ["rig.controls"],
            commandId: commandId
        )
        guard let response: RadioLiteRigControlsResponse = reply.decoded(),
              response.t == "rig.controls",
              response.radioId == radioId,
              response.commandId == commandId else {
            throw RadioLiteHTTPError.invalidResponse
        }
        guard selectedRadioId == radioId else { return }
        rigControls = response.controls
    }

    @discardableResult
    func setRigControl(_ controlId: String, value requestedValue: Double) async -> RadioLiteRigControl? {
        guard let radioId = selectedRadioId,
              let controlToken else {
            errorMessage = RadioLiteSessionError.controlRequired.localizedDescription
            return nil
        }
        guard let current = rigControls.first(where: { $0.id == controlId }) else {
            errorMessage = RadioLiteSessionError.rigControlUnavailable.localizedDescription
            return nil
        }

        let transmitting = isVoicePTTHeld || isTuning || rigState?.ptt == true
        let display = current.displayState(isTransmitting: transmitting)
        guard display.writable else {
            errorMessage = RadioLiteSessionError.rigControlLocked(
                display.lockedReason ?? "该控件当前不可调整"
            ).localizedDescription
            return nil
        }
        guard let value = validatedRigControlValue(requestedValue, for: current) else {
            errorMessage = RadioLiteSessionError.invalidRigControlValue.localizedDescription
            return nil
        }

        isWorking = true
        defer { isWorking = false }
        do {
            let commandId = UUID().uuidString
            let reply = try await control.request(
                RadioLiteRigControlProtocol.setRequest(
                    radioId: radioId,
                    controlToken: controlToken,
                    controlId: controlId,
                    value: value,
                    commandId: commandId
                ),
                expecting: ["rig.control.confirmed"],
                commandId: commandId
            )
            guard let confirmation: RadioLiteRigControlConfirmation = reply.decoded(),
                  confirmation.t == "rig.control.confirmed",
                  confirmation.radioId == radioId,
                  confirmation.commandId == commandId,
                  confirmation.control.id == controlId else {
                throw RadioLiteHTTPError.invalidResponse
            }
            guard selectedRadioId == radioId else { return nil }
            rigControls = RadioLiteRigControlProtocol.applying(confirmation, to: rigControls)
            if confirmation.control.kind == .filter,
               confirmation.control.value.isFinite,
               confirmation.control.value > Double(Int.min),
               confirmation.control.value < Double(Int.max) {
                replaceRigState(passbandHz: Int(confirmation.control.value.rounded()))
            }
            return confirmation.control
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func startReceiveAudio() async {
        guard let radioId = selectedRadioId else {
            errorMessage = RadioLiteSessionError.radioUnavailable.localizedDescription
            return
        }
        if let pending = receiveAudioStartupTask {
            await pending.value
            return
        }

        let generation = receiveAudioEpoch.begin()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard self.media.state == .ready else { throw RadioLiteSocketError.notConnected }
                if self.media.subscribedRadioId != radioId {
                    try await self.media.subscribe(radioId: radioId)
                    try Task.checkCancellation()
                    guard self.receiveAudioEpoch.owns(generation) else { return }
                    self.resolveMediaNotices()
                }
                try Task.checkCancellation()
                guard self.receiveAudioEpoch.owns(generation) else { return }
                try self.audio.startMonitoring()
                guard !Task.isCancelled, self.receiveAudioEpoch.owns(generation) else {
                    self.audio.stopMonitoring()
                    return
                }
            } catch {
                guard !Task.isCancelled, self.receiveAudioEpoch.owns(generation) else { return }
                if self.media.subscribedRadioId != radioId {
                    self.scheduleMediaRetry()
                }
                self.errorMessage = "接收音频启动失败：\(error.localizedDescription)"
            }
        }
        receiveAudioStartupTask = task
        await task.value
        if receiveAudioEpoch.owns(generation) {
            receiveAudioStartupTask = nil
        }
    }

    func stopReceiveAudio() {
        receiveAudioEpoch.invalidate()
        receiveAudioStartupTask?.cancel()
        receiveAudioStartupTask = nil
        audio.stopMonitoring()
    }

    func beginVoicePTT() {
        guard !isVoicePTTHeld, !isTuning else { return }
        guard canTransmit else {
            errorMessage = RadioLiteSessionError.transmitNotAllowed.localizedDescription
            return
        }
        guard let radioId = selectedRadioId, let token = controlToken else {
            errorMessage = RadioLiteSessionError.controlRequired.localizedDescription
            return
        }
        voicePTTStartupTask?.cancel()
        let generation = transmitEpoch.begin()
        isVoicePTTHeld = true
        voicePTTStartupTask = Task { [weak self] in
            guard let self else { return }
            var startedToken: String?
            var capture: RadioLiteMicrophoneCaptureOwnership?
            var uplink: RadioLiteUplinkOwnership?
            do {
                guard self.media.state == .ready else {
                    throw RadioLiteSocketError.notConnected
                }
                if self.media.subscribedRadioId != radioId {
                    try await self.media.subscribe(radioId: radioId)
                    try Task.checkCancellation()
                    guard self.isVoicePTTHeld, self.transmitEpoch.owns(generation) else { return }
                    self.resolveMediaNotices()
                }
                try Task.checkCancellation()
                guard self.isVoicePTTHeld, self.transmitEpoch.owns(generation) else { return }

                // Prove that iOS can open and encode the microphone before
                // keying the physical radio. Packets are intentionally dropped
                // until the server returns and binds a transmit token.
                let captureOwnership = try await self.audio.beginMicrophoneCapture { [weak self] packet in
                    self?.media.enqueueMicrophonePacket(packet)
                }
                capture = captureOwnership
                guard !Task.isCancelled,
                      self.isVoicePTTHeld,
                      self.transmitEpoch.owns(generation) else {
                    self.audio.stopMicrophoneCapture(epoch: captureOwnership.epoch)
                    return
                }
                self.activeCaptureOwnership = captureOwnership

                let commandId = UUID().uuidString
                let reply = try await self.control.request(
                    .object([
                        "t": .string("tx.start"),
                        "radioId": .string(radioId),
                        "controlToken": .string(token),
                        "mode": .string("voice"),
                        "commandId": .string(commandId),
                    ]),
                    expecting: ["tx.started"],
                    commandId: commandId
                )
                guard let transmitToken = reply["transmitToken"]?.stringValue else {
                    throw RadioLiteHTTPError.invalidResponse
                }
                startedToken = transmitToken
                guard !Task.isCancelled,
                      self.isVoicePTTHeld,
                      self.transmitEpoch.owns(generation) else {
                    self.audio.stopMicrophoneCapture(epoch: captureOwnership.epoch)
                    await self.stopRemoteTransmit(radioId: radioId, transmitToken: transmitToken)
                    return
                }
                self.activeTransmitToken = transmitToken
                let uplinkOwnership = try await self.media.bindUplink(
                    radioId: radioId,
                    transmitToken: transmitToken
                )
                uplink = uplinkOwnership
                guard !Task.isCancelled,
                      self.isVoicePTTHeld,
                      self.transmitEpoch.owns(generation) else {
                    self.media.stopUplink(
                        transmitToken: uplinkOwnership.transmitToken,
                        epoch: uplinkOwnership.epoch
                    )
                    self.audio.stopMicrophoneCapture(epoch: captureOwnership.epoch)
                    await self.stopRemoteTransmit(radioId: radioId, transmitToken: transmitToken)
                    return
                }
                self.activeUplinkOwnership = uplinkOwnership
                self.startTransmitHeartbeat(
                    radioId: radioId,
                    controlToken: token,
                    transmitToken: transmitToken,
                    generation: generation
                )
                if self.transmitEpoch.owns(generation) {
                    self.voicePTTStartupTask = nil
                }
            } catch {
                if let uplink {
                    self.media.stopUplink(transmitToken: uplink.transmitToken, epoch: uplink.epoch)
                    if self.activeUplinkOwnership == uplink { self.activeUplinkOwnership = nil }
                }
                if let capture {
                    self.audio.stopMicrophoneCapture(epoch: capture.epoch)
                    if self.activeCaptureOwnership == capture { self.activeCaptureOwnership = nil }
                }
                if !Task.isCancelled,
                   self.isVoicePTTHeld,
                   self.transmitEpoch.owns(generation) {
                    _ = self.stopLocalTransmit(expectedEpoch: generation)
                    if self.media.subscribedRadioId != radioId { self.scheduleMediaRetry() }
                    self.errorMessage = "PTT 启动失败：\(error.localizedDescription)"
                }
                if let startedToken {
                    await self.stopRemoteTransmit(radioId: radioId, transmitToken: startedToken)
                }
            }
        }
    }

    func endVoicePTT() {
        guard isVoicePTTHeld || voicePTTStartupTask != nil ||
                activeCaptureOwnership != nil || activeUplinkOwnership != nil else { return }
        let transmitToken = activeTransmitToken
        let radioId = selectedRadioId
        _ = stopLocalTransmit()
        guard let transmitToken, let radioId else { return }
        Task { [weak self] in await self?.stopRemoteTransmit(radioId: radioId, transmitToken: transmitToken) }
    }

    func beginTuning() {
        guard !isTuning, !isVoicePTTHeld else { return }
        guard canTransmit else {
            errorMessage = RadioLiteSessionError.transmitNotAllowed.localizedDescription
            return
        }
        guard let radioId = selectedRadioId, let token = controlToken else {
            errorMessage = RadioLiteSessionError.controlRequired.localizedDescription
            return
        }
        tuningStartupTask?.cancel()
        let generation = transmitEpoch.begin()
        isTuning = true
        tuningStartupTask = Task { [weak self] in
            guard let self else { return }
            var startedToken: String?
            do {
                let commandId = UUID().uuidString
                let reply = try await self.control.request(
                    .object([
                        "t": .string("tx.start"),
                        "radioId": .string(radioId),
                        "controlToken": .string(token),
                        "mode": .string("tuning"),
                        "commandId": .string(commandId),
                    ]),
                    expecting: ["tx.started"],
                    commandId: commandId
                )
                guard let transmitToken = reply["transmitToken"]?.stringValue else {
                    throw RadioLiteHTTPError.invalidResponse
                }
                startedToken = transmitToken
                guard !Task.isCancelled,
                      self.isTuning,
                      self.transmitEpoch.owns(generation) else {
                    await self.stopRemoteTransmit(radioId: radioId, transmitToken: transmitToken)
                    return
                }
                self.activeTransmitToken = transmitToken
                self.startTransmitHeartbeat(
                    radioId: radioId,
                    controlToken: token,
                    transmitToken: transmitToken,
                    generation: generation
                )
                if self.transmitEpoch.owns(generation) {
                    self.tuningStartupTask = nil
                }
            } catch {
                if !Task.isCancelled,
                   self.isTuning,
                   self.transmitEpoch.owns(generation) {
                    _ = self.stopLocalTransmit(expectedEpoch: generation)
                    self.errorMessage = "机内天调启动失败：\(error.localizedDescription)"
                }
                if let startedToken {
                    await self.stopRemoteTransmit(radioId: radioId, transmitToken: startedToken)
                }
            }
        }
    }

    func endTuning() {
        guard isTuning || tuningStartupTask != nil else { return }
        let transmitToken = activeTransmitToken
        let radioId = selectedRadioId
        _ = stopLocalTransmit()
        guard let transmitToken, let radioId else { return }
        Task { [weak self] in await self?.stopRemoteTransmit(radioId: radioId, transmitToken: transmitToken) }
    }

    func refreshDigitalSnapshot() async throws {
        guard let radioId = selectedRadioId else { throw RadioLiteSessionError.radioUnavailable }
        let reply = try await control.request(
            .object([
                "t": .string("digital.snapshot.get"),
                "radioId": .string(radioId),
            ]),
            expecting: ["digital.snapshot"]
        )
        guard let snapshot: RadioLiteDigitalSnapshot = reply.decoded() else {
            throw RadioLiteHTTPError.invalidResponse
        }
        applyDigitalSnapshot(snapshot)
    }

    func addDecodeToQueue(_ decodeId: String) async {
        await performDigitalCommand(status: "已加入呼叫队列") { radioId, token, commandId in
            .object([
                "t": .string("digital.queue.add.decode"),
                "radioId": .string(radioId),
                "controlToken": .string(token),
                "decodeId": .string(decodeId),
                "commandId": .string(commandId),
            ])
        } expected: { ["digital.queue.added"] }
    }

    func addManualCall(
        callsign: String,
        grid: String?,
        mode: String,
        audioFrequencyHz: Int,
        parity: String
    ) async {
        await performDigitalCommand(status: "已加入手动呼叫") { radioId, token, commandId in
            var fields: [String: JSONValue] = [
                "t": .string("digital.queue.add.manual"),
                "radioId": .string(radioId),
                "controlToken": .string(token),
                "targetCallsign": .string(callsign.uppercased()),
                "mode": .string(mode),
                "audioFrequencyHz": .number(Double(audioFrequencyHz)),
                "txParity": .string(parity),
                "commandId": .string(commandId),
            ]
            if let grid, !grid.isEmpty { fields["targetGrid"] = .string(grid.uppercased()) }
            return .object(fields)
        } expected: { ["digital.queue.added"] }
    }

    func skipQueue() async {
        await performDigitalCommand(status: "已跳到下一呼叫") { radioId, token, commandId in
            .object([
                "t": .string("digital.queue.skip"),
                "radioId": .string(radioId),
                "controlToken": .string(token),
                "commandId": .string(commandId),
            ])
        } expected: { ["digital.queue.skipped"] }
    }

    func removeQueueEntry(_ entryId: String) async {
        await performDigitalCommand(status: "已移出呼叫队列") { radioId, token, commandId in
            .object([
                "t": .string("digital.queue.remove"),
                "radioId": .string(radioId),
                "controlToken": .string(token),
                "entryId": .string(entryId),
                "commandId": .string(commandId),
            ])
        } expected: { ["digital.queue.removed"] }
    }

    func stopAutomaticQSO(requeue: Bool) async {
        await performDigitalCommand(status: requeue ? "自动 QSO 已暂停并重新排队" : "自动 QSO 已停止") { radioId, token, commandId in
            .object([
                "t": .string("digital.auto.stop"),
                "radioId": .string(radioId),
                "controlToken": .string(token),
                "requeue": .bool(requeue),
                "commandId": .string(commandId),
            ])
        } expected: { ["digital.auto.stopped"] }
    }

    func refreshLogs(limit: Int = 200, offset: Int = 0) async {
        guard let http else { return }
        do {
            async let page = http.logs(limit: limit, offset: offset)
            async let gridResponse = http.grids(resolution: 4)
            let (pageValue, gridValue) = try await (page, gridResponse)
            qsos = pageValue.records
            qsoTotal = pageValue.total
            grids = gridValue.grids
        } catch {
            errorMessage = "日志读取失败：\(error.localizedDescription)"
        }
    }

    func addManualQSO(_ value: RadioLiteManualQSO) async throws {
        guard let http else { throw RadioLiteSessionError.notConnected }
        _ = try await http.addManualQSO(value)
        await refreshLogs()
    }

    func exportADIF() async throws -> URL {
        guard let http else { throw RadioLiteSessionError.notConnected }
        let data = try await http.exportADIF()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("radio-lite-log.adi")
        try data.write(to: url, options: .atomic)
        return url
    }

    func importADIF(from url: URL) async throws -> (Int, Int) {
        guard isAdmin else { throw RadioLiteSessionError.administratorRequired }
        guard let http else { throw RadioLiteSessionError.notConnected }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let result = try await http.importADIF(Data(contentsOf: url))
        await refreshLogs()
        return (result.imported, result.duplicates)
    }

    func refreshUsers() async {
        guard isAdmin, let http else { return }
        do {
            users = try await http.users()
        } catch {
            errorMessage = "账户读取失败：\(error.localizedDescription)"
        }
    }

    func loadHardwareDiscovery() async throws -> RadioLiteHardwareDiscovery {
        guard isAdmin else { throw RadioLiteSessionError.administratorRequired }
        guard let http else { throw RadioLiteSessionError.notConnected }
        return try await http.hardwareDiscovery()
    }

    @discardableResult
    func saveRadioConfiguration(
        _ profile: RadioLiteRadioProfile,
        confirmHardwareTransmission: Bool
    ) async throws -> Bool {
        guard isAdmin else { throw RadioLiteSessionError.administratorRequired }
        guard let http else { throw RadioLiteSessionError.notConnected }

        isWorking = true
        defer { isWorking = false }
        endVoicePTT()
        endTuning()

        let response = try await http.upsertRadio(
            profile,
            confirmHardwareTransmission: confirmHardwareTransmission
        )
        if let index = radios.firstIndex(where: { $0.id == response.radio.id }) {
            radios[index] = response.radio
        } else {
            radios.append(response.radio)
            radios.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }

        guard response.reconnectRequired else {
            presentNotice("设备配置已保存")
            return true
        }
        controlHeartbeatTask?.cancel()
        controlHeartbeatTask = nil
        controlToken = nil
        controlExpiresAtMs = nil
        var controlReady = true
        do {
            try await acquireControl()
        } catch {
            controlReady = false
        }
        do {
            if selectedRadioId == response.radio.id {
                try await media.subscribe(radioId: response.radio.id)
                resolveMediaNotices()
                try await refreshRigState()
                try? await refreshRigControls()
            }
            presentNotice(
                controlReady
                    ? "设备配置已保存，电台与音频已重新连接"
                    : "设备配置和媒体已生效，但当前未取得电台控制权"
            )
            return true
        } catch {
            presentNotice(
                "设备配置已保存，后台正在重连：\(error.localizedDescription)",
                deduplicationKey: "radio.configuration.reconnect"
            )
            scheduleMediaRetry()
            return false
        }
    }

    func createUser(
        username: String,
        password: String,
        role: RadioLiteUserRole,
        canTransmit: Bool,
        mustChangePassword: Bool
    ) async throws {
        guard isAdmin else { throw RadioLiteSessionError.administratorRequired }
        guard let http else { throw RadioLiteSessionError.notConnected }
        _ = try await http.createUser(
            username: username,
            password: password,
            role: role,
            canTransmit: canTransmit,
            mustChangePassword: mustChangePassword
        )
        users = try await http.users()
    }

    func issuePairingCode(for userId: String) async throws {
        guard isAdmin else { throw RadioLiteSessionError.administratorRequired }
        guard let http else { throw RadioLiteSessionError.notConnected }
        issuedPairingCode = try await http.issuePairingCode(userId: userId)
    }

    func appDidEnterBackground() {
        endVoicePTT()
        endTuning()
        media.setSpectrumVisible(false)
    }

    func appDidBecomeActive() {
        media.setSpectrumVisible(true)
        guard phase == .ready else { return }
        if case .device(let device) = credential, device.accessExpiresAtMs <= nowMs() + 30_000 {
            Task { [weak self] in await self?.refreshCredentialAndReconnect() }
        } else if control.state != .ready || media.state != .ready {
            scheduleReconnect()
        }
    }

    func reconnectNow() {
        reconnectTask?.cancel()
        reconnectTask = nil
        scheduleReconnect()
    }

    private func authenticate(_ operation: () async throws -> Void) async {
        phase = .authenticating
        isWorking = true
        errorMessage = nil
        resetNotices()
        defer { isWorking = false }
        do {
            try await operation()
        } catch {
            phase = .signedOut
            errorMessage = error.localizedDescription
        }
    }

    private func persistAndFinish(
        server: RadioLiteServer,
        credential: RadioLiteCredential,
        username: String?
    ) async throws {
        let stored = RadioLiteStoredLogin(
            serverAddress: server.displayAddress,
            credential: credential,
            username: username
        )
        try credentialStore.save(stored)
        UserDefaults.standard.set(server.displayAddress, forKey: Self.addressDefaultsKey)
        try await finishAuthentication(server: server, credential: credential, username: username)
    }

    private func finishAuthentication(
        server: RadioLiteServer,
        credential: RadioLiteCredential,
        username: String?
    ) async throws {
        phase = .authenticating
        intentionalDisconnect = true
        cancelRuntimeTasks()
        control.disconnect()
        media.disconnect()
        intentionalDisconnect = false

        self.server = server
        self.credential = credential
        self.username = username
        self.http = RadioLiteHTTPClient(server: server, credential: credential)

        let controlWelcome = try await control.connect(server: server, credential: credential)
        let mediaWelcome = try await media.connect(server: server, credential: credential)
        guard controlWelcome.principal.userId == mediaWelcome.principal.userId else {
            throw RadioLiteHTTPError.invalidResponse
        }
        principal = controlWelcome.principal
        radios = controlWelcome.radios
        guard !radios.isEmpty else { throw RadioLiteSessionError.radioUnavailable }

        let preferred = UserDefaults.standard.string(forKey: Self.radioDefaultsKey)
        selectedRadioId = radios.contains(where: { $0.id == preferred }) ? preferred : radios[0].id
        guard let radioId = selectedRadioId else { throw RadioLiteSessionError.radioUnavailable }
        var mediaReady = true
        do {
            try await media.subscribe(radioId: radioId)
            resolveMediaNotices()
        } catch {
            mediaReady = false
            presentMediaNotice(error)
        }
        do {
            try await acquireControl()
        } catch {
            controlToken = nil
            presentNotice("已连接，但电台控制权当前由其他操作员持有")
        }
        try await refreshRigState()
        try? await refreshRigControls()
        do { try await refreshDigitalSnapshot() } catch {
            presentNotice("FT8/FT4 暂不可用：\(error.localizedDescription)")
        }
        phase = .ready
        startPolling()
        scheduleCredentialRefresh()
        if !mediaReady {
            scheduleMediaRetry()
        }
        Task { [weak self] in
            await self?.refreshLogs()
            await self?.refreshUsers()
        }
    }

    private func performControlCommand(
        _ operation: (_ radioId: String, _ controlToken: String) async throws -> Void
    ) async {
        guard let radioId = selectedRadioId, let token = controlToken else {
            errorMessage = RadioLiteSessionError.controlRequired.localizedDescription
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            try await operation(radioId, token)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func performDigitalCommand(
        status: String,
        makeMessage: (_ radioId: String, _ token: String, _ commandId: String) -> JSONValue,
        expected: () -> Set<String>
    ) async {
        guard let radioId = selectedRadioId, let token = controlToken else {
            errorMessage = RadioLiteSessionError.controlRequired.localizedDescription
            return
        }
        digitalActionStatus = nil
        do {
            let commandId = UUID().uuidString
            _ = try await control.request(
                makeMessage(radioId, token, commandId),
                expecting: expected(),
                commandId: commandId
            )
            digitalActionStatus = status
            try? await Task.sleep(for: .seconds(2))
            if digitalActionStatus == status { digitalActionStatus = nil }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handleControlEvent(_ value: JSONValue) {
        guard value["radioId"]?.stringValue == nil || value["radioId"]?.stringValue == selectedRadioId else {
            return
        }
        switch value["t"]?.stringValue {
        case "control.alive":
            controlExpiresAtMs = value["expiresAtMs"]?.int64Value
        case "digital.decode.batch":
            if let batch: RadioLiteDigitalDecodeBatch = value["batch"]?.decoded() {
                if let index = decodeBatches.firstIndex(where: { $0.id == batch.id }) {
                    decodeBatches[index] = batch
                } else {
                    decodeBatches.append(batch)
                }
                decodeBatches.sort { $0.slotStartMs > $1.slotStartMs }
                if decodeBatches.count > 20 { decodeBatches.removeLast(decodeBatches.count - 20) }
            }
        case "digital.queue":
            if let queue: RadioLiteCallQueueSnapshot = value["queue"]?.decoded() { callQueue = queue }
        case "digital.qso":
            if let qso: RadioLiteAutoQSO = value["qso"]?.decoded() { automaticQSO = qso }
        case "digital.queue.skipped", "digital.queue.removed", "digital.auto.stopped":
            if let queue: RadioLiteCallQueueSnapshot = value["queue"]?.decoded() { callQueue = queue }
            if value["qso"] == .null { automaticQSO = nil }
        case "digital.log.created":
            Task { [weak self] in await self?.refreshLogs() }
        case "digital.error":
            errorMessage = value["message"]?.stringValue ?? "数字模式服务故障"
        case "command.error":
            errorMessage = value["message"]?.stringValue ?? "服务器拒绝了操作"
        default:
            break
        }
    }

    private func applyDigitalSnapshot(_ value: RadioLiteDigitalSnapshot) {
        decodeBatches = value.decodes.batches.sorted { $0.slotStartMs > $1.slotStartMs }
        callQueue = value.queue
        automaticQSO = value.qso
    }

    private func startControlHeartbeat() {
        controlHeartbeatTask?.cancel()
        controlHeartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self,
                      let radioId = self.selectedRadioId,
                      let token = self.controlToken else { return }
                do {
                    _ = try await self.control.request(
                        .object([
                            "t": .string("control.heartbeat"),
                            "radioId": .string(radioId),
                            "controlToken": .string(token),
                        ]),
                        expecting: ["control.alive"]
                    )
                } catch {
                    self.controlToken = nil
                    self.controlExpiresAtMs = nil
                    self.endVoicePTT()
                    self.endTuning()
                    self.presentNotice("控制租约已失效，请重新取得控制权")
                    return
                }
            }
        }
    }

    private func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self, self.phase == .ready else { return }
                try? await self.refreshRigState()
            }
        }
    }

    private func startTransmitHeartbeat(
        radioId: String,
        controlToken: String,
        transmitToken: String,
        generation: UInt64
    ) {
        transmitHeartbeatTask?.cancel()
        transmitHeartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled,
                      let self,
                      self.transmitEpoch.owns(generation),
                      self.activeTransmitToken == transmitToken else { return }
                do {
                    _ = try await self.control.request(
                        .object([
                            "t": .string("tx.heartbeat"),
                            "radioId": .string(radioId),
                            "controlToken": .string(controlToken),
                            "transmitToken": .string(transmitToken),
                        ]),
                        expecting: ["tx.alive"]
                    )
                } catch {
                    guard !Task.isCancelled,
                          self.transmitEpoch.owns(generation),
                          self.activeTransmitToken == transmitToken else { return }
                    guard self.stopLocalTransmit(expectedEpoch: generation) else { return }
                    self.errorMessage = "发射心跳中断：\(error.localizedDescription)"
                    await self.stopRemoteTransmit(radioId: radioId, transmitToken: transmitToken)
                    return
                }
            }
        }
    }

    private func stopRemoteTransmit(radioId: String, transmitToken: String) async {
        let commandId = UUID().uuidString
        _ = try? await control.request(
            .object([
                "t": .string("tx.stop"),
                "radioId": .string(radioId),
                "transmitToken": .string(transmitToken),
                "commandId": .string(commandId),
            ]),
            expecting: ["tx.stopped"],
            commandId: commandId
        )
    }

    @discardableResult
    private func stopLocalTransmit(expectedEpoch: UInt64? = nil) -> Bool {
        if let expectedEpoch, !transmitEpoch.owns(expectedEpoch) { return false }
        transmitEpoch.invalidate()
        voicePTTStartupTask?.cancel()
        tuningStartupTask?.cancel()
        voicePTTStartupTask = nil
        tuningStartupTask = nil
        isVoicePTTHeld = false
        isTuning = false
        if let capture = activeCaptureOwnership {
            audio.stopMicrophoneCapture(epoch: capture.epoch)
        } else {
            audio.stopMicrophoneCapture()
        }
        if let uplink = activeUplinkOwnership {
            media.stopUplink(transmitToken: uplink.transmitToken, epoch: uplink.epoch)
        } else {
            media.stopUplink()
        }
        transmitHeartbeatTask?.cancel()
        transmitHeartbeatTask = nil
        activeCaptureOwnership = nil
        activeUplinkOwnership = nil
        activeTransmitToken = nil
        return true
    }

    private func handleConnectionLoss(_ error: Error) {
        stopLocalTransmit()
        stopReceiveAudio()
        controlToken = nil
        controlExpiresAtMs = nil
        guard !intentionalDisconnect, phase == .ready else { return }
        presentNotice(
            "连接中断，正在自动重连：\(error.localizedDescription)",
            deduplicationKey: "connection.loss:\(error.localizedDescription)"
        )
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil, phase == .ready else { return }
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            var delay = 2.0
            while !Task.isCancelled, self.phase == .ready {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                do {
                    if case .device(let device) = self.credential,
                       device.accessExpiresAtMs <= self.nowMs() + 30_000 {
                        try await self.refreshCredential()
                    }
                    guard let server = self.server, let credential = self.credential else {
                        throw RadioLiteSessionError.notConnected
                    }
                    let mediaReady = try await self.reconnectChannels(server: server, credential: credential)
                    self.scheduleCredentialRefresh()
                    if mediaReady {
                        self.presentNotice("已恢复连接")
                    } else {
                        self.presentNotice(
                            "电台控制已恢复，频谱与音频仍在后台重试",
                            deduplicationKey: "media.failure"
                        )
                        self.scheduleMediaRetry()
                    }
                    self.reconnectTask = nil
                    return
                } catch {
                    self.presentNotice(
                        "重连失败，将继续尝试：\(error.localizedDescription)",
                        deduplicationKey: "connection.reconnect:\(error.localizedDescription)"
                    )
                    delay = min(30, delay * 1.8)
                }
            }
            self.reconnectTask = nil
        }
    }

    private func reconnectChannels(server: RadioLiteServer, credential: RadioLiteCredential) async throws -> Bool {
        intentionalDisconnect = true
        control.disconnect()
        media.disconnect()
        intentionalDisconnect = false
        let welcome = try await control.connect(server: server, credential: credential)
        _ = try await media.connect(server: server, credential: credential)
        principal = welcome.principal
        radios = welcome.radios
        guard let radioId = selectedRadioId, radios.contains(where: { $0.id == radioId }) else {
            throw RadioLiteSessionError.radioUnavailable
        }
        var mediaReady = true
        do {
            try await media.subscribe(radioId: radioId)
            resolveMediaNotices()
        } catch {
            mediaReady = false
            presentMediaNotice(error)
        }
        do { try await acquireControl() } catch { controlToken = nil }
        try await refreshRigState()
        try? await refreshRigControls()
        try? await refreshDigitalSnapshot()
        startPolling()
        return mediaReady
    }

    private func scheduleCredentialRefresh() {
        credentialRefreshTask?.cancel()
        guard case .device(let device) = credential else { return }
        credentialRefreshTask = Task { [weak self] in
            guard let self else { return }
            let delay = max(1, Double(device.accessExpiresAtMs - self.nowMs() - 60_000) / 1_000)
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self.refreshCredentialAndReconnect()
        }
    }

    private func scheduleMediaRetry() {
        guard mediaRetryTask == nil, phase == .ready else { return }
        mediaRetryTask = Task { [weak self] in
            guard let self else { return }
            var delay = 2.0
            while !Task.isCancelled, self.phase == .ready {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                guard self.media.state == .ready else {
                    self.mediaRetryTask = nil
                    self.scheduleReconnect()
                    return
                }
                guard let radioId = self.selectedRadioId else {
                    self.mediaRetryTask = nil
                    return
                }
                do {
                    try await self.media.subscribe(radioId: radioId)
                    self.resolveMediaNotices()
                    self.mediaRetryTask = nil
                    return
                } catch {
                    self.presentMediaNotice(error)
                    delay = min(30, delay * 1.8)
                }
            }
            self.mediaRetryTask = nil
        }
    }

    private func refreshCredentialAndReconnect() async {
        do {
            try await refreshCredential()
            guard let server, let credential else { throw RadioLiteSessionError.notConnected }
            let mediaReady = try await reconnectChannels(server: server, credential: credential)
            scheduleCredentialRefresh()
            if !mediaReady {
                scheduleMediaRetry()
            }
        } catch {
            stopLocalTransmit()
            phase = .signedOut
            errorMessage = "设备配对刷新失败，请重新配对：\(error.localizedDescription)"
            try? credentialStore.delete()
        }
    }

    private func refreshCredential() async throws {
        guard let server, case .device(let current) = credential else { return }
        let refreshed = try await RadioLiteHTTPClient(server: server).refreshDevice(current)
        let updated: RadioLiteCredential = .device(refreshed)
        credential = updated
        http = RadioLiteHTTPClient(server: server, credential: updated)
        try credentialStore.save(RadioLiteStoredLogin(
            serverAddress: server.displayAddress,
            credential: updated,
            username: username
        ))
    }

    private func cancelRuntimeTasks() {
        controlHeartbeatTask?.cancel()
        pollingTask?.cancel()
        transmitHeartbeatTask?.cancel()
        credentialRefreshTask?.cancel()
        reconnectTask?.cancel()
        mediaRetryTask?.cancel()
        voicePTTStartupTask?.cancel()
        tuningStartupTask?.cancel()
        receiveAudioStartupTask?.cancel()
        transmitEpoch.invalidate()
        receiveAudioEpoch.invalidate()
        controlHeartbeatTask = nil
        pollingTask = nil
        transmitHeartbeatTask = nil
        credentialRefreshTask = nil
        reconnectTask = nil
        mediaRetryTask = nil
        voicePTTStartupTask = nil
        tuningStartupTask = nil
        receiveAudioStartupTask = nil
    }

    private func clearRadioState() {
        controlToken = nil
        controlExpiresAtMs = nil
        rigState = nil
        rigControls = []
        decodeBatches = []
        callQueue = nil
        automaticQSO = nil
    }

    private func presentNotice(_ message: String, deduplicationKey: String? = nil) {
        noticeState.present(message, deduplicationKey: deduplicationKey)
        noticeMessage = noticeState.message
    }

    private func presentMediaNotice(_ error: Error) {
        let detail = error.localizedDescription
        presentNotice(
            "媒体订阅受限：\(detail)",
            deduplicationKey: "media.failure"
        )
    }

    private func resolveMediaNotices() {
        mediaRetryTask?.cancel()
        mediaRetryTask = nil
        noticeState.resolve(keysWithPrefix: "media.")
        noticeMessage = noticeState.message
    }

    private func resolveModeNotices() {
        noticeState.resolve(keysWithPrefix: "rig.mode.")
        noticeMessage = noticeState.message
    }

    private func resetNotices() {
        noticeState.reset()
        noticeMessage = nil
    }

    private func replaceRigState(
        frequencyHz: Int64? = nil,
        mode: String? = nil,
        passbandHz: Int? = nil,
        ptt: Bool? = nil
    ) {
        let current = rigState ?? RadioLiteRigState(
            frequencyHz: 14_074_000,
            mode: "USB",
            passbandHz: 3_000,
            ptt: false
        )
        rigState = RadioLiteRigState(
            frequencyHz: frequencyHz ?? current.frequencyHz,
            mode: mode ?? current.mode,
            passbandHz: passbandHz ?? current.passbandHz,
            ptt: ptt ?? current.ptt
        )
    }

    private func validatedRigControlValue(
        _ requestedValue: Double,
        for control: RadioLiteRigControl
    ) -> Double? {
        guard requestedValue.isFinite,
              control.minimum.isFinite,
              control.maximum.isFinite,
              control.step.isFinite,
              control.minimum <= control.maximum else {
            return nil
        }

        let scale = max(
            1,
            max(abs(control.minimum), max(abs(control.maximum), abs(control.step)))
        )
        let tolerance = scale * 1e-9
        guard requestedValue >= control.minimum - tolerance,
              requestedValue <= control.maximum + tolerance else {
            return nil
        }

        let clamped = min(control.maximum, max(control.minimum, requestedValue))
        guard control.step > 0 else { return clamped }
        let stepCount = ((clamped - control.minimum) / control.step).rounded()
        let snapped = control.minimum + stepCount * control.step
        guard snapped.isFinite,
              abs(snapped - clamped) <= max(tolerance, abs(control.step) * 1e-6) else {
            return nil
        }
        return min(control.maximum, max(control.minimum, snapped))
    }

    private func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }
}

private extension JSONValue {
    var int64Value: Int64? { doubleValue.map(Int64.init) }
}
