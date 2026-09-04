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
    case hardwarePreflightUnavailable

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
        case .hardwarePreflightUnavailable:
            "服务器版本过旧或反向代理路径错误，当前不支持硬件预检"
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
    @Published private(set) var telemetry: RadioLiteTelemetry?
    @Published private(set) var rigControls: [RadioLiteRigControl] = []
    @Published private(set) var radioCapabilities: [RadioLiteCapabilityControl] = []
    @Published private(set) var radioCapabilitiesAvailable = false
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
    @Published private(set) var isTuningPending = false
    @Published private(set) var isWorking = false
    @Published private(set) var isRestoringSession = false
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
    private var serverFeatures: RadioLiteServerFeatures?
    private var intentionalDisconnect = false
    private var controlHeartbeatTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var transmitHeartbeatTask: Task<Void, Never>?
    private var credentialRefreshTask: Task<Void, Never>?
    private var credentialPersistenceRetryTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectOwnershipState = RadioLiteReconnectOwnershipState()
    private let credentialRefreshCoordinator = RadioLiteCredentialRefreshCoordinator()
    private var credentialAccountOwnershipState = RadioLiteCredentialAccountOwnershipState()
    private var authenticationOwnershipState = RadioLiteAuthenticationOwnershipState()
    private var startupRestoreTask: Task<Void, Never>?
    private var startupRestoreDeadlineTask: Task<Void, Never>?
    private var mediaRetryTask: Task<Void, Never>?
    private var mediaRetryOwnership: RadioLiteReceiveMonitoringOwnership?
    private var voicePTTStartupTask: Task<Void, Never>?
    private var tuningStartupTask: Task<Void, Never>?
    private var tuningPendingTask: Task<Void, Never>?
    private var receiveAudioStartupTask: Task<Void, Never>?
    private var receiveAudioStartupOwnership: RadioLiteReceiveMonitoringOwnership?
    private var voicePTTReceiveRestoreState = RadioLiteVoicePTTReceiveRestoreState()
    private var voicePTTStartReleaseState = RadioLiteVoicePTTStartReleaseState()
    private var voicePTTStartOwnership: RadioLiteVoicePTTStartOwnership?
    private var voicePTTReleaseState = RadioLiteVoicePTTReleaseState()
    private var voicePTTReceiveResumeTask: Task<Void, Never>?
    private var audioInterruptionReceiveRestore: RadioLiteReceiveMonitoringOwnership?
    private var audioInterruptionRecoveryTask: Task<Void, Never>?
    private var isAppActive = true
    private var keepsReceiveAudioInBackground = false
    private var radioConfigurationReconnectState = RadioLiteRadioConfigurationReconnectOwnershipState()
    private var activeTransmitToken: String?
    private var earlyTuningCompletionToken: String?
    private var voicePTTGeneration: UInt64?
    private var activeCaptureOwnership: RadioLiteMicrophoneCaptureOwnership?
    private var activeUplinkOwnership: RadioLiteUplinkOwnership?
    private var transmitEpoch = RadioLiteOperationEpoch()
    private var receiveAudioEpoch = RadioLiteOperationEpoch()
    private var receiveMonitoringIntent = RadioLiteReceiveMonitoringIntent()
    private var rigControlCatalogue = RadioLiteRigControlCatalogue()
    private var capabilityCatalogue = RadioLiteCapabilityCatalogue()
    private var noticeState = RadioLiteNoticeState()
    private var telemetrySubscriptionOwnership: RadioLiteTelemetrySubscriptionOwnership?

    private static let addressDefaultsKey = "radio-lite.server-address"
    private static let radioDefaultsKey = "radio-lite.selected-radio"

    init() {
        let audio = RadioLiteAudioEngine()
        self.audio = audio
        self.media = RadioLiteMediaClient(audio: audio)
        self.serverAddress = UserDefaults.standard.string(forKey: Self.addressDefaultsKey)
            ?? "http://localhost:8787"

        audio.onCaptureInterrupted = { [weak self] in
            self?.handleAudioSessionInterruption()
        }
        audio.onAudioReconfigurationDetected = { [weak self] microphoneWasCapturing in
            guard let self,
                  microphoneWasCapturing || self.isVoicePTTHeld || self.isTuning else { return }
            self.presentNotice(
                "音频设备发生变化，当前发射已安全停止；请确认耳机或蓝牙连接后重新发射",
                deduplicationKey: "audio.route-change.transmit-stopped"
            )
        }
        audio.onReceiveMayResume = { [weak self] in
            self?.resumeReceiveAudioAfterInterruption()
        }
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
    var canUseInternalTuner: Bool {
        canTransmit && tunerActionCapability != nil
    }
    var tunerActionCapability: RadioLiteCapabilityControl? {
        radioCapabilities.first { control in
            control.id == RadioLiteCapabilityProtocol.tunerActionId
                && control.access == .action
                && control.presentation == .button
        }
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
            serverFeatures = healthValue.features
            loginServerReachable = true
            setupRequired = setupValue.initializationRequired
        } catch {
            loginServerReachable = false
            setupRequired = false
        }
    }

    func restoreSession() async {
        if let startupRestoreTask {
            await startupRestoreTask.value
            return
        }
        let authenticationOwnership = authenticationOwnershipState.begin()
        await prepareForAuthentication()
        phase = .launching
        isRestoringSession = true
        errorMessage = nil
        let restoreTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.restoreStoredSession(authenticationOwnership: authenticationOwnership)
        }
        startupRestoreTask = restoreTask
        let deadlineTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(RadioLiteStartupRestorePolicy.deadline))
            } catch {
                return
            }
            await self?.cancelSessionRestore(
                expectedOwnership: authenticationOwnership,
                message: RadioLiteStartupRestorePolicy.timeoutMessage(
                    serverAddress: self?.serverAddress ?? "上次保存的地址"
                )
            )
        }
        startupRestoreDeadlineTask = deadlineTask
        await restoreTask.value
        guard authenticationOwnershipState.isCurrent(authenticationOwnership) else { return }
        startupRestoreTask = nil
        startupRestoreDeadlineTask?.cancel()
        startupRestoreDeadlineTask = nil
        isRestoringSession = false
    }

    func cancelSessionRestore() async {
        guard let ownership = authenticationOwnershipState.currentOwnership else { return }
        await cancelSessionRestore(
            expectedOwnership: ownership,
            message: "已停止连接上次服务器，请输入可用的服务器地址"
        )
    }

    private func cancelSessionRestore(
        expectedOwnership: RadioLiteAuthenticationOwnership,
        message: String
    ) async {
        guard startupRestoreTask != nil,
              authenticationOwnershipState.isCurrent(expectedOwnership) else { return }
        startupRestoreTask?.cancel()
        startupRestoreTask = nil
        startupRestoreDeadlineTask?.cancel()
        startupRestoreDeadlineTask = nil
        authenticationOwnershipState.invalidate()
        await prepareForAuthentication()
        isRestoringSession = false
        phase = .signedOut
        errorMessage = message
    }

    private func restoreStoredSession(
        authenticationOwnership: RadioLiteAuthenticationOwnership
    ) async {
        do {
            guard let stored = try credentialStore.load() else {
                try requireCurrentAuthentication(authenticationOwnership)
                phase = .signedOut
                return
            }
            try requireCurrentAuthentication(authenticationOwnership)
            serverAddress = stored.serverAddress
            var parsedServer = try RadioLiteServer(address: stored.serverAddress)
            var restoredCredential = stored.credential
            var restoredUsername = stored.username
            if case .device(let device) = restoredCredential,
               device.accessExpiresAtMs <= nowMs() + 30_000 {
                guard device.refreshExpiresAtMs > nowMs() else {
                    throw RadioLiteHTTPError.http(status: 401, code: "refresh_expired", message: "设备配对已过期，请重新配对")
                }
                let refreshServer = parsedServer
                let refreshUsername = restoredUsername
                let request = RadioLiteCredentialRefreshRequest(
                    server: refreshServer,
                    current: device
                )
                let accountOwnership: RadioLiteCredentialAccountOwnership
                if let existing = credentialAccountOwnershipState.ownership(
                    matching: request.key
                ) {
                    accountOwnership = existing
                } else {
                    accountOwnership = credentialAccountOwnershipState.activate(
                        server: refreshServer,
                        credential: device
                    )
                }
                do {
                    let lease = try await credentialRefreshCoordinator.refresh(
                        server: refreshServer,
                        current: device,
                        operation: { credential in
                            try await RadioLiteHTTPClient(server: refreshServer).refreshDevice(credential)
                        },
                        commit: { [weak self] refreshRequest, refreshed in
                            guard let self,
                                  self.authenticationOwnershipState.isCurrent(authenticationOwnership),
                                  self.credentialAccountOwnershipState.isCurrent(accountOwnership),
                                  refreshRequest.matches(
                                    server: refreshServer,
                                    credential: .device(device)
                                  ) else {
                                throw CancellationError()
                            }
                            try self.credentialStore.save(RadioLiteStoredLogin(
                                serverAddress: refreshServer.displayAddress,
                                credential: .device(refreshed),
                                username: refreshUsername
                            ))
                        }
                    )
                    restoredCredential = .device(lease.credentials)
                } catch {
                    try requireCurrentAuthentication(authenticationOwnership)
                    guard error is RadioLiteCredentialStoreError,
                          let pending = credentialRefreshCoordinator.pendingCommitCredentials(
                            server: refreshServer,
                            deviceId: device.deviceId
                          ) else {
                        throw error
                    }
                    restoredCredential = .device(pending)
                    presentNotice(
                        "刷新凭据已生效，正在后台重试安全保存",
                        deduplicationKey: "credential.persistence"
                    )
                    scheduleCredentialPersistenceRetry(
                        server: refreshServer,
                        credential: pending,
                        username: refreshUsername,
                        expectedRequest: request,
                        authenticationOwnership: authenticationOwnership
                    )
                }
                try requireCurrentAuthentication(authenticationOwnership)
                guard credentialAccountOwnershipState.isCurrent(accountOwnership) else {
                    throw CancellationError()
                }
            } else if case .browser = restoredCredential {
                let restored = try await RadioLiteHTTPClient(
                    server: parsedServer,
                    credential: restoredCredential
                ).currentSession()
                try requireCurrentAuthentication(authenticationOwnership)
                restoredCredential = restored.credential
                restoredUsername = restored.user.username
                parsedServer = try RadioLiteServer(address: stored.serverAddress)
            }
            try requireCurrentAuthentication(authenticationOwnership)
            try await finishAuthentication(
                server: parsedServer,
                credential: restoredCredential,
                username: restoredUsername,
                authenticationOwnership: authenticationOwnership
            )
        } catch is CancellationError {
            guard authenticationOwnershipState.isCurrent(authenticationOwnership) else { return }
            if phase == .launching || phase == .authenticating {
                phase = .signedOut
                errorMessage = "登录恢复已取消，请重试"
            }
        } catch {
            guard authenticationOwnershipState.isCurrent(authenticationOwnership) else { return }
            if shouldDiscardStoredCredential(after: error) {
                credentialAccountOwnershipState.invalidate()
                try? credentialStore.delete()
            }
            phase = .signedOut
            errorMessage = "登录恢复失败：\(error.localizedDescription)"
        }
    }

    func initializeServer(setupCode: String, username: String, password: String) async {
        await authenticate { authenticationOwnership in
            let server = try RadioLiteServer(address: self.serverAddress)
            let client = RadioLiteHTTPClient(server: server)
            _ = try await client.initialize(setupCode: setupCode, username: username, password: password)
            let login = try await client.login(username: username, password: password)
            try await self.persistAndFinish(
                server: server,
                credential: login.credential,
                username: login.user.username,
                authenticationOwnership: authenticationOwnership
            )
        }
    }

    func login(username: String, password: String) async {
        await authenticate { authenticationOwnership in
            let server = try RadioLiteServer(address: self.serverAddress)
            let login = try await RadioLiteHTTPClient(server: server).login(
                username: username,
                password: password
            )
            try await self.persistAndFinish(
                server: server,
                credential: login.credential,
                username: login.user.username,
                authenticationOwnership: authenticationOwnership
            )
        }
    }

    func login(pairingCode: String) async {
        await authenticate { authenticationOwnership in
            let code = pairingCode.filter(\.isNumber)
            guard code.count == 6 else {
                throw RadioLiteHTTPError.http(status: 400, code: "invalid_code", message: "配对码必须是 6 位数字")
            }
            let server = try RadioLiteServer(address: self.serverAddress)
            let credentials = try await RadioLiteHTTPClient(server: server).redeemPairingCode(
                code,
                deviceName: UIDevice.current.name
            )
            try await self.persistAndFinish(
                server: server,
                credential: .device(credentials),
                username: nil,
                authenticationOwnership: authenticationOwnership
            )
        }
    }

    func logout() async {
        authenticationOwnershipState.invalidate()
        credentialPersistenceRetryTask?.cancel()
        credentialPersistenceRetryTask = nil
        intentionalDisconnect = true
        _ = stopLocalTransmit()
        stopReceiveAudio()
        cancelRuntimeTasks()
        let logoutClient = http
        if case .browser = credential {
            Task { try? await logoutClient?.logout() }
        }
        await unsubscribeTelemetry()
        control.disconnect()
        media.disconnect()
        try? credentialStore.delete()
        clearAuthenticatedState()
        phase = .signedOut
        intentionalDisconnect = false
    }

    func acquireControl(
        force: Bool = false,
        expectedRadioId: String? = nil,
        reconnectOwnership: RadioLiteReconnectOwnership? = nil,
        configurationOwnership: RadioLiteRadioConfigurationReconnectOwnership? = nil,
        authenticationOwnership: RadioLiteAuthenticationOwnership? = nil
    ) async throws {
        let radioId = expectedRadioId ?? selectedRadioId
        guard let radioId else { throw RadioLiteSessionError.radioUnavailable }
        guard selectedRadioId == radioId,
              reconnectOwnership.map(reconnectOwnershipState.isCurrent) ?? true,
              configurationOwnership.map({
                  radioConfigurationReconnectState.isCurrent($0, selectedRadioId: selectedRadioId)
              }) ?? true,
              authenticationOwnership.map(authenticationOwnershipState.isCurrent) ?? true else {
            throw CancellationError()
        }
        var fields: [String: JSONValue] = [
            "t": .string("control.acquire"),
            "radioId": .string(radioId),
        ]
        if force { fields["force"] = .bool(true) }
        let reply = try await control.request(.object(fields), expecting: ["control.acquired"])
        guard let token = reply["controlToken"]?.stringValue else {
            throw RadioLiteSocketError.invalidWelcome
        }
        try Task.checkCancellation()
        guard selectedRadioId == radioId,
              reconnectOwnership.map(reconnectOwnershipState.isCurrent) ?? true,
              configurationOwnership.map({
                  radioConfigurationReconnectState.isCurrent($0, selectedRadioId: selectedRadioId)
              }) ?? true,
              authenticationOwnership.map(authenticationOwnershipState.isCurrent) ?? true else {
            throw CancellationError()
        }
        controlToken = token
        controlExpiresAtMs = reply["expiresAtMs"]?.int64Value
        startControlHeartbeat()
    }

    func releaseControl() async {
        endVoicePTT()
        endTuning(reason: .operatorCancellation)
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
        radioConfigurationReconnectState.invalidate()
        isWorking = true
        defer { isWorking = false }
        endVoicePTT()
        endTuning(reason: .operatorCancellation)
        let receiveGeneration = suspendReceiveAudio()
        pollingTask?.cancel()
        pollingTask = nil
        invalidateRigControlCatalogue()
        await unsubscribeTelemetry()
        await releaseControl()
        await media.unsubscribe()
        selectedRadioId = radioId
        UserDefaults.standard.set(radioId, forKey: Self.radioDefaultsKey)
        clearRadioState()
        let telemetryReady = await subscribeTelemetryIfAvailable(radioId: radioId)
        var mediaReady = true
        do {
            do {
                try await media.subscribe(radioId: radioId)
                guard selectedRadioId == radioId,
                      receiveMonitoringIntent.isCurrent(receiveGeneration),
                      media.subscribedRadioId == radioId else {
                    return
                }
                resolveMediaNotices()
                await restoreReceiveAudioAfterSubscription(
                    expectedRadioId: radioId,
                    generation: receiveGeneration
                )
            } catch is CancellationError {
                return
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
            await refreshRadioCapabilitiesAutomatically()
            await refreshRigControlsAutomatically()
            try await refreshDigitalSnapshot()
        } catch {
            errorMessage = error.localizedDescription
        }
        if !mediaReady {
            scheduleMediaRetry()
        }
        if !telemetryReady { startPolling() }
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

    func refreshRigState(
        expectedRadioId: String? = nil,
        reconnectOwnership: RadioLiteReconnectOwnership? = nil,
        configurationOwnership: RadioLiteRadioConfigurationReconnectOwnership? = nil,
        authenticationOwnership: RadioLiteAuthenticationOwnership? = nil
    ) async throws {
        let radioId = expectedRadioId ?? selectedRadioId
        guard let radioId else { throw RadioLiteSessionError.radioUnavailable }
        guard selectedRadioId == radioId else { throw CancellationError() }
        guard authenticationOwnership.map(authenticationOwnershipState.isCurrent) ?? true else {
            throw CancellationError()
        }
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
        try Task.checkCancellation()
        guard selectedRadioId == radioId,
              reconnectOwnership.map({ reconnectOwnershipState.isCurrent($0) }) ?? true,
              configurationOwnership.map({
                  radioConfigurationReconnectState.isCurrent($0, selectedRadioId: selectedRadioId)
              }) ?? true,
              authenticationOwnership.map(authenticationOwnershipState.isCurrent) ?? true else {
            throw CancellationError()
        }
        rigState = state
    }

    func refreshRigControls(
        authenticationOwnership: RadioLiteAuthenticationOwnership? = nil
    ) async throws {
        guard let radioId = selectedRadioId else { throw RadioLiteSessionError.radioUnavailable }
        guard authenticationOwnership.map(authenticationOwnershipState.isCurrent) ?? true else {
            throw CancellationError()
        }
        let catalogueGeneration = beginRigControlDiscovery()
        let commandId = UUID().uuidString
        do {
            let reply = try await control.request(
                RadioLiteRigControlProtocol.getRequest(radioId: radioId, commandId: commandId),
                expecting: ["rig.controls"],
                commandId: commandId
            )
            guard authenticationOwnership.map(authenticationOwnershipState.isCurrent) ?? true,
                  selectedRadioId == radioId,
                  rigControlCatalogue.isCurrent(catalogueGeneration) else {
                throw CancellationError()
            }
            guard let response: RadioLiteRigControlsResponse = reply.decoded(),
                  response.t == "rig.controls",
                  response.radioId == radioId,
                  response.commandId == commandId else {
                throw RadioLiteHTTPError.invalidResponse
            }
            guard rigControlCatalogue.publish(
                response.controls,
                generation: catalogueGeneration
            ) else {
                return
            }
            rigControls = rigControlCatalogue.controls
        } catch {
            guard authenticationOwnership.map(authenticationOwnershipState.isCurrent) ?? true,
                  selectedRadioId == radioId,
                  rigControlCatalogue.isCurrent(catalogueGeneration) else {
                throw CancellationError()
            }
            rigControls = rigControlCatalogue.controls
            throw error
        }
    }

    func refreshRadioCapabilities(
        authenticationOwnership: RadioLiteAuthenticationOwnership? = nil
    ) async throws {
        guard let radioId = selectedRadioId else { throw RadioLiteSessionError.radioUnavailable }
        guard authenticationOwnership.map(authenticationOwnershipState.isCurrent) ?? true else {
            throw CancellationError()
        }
        let catalogueGeneration = beginCapabilityDiscovery()
        let commandId = UUID().uuidString
        do {
            let reply = try await control.request(
                RadioLiteCapabilityProtocol.getRequest(radioId: radioId, commandId: commandId),
                expecting: ["rig.capabilities"],
                commandId: commandId
            )
            guard authenticationOwnership.map(authenticationOwnershipState.isCurrent) ?? true,
                  selectedRadioId == radioId,
                  capabilityCatalogue.isCurrent(catalogueGeneration) else {
                throw CancellationError()
            }
            guard let response: RadioLiteCapabilitiesResponse = reply.decoded(),
                  response.t == "rig.capabilities",
                  response.radioId == radioId,
                  response.commandId == commandId else {
                throw RadioLiteHTTPError.invalidResponse
            }
            guard capabilityCatalogue.publish(
                response.controls,
                generation: catalogueGeneration
            ) else { return }
            publishCapabilityCatalogue()
        } catch {
            guard authenticationOwnership.map(authenticationOwnershipState.isCurrent) ?? true,
                  selectedRadioId == radioId,
                  capabilityCatalogue.isCurrent(catalogueGeneration) else {
                throw CancellationError()
            }
            publishCapabilityCatalogue()
            throw error
        }
    }

    private func refreshRadioCapabilitiesAutomatically(
        authenticationOwnership: RadioLiteAuthenticationOwnership? = nil
    ) async {
        do {
            try await refreshRadioCapabilities(authenticationOwnership: authenticationOwnership)
        } catch {
            guard !(error is CancellationError),
                  authenticationOwnership.map(authenticationOwnershipState.isCurrent) ?? true else {
                return
            }
            // Older servers do not implement rig.capabilities. Keep the grouped surface
            // unavailable and let the existing flat controls remain as the fallback.
        }
    }

    private func refreshRigControlsAutomatically(
        authenticationOwnership: RadioLiteAuthenticationOwnership? = nil
    ) async {
        do {
            try await refreshRigControls(authenticationOwnership: authenticationOwnership)
        } catch {
            guard !(error is CancellationError),
                  authenticationOwnership.map(authenticationOwnershipState.isCurrent) ?? true else {
                return
            }
            errorMessage = "读取 Hamlib 控件失败：\(error.localizedDescription)"
        }
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
        let operationOwnership = RadioLiteRigControlOperationOwnership(
            radioId: radioId,
            catalogueGeneration: rigControlCatalogue.generation
        )

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
            guard operationOwnership.isCurrent(
                selectedRadioId: selectedRadioId,
                catalogueGeneration: rigControlCatalogue.generation
            ) else {
                return nil
            }
            let updatedControls = RadioLiteRigControlProtocol.applying(
                confirmation,
                to: rigControlCatalogue.controls
            )
            guard rigControlCatalogue.publish(
                updatedControls,
                generation: operationOwnership.catalogueGeneration
            ) else {
                return nil
            }
            rigControls = rigControlCatalogue.controls
            if confirmation.control.kind == .filter,
               confirmation.control.value.isFinite,
               confirmation.control.value > Double(Int.min),
               confirmation.control.value < Double(Int.max) {
                replaceRigState(passbandHz: Int(confirmation.control.value.rounded()))
            }
            return confirmation.control
        } catch {
            guard operationOwnership.isCurrent(
                selectedRadioId: selectedRadioId,
                catalogueGeneration: rigControlCatalogue.generation
            ) else {
                return nil
            }
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func setCapabilityControl(
        _ controlId: String,
        value requestedValue: RadioLiteControlValue
    ) async -> RadioLiteCapabilityControl? {
        guard let radioId = selectedRadioId, let controlToken else {
            errorMessage = RadioLiteSessionError.controlRequired.localizedDescription
            return nil
        }
        guard let current = radioCapabilities.first(where: { $0.id == controlId }) else {
            errorMessage = RadioLiteSessionError.rigControlUnavailable.localizedDescription
            return nil
        }
        let operationOwnership = RadioLiteRigControlOperationOwnership(
            radioId: radioId,
            catalogueGeneration: capabilityCatalogue.generation
        )
        let transmitting = isVoicePTTHeld || isTuning || rigState?.ptt == true
        let display = current.displayState(isTransmitting: transmitting, hasControl: true)
        guard display.isEnabled else {
            errorMessage = RadioLiteSessionError.rigControlLocked(
                display.disabledReason ?? "该控件当前不可调整"
            ).localizedDescription
            return nil
        }
        guard let value = current.validated(requestedValue) else {
            errorMessage = RadioLiteSessionError.invalidRigControlValue.localizedDescription
            return nil
        }

        isWorking = true
        defer { isWorking = false }
        do {
            let commandId = UUID().uuidString
            let reply = try await control.request(
                RadioLiteCapabilityProtocol.setRequest(
                    radioId: radioId,
                    controlToken: controlToken,
                    controlId: controlId,
                    value: value,
                    commandId: commandId
                ),
                expecting: ["rig.control.confirmed"],
                commandId: commandId
            )
            guard let confirmation: RadioLiteCapabilityControlConfirmation = reply.decoded(),
                  confirmation.t == "rig.control.confirmed",
                  confirmation.radioId == radioId,
                  confirmation.commandId == commandId,
                  confirmation.control.id == controlId else {
                throw RadioLiteHTTPError.invalidResponse
            }
            guard operationOwnership.isCurrent(
                selectedRadioId: selectedRadioId,
                catalogueGeneration: capabilityCatalogue.generation
            ) else { return nil }
            let updated = RadioLiteCapabilityProtocol.applying(
                confirmation,
                to: capabilityCatalogue.controls
            )
            guard capabilityCatalogue.publish(
                updated,
                generation: operationOwnership.catalogueGeneration
            ) else { return nil }
            publishCapabilityCatalogue()
            return radioCapabilities.first { $0.id == controlId }
        } catch {
            guard operationOwnership.isCurrent(
                selectedRadioId: selectedRadioId,
                catalogueGeneration: capabilityCatalogue.generation
            ) else { return nil }
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func invokeCapabilityAction(_ id: String) async -> Bool {
        guard let radioId = selectedRadioId, let controlToken else {
            errorMessage = RadioLiteSessionError.controlRequired.localizedDescription
            return false
        }
        guard let capability = radioCapabilities.first(where: { $0.id == id }),
              capability.access == .action,
              capability.presentation == .button,
              id != RadioLiteCapabilityProtocol.tunerActionId else {
            errorMessage = RadioLiteSessionError.rigControlUnavailable.localizedDescription
            return false
        }
        let transmitting = isVoicePTTHeld || isTuning || rigState?.ptt == true
        let display = capability.displayState(isTransmitting: transmitting, hasControl: true)
        guard display.isEnabled else {
            errorMessage = display.disabledReason
                ?? RadioLiteSessionError.rigControlUnavailable.localizedDescription
            return false
        }
        do {
            let commandId = UUID().uuidString
            let reply = try await control.request(
                RadioLiteCapabilityProtocol.actionRequest(
                    radioId: radioId,
                    controlToken: controlToken,
                    id: id,
                    commandId: commandId
                ),
                expecting: ["rig.action.confirmed"],
                commandId: commandId
            )
            guard let confirmation: RadioLiteActionConfirmation = reply.decoded(),
                  confirmation.t == "rig.action.confirmed",
                  confirmation.radioId == radioId,
                  confirmation.commandId == commandId,
                  confirmation.id == id,
                  confirmation.transmitToken == nil else {
                throw RadioLiteHTTPError.invalidResponse
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func startReceiveAudio() async {
        receiveMonitoringIntent.setDesired(true)
        let ownership = RadioLiteReceiveMonitoringOwnership(
            radioId: selectedRadioId ?? "",
            generation: receiveMonitoringIntent.activate()
        )
        guard !ownership.radioId.isEmpty else {
            errorMessage = RadioLiteSessionError.radioUnavailable.localizedDescription
            return
        }
        await startReceiveAudioIfDesired(ownership: ownership, subscribeIfNeeded: true)
    }

    private func startReceiveAudioIfDesired(
        ownership: RadioLiteReceiveMonitoringOwnership,
        subscribeIfNeeded: Bool
    ) async {
        guard receiveMonitoringIntent.shouldMonitor,
              ownership.isCurrent(
                selectedRadioId: selectedRadioId,
                generation: receiveMonitoringIntent.generation
              ) else {
            return
        }
        if let pending = receiveAudioStartupTask,
           receiveAudioStartupOwnership == ownership {
            await pending.value
            return
        }

        receiveAudioStartupTask?.cancel()
        let generation = receiveAudioEpoch.begin()
        receiveAudioStartupOwnership = ownership
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard self.media.state == .ready else { throw RadioLiteSocketError.notConnected }
                if self.media.subscribedRadioId != ownership.radioId {
                    guard subscribeIfNeeded else { return }
                    try await self.media.subscribe(radioId: ownership.radioId)
                    try Task.checkCancellation()
                    guard self.receiveAudioEpoch.owns(generation),
                          ownership.isCurrent(
                            selectedRadioId: self.selectedRadioId,
                            generation: self.receiveMonitoringIntent.generation
                          ),
                          self.media.subscribedRadioId == ownership.radioId else {
                        return
                    }
                    self.resolveMediaNotices()
                }
                try Task.checkCancellation()
                guard self.receiveAudioEpoch.owns(generation),
                      self.receiveMonitoringIntent.shouldMonitor,
                      ownership.isCurrent(
                        selectedRadioId: self.selectedRadioId,
                        generation: self.receiveMonitoringIntent.generation
                      ),
                      self.media.subscribedRadioId == ownership.radioId else {
                    return
                }
                try self.audio.startMonitoring()
                guard !Task.isCancelled,
                      self.receiveAudioEpoch.owns(generation),
                      self.receiveMonitoringIntent.shouldMonitor,
                      ownership.isCurrent(
                        selectedRadioId: self.selectedRadioId,
                        generation: self.receiveMonitoringIntent.generation
                      ),
                      self.media.subscribedRadioId == ownership.radioId else {
                    self.audio.stopMonitoring()
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      self.receiveAudioEpoch.owns(generation),
                      ownership.isCurrent(
                        selectedRadioId: self.selectedRadioId,
                        generation: self.receiveMonitoringIntent.generation
                      ) else {
                    return
                }
                self.errorMessage = "接收音频启动失败：\(error.localizedDescription)"
                if self.media.subscribedRadioId != ownership.radioId {
                    self.scheduleMediaRetry()
                }
            }
        }
        receiveAudioStartupTask = task
        await task.value
        if receiveAudioEpoch.owns(generation),
           receiveAudioStartupOwnership == ownership {
            receiveAudioStartupTask = nil
            receiveAudioStartupOwnership = nil
        }
    }

    func stopReceiveAudio() {
        receiveMonitoringIntent.setDesired(false)
        audioInterruptionReceiveRestore = nil
        audioInterruptionRecoveryTask?.cancel()
        audioInterruptionRecoveryTask = nil
        _ = suspendReceiveAudio()
    }

    @discardableResult
    private func suspendReceiveAudio() -> UInt64 {
        let generation = receiveMonitoringIntent.suspend()
        stopReceiveAudioLocally()
        return generation
    }

    private func restoreReceiveAudioAfterSubscription(
        expectedRadioId: String,
        generation: UInt64
    ) async {
        guard receiveMonitoringIntent.resume(
            generation: generation,
            expectedRadioId: expectedRadioId,
            selectedRadioId: selectedRadioId,
            subscribedRadioId: media.subscribedRadioId
        ) else {
            return
        }
        await startReceiveAudioIfDesired(
            ownership: RadioLiteReceiveMonitoringOwnership(
                radioId: expectedRadioId,
                generation: generation
            ),
            subscribeIfNeeded: false
        )
    }

    private func stopReceiveAudioLocally() {
        receiveAudioEpoch.invalidate()
        receiveAudioStartupTask?.cancel()
        receiveAudioStartupTask = nil
        receiveAudioStartupOwnership = nil
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
        voicePTTReleaseState.beginTransmit()
        voicePTTReceiveResumeTask?.cancel()
        voicePTTReceiveResumeTask = nil
        audioInterruptionRecoveryTask?.cancel()
        audioInterruptionRecoveryTask = nil
        audio.armPTTInterruptionFailSafe()
        voicePTTStartupTask?.cancel()
        let startOwnership = voicePTTStartReleaseState.begin()
        voicePTTStartOwnership = startOwnership
        let generation = transmitEpoch.begin()
        voicePTTGeneration = generation
        isVoicePTTHeld = true
        voicePTTStartupTask = RadioLiteVoicePTTStartup.schedule(
            requiresMediaSubscription: media.subscribedRadioId != radioId,
            prepareReceiveRecovery: { [weak self] in
                self?.transferMediaRetryMonitoringToVoicePTT(
                    radioId: radioId,
                    transmitGeneration: generation
                )
            }
        ) { [weak self] in
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
                    self.resolveMediaNotices(cancelRetry: false)
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
                guard self.voicePTTStartReleaseState.markStartDispatched(startOwnership) else {
                    self.audio.stopMicrophoneCapture(epoch: captureOwnership.epoch)
                    return
                }
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
                // The request continuation can finish after release cancelled this startup Task.
                // Consume ownership before checking cancellation so the late token is de-keyed.
                let disposition = self.voicePTTStartReleaseState.receiveStarted(startOwnership)
                if self.voicePTTStartOwnership == startOwnership {
                    self.voicePTTStartOwnership = nil
                }
                guard disposition != .ignore else {
                    self.audio.stopMicrophoneCapture(epoch: captureOwnership.epoch)
                    return
                }
                guard disposition == .bind,
                      !Task.isCancelled,
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
                self.voicePTTStartReleaseState.failStart(startOwnership)
                if self.voicePTTStartOwnership == startOwnership {
                    self.voicePTTStartOwnership = nil
                }
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
                    let receiveRestore = self.takeVoicePTTReceiveRestore(
                        transmitGeneration: generation,
                        reason: .transmitFailure
                    )
                    let stopped = self.stopLocalTransmit(expectedEpoch: generation)
                    if self.media.subscribedRadioId != radioId { self.scheduleMediaRetry() }
                    self.errorMessage = "PTT 启动失败：\(error.localizedDescription)"
                    if stopped {
                        self.finishReceiveMonitoringAfterTransmit(
                            reason: .transmitFailure,
                            voicePTTRestore: receiveRestore
                        )
                    }
                }
                if let startedToken {
                    await self.stopRemoteTransmit(radioId: radioId, transmitToken: startedToken)
                }
            }
        }
    }

    func endVoicePTT() {
        endVoicePTT(reason: .userRelease)
    }

    private func handleAudioSessionInterruption() {
        audioInterruptionRecoveryTask?.cancel()
        audioInterruptionRecoveryTask = nil
        let generation = suspendReceiveAudio()
        if receiveMonitoringIntent.isDesired, let radioId = selectedRadioId {
            audioInterruptionReceiveRestore = RadioLiteReceiveMonitoringOwnership(
                radioId: radioId,
                generation: generation
            )
        } else {
            audioInterruptionReceiveRestore = nil
        }
        endVoicePTT(reason: .audioInterruption)
        endTuning(reason: .audioInterruption)
    }

    private func resumeReceiveAudioAfterInterruption() {
        guard allowsReceiveMonitoringInCurrentScene,
              !isVoicePTTHeld, !isTuning, !audio.isCapturingMicrophone,
              receiveMonitoringIntent.isDesired,
              let radioId = selectedRadioId else { return }
        let ownership = audioInterruptionReceiveRestore
            ?? RadioLiteReceiveMonitoringOwnership(
                radioId: radioId,
                generation: receiveMonitoringIntent.generation
            )
        guard ownership.generation != 0 else { return }
        audioInterruptionReceiveRestore = ownership
        audioInterruptionRecoveryTask?.cancel()
        audioInterruptionRecoveryTask = Task { [weak self] in
            guard let self else { return }
            for delay in [0.0, 0.4, 1.0, 2.0, 4.0] {
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                }
                guard !Task.isCancelled,
                      self.allowsReceiveMonitoringInCurrentScene,
                      self.audioInterruptionReceiveRestore == ownership,
                      ownership.isCurrent(
                          selectedRadioId: self.selectedRadioId,
                          generation: self.receiveMonitoringIntent.generation
                      ),
                      !self.isVoicePTTHeld,
                      !self.isTuning,
                      !self.audio.isCapturingMicrophone else { return }
                await self.restoreOrRetryReceiveAudioAfterVoicePTT(ownership)
                if self.audio.isMonitoring {
                    self.audioInterruptionReceiveRestore = nil
                    self.audioInterruptionRecoveryTask = nil
                    return
                }
                guard ownership.isCurrent(
                    selectedRadioId: self.selectedRadioId,
                    generation: self.receiveMonitoringIntent.generation
                ) else {
                    self.audioInterruptionReceiveRestore = nil
                    self.audioInterruptionRecoveryTask = nil
                    return
                }
            }
            self.audioInterruptionRecoveryTask = nil
        }
    }

    private func endVoicePTT(reason: RadioLiteVoicePTTStopReason) {
        guard isVoicePTTHeld || voicePTTStartupTask != nil ||
                activeCaptureOwnership != nil || activeUplinkOwnership != nil else { return }
        let transmitToken = activeTransmitToken
        let radioId = selectedRadioId
        let receiveRestore = voicePTTGeneration.flatMap {
            takeVoicePTTReceiveRestore(
                transmitGeneration: $0,
                reason: reason
            )
        }
        _ = stopLocalTransmit(resumeMonitoringAfterCapture: false)
        finishReceiveMonitoringAfterTransmit(
            reason: reason,
            voicePTTRestore: receiveRestore
        )
        if let transmitToken, let radioId {
            Task { [weak self] in
                await self?.stopRemoteTransmit(radioId: radioId, transmitToken: transmitToken)
            }
        }
    }

    private func finishReceiveMonitoringAfterTransmit(
        reason: RadioLiteVoicePTTStopReason,
        voicePTTRestore: RadioLiteReceiveMonitoringOwnership? = nil
    ) {
        let releaseOwnership = voicePTTReleaseState.beginRelease()
        guard allowsReceiveMonitoringInCurrentScene, reason.restoresReceiveMonitoring,
              voicePTTReleaseState.mayResume(
                  releaseOwnership,
                  voicePTTHeld: isVoicePTTHeld,
                  tuning: isTuning,
                  capturingMicrophone: audio.isCapturingMicrophone
              ) else { return }

        audio.resumeAfterLocalTransmitRelease()
        voicePTTReceiveResumeTask?.cancel()
        voicePTTReceiveResumeTask = nil
        switch RadioLiteTransmitReceiveRecoverySource.select(
            voicePTTRestore: voicePTTRestore,
            audioInterruptionRestore: audioInterruptionReceiveRestore
        ) {
        case .voicePTT:
            guard let voicePTTRestore else { return }
            voicePTTReceiveResumeTask = Task { [weak self] in
                guard let self,
                      self.voicePTTReleaseState.mayResume(
                          releaseOwnership,
                          voicePTTHeld: self.isVoicePTTHeld,
                          tuning: self.isTuning,
                          capturingMicrophone: self.audio.isCapturingMicrophone
                      ) else { return }
                await self.restoreOrRetryReceiveAudioAfterVoicePTT(voicePTTRestore)
                if self.voicePTTReleaseState.mayResume(
                    releaseOwnership,
                    voicePTTHeld: self.isVoicePTTHeld,
                    tuning: self.isTuning,
                    capturingMicrophone: self.audio.isCapturingMicrophone
                ) {
                    self.voicePTTReceiveResumeTask = nil
                }
            }
        case .audioInterruption:
            resumeReceiveAudioAfterInterruption()
        case .none:
            break
        }
    }

    func beginTuning() {
        guard !isTuning, !isTuningPending, !isVoicePTTHeld else { return }
        guard canTransmit else {
            errorMessage = RadioLiteSessionError.transmitNotAllowed.localizedDescription
            return
        }
        guard let tunerActionCapability else {
            errorMessage = "当前电台或 Hamlib 后端不支持机内天调"
            return
        }
        guard let radioId = selectedRadioId, let token = controlToken else {
            errorMessage = RadioLiteSessionError.controlRequired.localizedDescription
            return
        }
        let transmitting = isVoicePTTHeld || isTuning || rigState?.ptt == true
        let tunerDisplay = tunerActionCapability.displayState(
            isTransmitting: transmitting,
            hasControl: true
        )
        guard tunerDisplay.isEnabled else {
            errorMessage = tunerDisplay.disabledReason
                ?? RadioLiteSessionError.rigControlUnavailable.localizedDescription
            return
        }
        voicePTTReleaseState.beginTransmit()
        voicePTTReceiveResumeTask?.cancel()
        voicePTTReceiveResumeTask = nil
        audioInterruptionRecoveryTask?.cancel()
        audioInterruptionRecoveryTask = nil
        tuningStartupTask?.cancel()
        tuningPendingTask?.cancel()
        let generation = transmitEpoch.begin()
        isTuning = true
        isTuningPending = true
        earlyTuningCompletionToken = nil
        tuningPendingTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled,
                  let self,
                  self.isTuningPending,
                  self.transmitEpoch.owns(generation) else { return }
            self.isTuningPending = false
            self.tuningPendingTask = nil
        }
        tuningStartupTask = Task { [weak self] in
            guard let self else { return }
            var startedToken: String?
            do {
                let commandId = UUID().uuidString
                let reply = try await self.control.request(
                    RadioLiteCapabilityProtocol.actionRequest(
                        radioId: radioId,
                        controlToken: token,
                        id: tunerActionCapability.id,
                        commandId: commandId
                    ),
                    expecting: ["rig.action.confirmed"],
                    commandId: commandId
                )
                guard let confirmation: RadioLiteActionConfirmation = reply.decoded(),
                      confirmation.t == "rig.action.confirmed",
                      confirmation.radioId == radioId,
                      confirmation.commandId == commandId,
                      confirmation.id == tunerActionCapability.id,
                      let transmitToken = confirmation.transmitToken else {
                    throw RadioLiteHTTPError.invalidResponse
                }
                startedToken = transmitToken
                if self.earlyTuningCompletionToken == transmitToken {
                    self.earlyTuningCompletionToken = nil
                    let stopped = self.stopLocalTransmit(expectedEpoch: generation)
                    if stopped {
                        self.finishReceiveMonitoringAfterTransmit(reason: .userRelease)
                    }
                    return
                }
                guard !Task.isCancelled,
                      self.isTuning,
                      self.transmitEpoch.owns(generation) else {
                    _ = await self.stopRemoteTransmit(
                        radioId: radioId,
                        transmitToken: transmitToken
                    )
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
                    let stopped = self.stopLocalTransmit(expectedEpoch: generation)
                    self.errorMessage = "机内天调启动失败：\(error.localizedDescription)"
                    if stopped {
                        self.finishReceiveMonitoringAfterTransmit(reason: .transmitFailure)
                    }
                }
                if let startedToken {
                    _ = await self.stopRemoteTransmit(
                        radioId: radioId,
                        transmitToken: startedToken
                    )
                }
            }
        }
    }

    func endTuning() {
        endTuning(reason: .userRelease)
    }

    func cancelTuning() {
        endTuning(reason: .operatorCancellation)
    }

    private func endTuning(reason: RadioLiteVoicePTTStopReason) {
        guard isTuning || tuningStartupTask != nil else { return }
        let transmitToken = activeTransmitToken
        let radioId = selectedRadioId
        guard stopLocalTransmit() else { return }
        finishReceiveMonitoringAfterTransmit(reason: reason)
        guard let transmitToken, let radioId else { return }
        Task { [weak self] in
            guard let self else { return }
            _ = await self.stopRemoteTransmit(
                radioId: radioId,
                transmitToken: transmitToken
            )
        }
    }

    private func reflectSuccessfulTunerStart(radioId: String) {
        guard selectedRadioId == radioId else { return }
        let generation = rigControlCatalogue.generation
        let updated = RadioLiteTunerInteractionPolicy.reflectingSuccessfulTuneStart(
            in: rigControlCatalogue.controls
        )
        guard rigControlCatalogue.publish(updated, generation: generation) else { return }
        rigControls = rigControlCatalogue.controls
    }

    private func handleTuningCompletion(_ completion: RadioLiteActionCompletion) {
        guard completion.id == RadioLiteCapabilityProtocol.tunerActionId,
              completion.radioId == selectedRadioId,
              isTuning else { return }
        if activeTransmitToken == nil, tuningStartupTask != nil {
            earlyTuningCompletionToken = completion.transmitToken
            isTuningPending = false
            tuningPendingTask?.cancel()
            tuningPendingTask = nil
            return
        }
        guard activeTransmitToken == completion.transmitToken else { return }
        let stopped = stopLocalTransmit()
        if stopped {
            finishReceiveMonitoringAfterTransmit(reason: .userRelease)
        }
    }

    func refreshDigitalSnapshot(
        expectedRadioId: String? = nil,
        reconnectOwnership: RadioLiteReconnectOwnership? = nil,
        authenticationOwnership: RadioLiteAuthenticationOwnership? = nil
    ) async throws {
        let radioId = expectedRadioId ?? selectedRadioId
        guard let radioId else { throw RadioLiteSessionError.radioUnavailable }
        guard selectedRadioId == radioId,
              authenticationOwnership.map(authenticationOwnershipState.isCurrent) ?? true else {
            throw CancellationError()
        }
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
        try Task.checkCancellation()
        guard selectedRadioId == radioId,
              reconnectOwnership.map({ reconnectOwnershipState.isCurrent($0) }) ?? true,
              authenticationOwnership.map(authenticationOwnershipState.isCurrent) ?? true else {
            throw CancellationError()
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

    func refreshLogs(
        limit: Int = 200,
        offset: Int = 0,
        authenticationOwnership: RadioLiteAuthenticationOwnership? = nil
    ) async {
        guard let ownership = authenticationOwnership
                ?? authenticationOwnershipState.currentOwnership,
              authenticationOwnershipState.isCurrent(ownership),
              let http else {
            return
        }
        do {
            async let page = http.logs(limit: limit, offset: offset)
            async let gridResponse = http.grids(resolution: 4)
            let (pageValue, gridValue) = try await (page, gridResponse)
            guard authenticationOwnershipState.isCurrent(ownership) else { return }
            qsos = pageValue.records
            qsoTotal = pageValue.total
            grids = gridValue.grids
        } catch {
            guard authenticationOwnershipState.isCurrent(ownership) else { return }
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

    func importADIF(data: Data) async throws -> (Int, Int) {
        guard isAdmin else { throw RadioLiteSessionError.administratorRequired }
        guard let http else { throw RadioLiteSessionError.notConnected }
        let result = try await http.importADIF(data)
        await refreshLogs()
        return (result.imported, result.duplicates)
    }

    func refreshUsers(
        authenticationOwnership: RadioLiteAuthenticationOwnership? = nil
    ) async {
        guard let ownership = authenticationOwnership
                ?? authenticationOwnershipState.currentOwnership,
              authenticationOwnershipState.isCurrent(ownership),
              isAdmin,
              let http else {
            return
        }
        do {
            let refreshedUsers = try await http.users()
            guard authenticationOwnershipState.isCurrent(ownership) else { return }
            users = refreshedUsers
        } catch {
            guard authenticationOwnershipState.isCurrent(ownership) else { return }
            errorMessage = "账户读取失败：\(error.localizedDescription)"
        }
    }

    func loadHardwareDiscovery() async throws -> RadioLiteHardwareDiscovery {
        guard isAdmin else { throw RadioLiteSessionError.administratorRequired }
        guard let http else { throw RadioLiteSessionError.notConnected }
        return try await http.hardwareDiscovery()
    }

    func testRadioConfiguration(
        _ profile: RadioLiteRadioProfile
    ) async throws -> RadioLiteHardwarePreflightResult {
        guard isAdmin else { throw RadioLiteSessionError.administratorRequired }
        guard let http else { throw RadioLiteSessionError.notConnected }
        if serverFeatures == nil {
            let health = try await http.health()
            guard health.service == "radio-lite", health.protocolVersion == 1 else {
                throw RadioLiteHTTPError.invalidResponse
            }
            serverFeatures = health.features
        }
        guard serverFeatures?.hardwarePreflight == true else {
            throw RadioLiteSessionError.hardwarePreflightUnavailable
        }
        do {
            return try await http.testHardware(profile)
        } catch let error as RadioLiteHTTPError {
            if case .http(let status, _, _) = error, status == 404 {
                throw RadioLiteSessionError.hardwarePreflightUnavailable
            }
            throw error
        }
    }

    @discardableResult
    func saveRadioConfiguration(
        _ profile: RadioLiteRadioProfile,
        confirmHardwareTransmission: Bool
    ) async throws -> Bool {
        guard isAdmin else { throw RadioLiteSessionError.administratorRequired }
        guard let http else { throw RadioLiteSessionError.notConnected }

        radioConfigurationReconnectState.invalidate()
        isWorking = true
        defer { isWorking = false }
        endVoicePTT()
        endTuning(reason: .operatorCancellation)

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
        guard selectedRadioId == response.radio.id else {
            presentNotice("设备配置已保存")
            return true
        }
        let operationOwnership = radioConfigurationReconnectState.begin(radioId: response.radio.id)
        let receiveGeneration = suspendReceiveAudio()
        invalidateRigControlCatalogue()
        controlHeartbeatTask?.cancel()
        controlHeartbeatTask = nil
        controlToken = nil
        controlExpiresAtMs = nil
        var controlReady = true
        do {
            try await acquireControl(
                expectedRadioId: operationOwnership.radioId,
                configurationOwnership: operationOwnership
            )
        } catch is CancellationError {
            return false
        } catch {
            guard radioConfigurationReconnectState.isCurrent(
                operationOwnership,
                selectedRadioId: selectedRadioId
            ) else {
                return false
            }
            controlReady = false
        }
        do {
            guard radioConfigurationReconnectState.isCurrent(
                operationOwnership,
                selectedRadioId: selectedRadioId
            ) else {
                return false
            }
            try await media.subscribe(radioId: operationOwnership.radioId)
            guard radioConfigurationReconnectState.isCurrent(
                    operationOwnership,
                    selectedRadioId: selectedRadioId
                  ),
                  receiveMonitoringIntent.isCurrent(receiveGeneration),
                  media.subscribedRadioId == operationOwnership.radioId else {
                return false
            }
            resolveMediaNotices()
            await restoreReceiveAudioAfterSubscription(
                expectedRadioId: operationOwnership.radioId,
                generation: receiveGeneration
            )
            try await refreshRigState(
                expectedRadioId: operationOwnership.radioId,
                configurationOwnership: operationOwnership
            )
            await refreshRadioCapabilitiesAutomatically()
            await refreshRigControlsAutomatically()
            guard radioConfigurationReconnectState.complete(
                operationOwnership,
                selectedRadioId: selectedRadioId
            ) else {
                return false
            }
            presentNotice(
                controlReady
                    ? "设备配置已保存，电台与音频已重新连接"
                    : "设备配置和媒体已生效，但当前未取得电台控制权"
            )
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard radioConfigurationReconnectState.complete(
                operationOwnership,
                selectedRadioId: selectedRadioId
            ) else {
                return false
            }
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
        let decision = AudioRuntimePolicy.backgroundDecision(
            receiveAudioDesired: receiveMonitoringIntent.isDesired
        )
        keepsReceiveAudioInBackground = decision.keepsReceiving
        isAppActive = false
        endVoicePTT()
        endTuning(reason: .operatorCancellation)
        if decision.cancelsReceiveRecovery {
            voicePTTReleaseState.beginTransmit()
            voicePTTReceiveResumeTask?.cancel()
            voicePTTReceiveResumeTask = nil
            audioInterruptionRecoveryTask?.cancel()
            audioInterruptionRecoveryTask = nil
        }
        if decision.suspendsReceiveAudio {
            let generation = suspendReceiveAudio()
            if receiveMonitoringIntent.isDesired, let radioId = selectedRadioId {
                audioInterruptionReceiveRestore = RadioLiteReceiveMonitoringOwnership(
                    radioId: radioId,
                    generation: generation
                )
            }
        }
        media.setSpectrumVisible(decision.spectrumVisible)
    }

    func appDidBecomeActive() {
        isAppActive = true
        keepsReceiveAudioInBackground = false
        media.setSpectrumVisible(true)
        guard phase == .ready else { return }
        resumeReceiveAudioAfterInterruption()
        if case .device(let device) = credential, credentialNeedsRefresh(device) {
            credentialRefreshTask?.cancel()
            credentialRefreshTask = Task { [weak self] in
                await self?.refreshCredentialAndReconnect()
            }
        } else if control.state != .ready || media.state != .ready {
            scheduleReconnect()
        }
    }

    func reconnectNow() {
        reconnectTask?.cancel()
        credentialRefreshTask?.cancel()
        reconnectOwnershipState.invalidate()
        reconnectTask = nil
        credentialRefreshTask = nil
        scheduleReconnect()
    }

    private func authenticate(
        _ operation: (RadioLiteAuthenticationOwnership) async throws -> Void
    ) async {
        let authenticationOwnership = authenticationOwnershipState.begin()
        await prepareForAuthentication()
        phase = .authenticating
        isWorking = true
        errorMessage = nil
        resetNotices()
        defer { isWorking = false }
        do {
            try await operation(authenticationOwnership)
            try requireCurrentAuthentication(authenticationOwnership)
        } catch {
            guard authenticationOwnershipState.isCurrent(authenticationOwnership) else { return }
            phase = .signedOut
            errorMessage = error.localizedDescription
        }
    }

    private func persistAndFinish(
        server: RadioLiteServer,
        credential: RadioLiteCredential,
        username: String?,
        authenticationOwnership: RadioLiteAuthenticationOwnership
    ) async throws {
        try requireCurrentAuthentication(authenticationOwnership)
        let stored = RadioLiteStoredLogin(
            serverAddress: server.displayAddress,
            credential: credential,
            username: username
        )
        try credentialStore.save(stored)
        try requireCurrentAuthentication(authenticationOwnership)
        UserDefaults.standard.set(server.displayAddress, forKey: Self.addressDefaultsKey)
        try await finishAuthentication(
            server: server,
            credential: credential,
            username: username,
            authenticationOwnership: authenticationOwnership
        )
    }

    private func finishAuthentication(
        server: RadioLiteServer,
        credential: RadioLiteCredential,
        username: String?,
        authenticationOwnership: RadioLiteAuthenticationOwnership
    ) async throws {
        try requireCurrentAuthentication(authenticationOwnership)
        phase = .authenticating
        let receiveGeneration = suspendReceiveAudio()
        invalidateRigControlCatalogue()
        intentionalDisconnect = true
        cancelRuntimeTasks()
        await unsubscribeTelemetry()
        control.disconnect()
        media.disconnect()
        intentionalDisconnect = false

        self.server = server
        self.credential = credential
        self.username = username
        self.http = RadioLiteHTTPClient(server: server, credential: credential)
        if case .device(let device) = credential {
            _ = credentialAccountOwnershipState.activate(server: server, credential: device)
        } else {
            credentialAccountOwnershipState.invalidate()
        }

        let controlWelcome = try await control.connect(server: server, credential: credential)
        try requireCurrentAuthentication(authenticationOwnership)
        let mediaWelcome = try await media.connect(server: server, credential: credential)
        try requireCurrentAuthentication(authenticationOwnership)
        guard controlWelcome.principal.userId == mediaWelcome.principal.userId else {
            throw RadioLiteHTTPError.invalidResponse
        }
        principal = controlWelcome.principal
        radios = controlWelcome.radios
        guard !radios.isEmpty else { throw RadioLiteSessionError.radioUnavailable }

        let preferred = UserDefaults.standard.string(forKey: Self.radioDefaultsKey)
        selectedRadioId = radios.contains(where: { $0.id == preferred }) ? preferred : radios[0].id
        guard let radioId = selectedRadioId else { throw RadioLiteSessionError.radioUnavailable }
        let telemetryReady = await subscribeTelemetryIfAvailable(radioId: radioId)
        var mediaReady = true
        do {
            try await media.subscribe(radioId: radioId)
            guard authenticationOwnershipState.isCurrent(authenticationOwnership),
                  selectedRadioId == radioId,
                  receiveMonitoringIntent.isCurrent(receiveGeneration),
                  media.subscribedRadioId == radioId else {
                throw CancellationError()
            }
            resolveMediaNotices()
            await restoreReceiveAudioAfterSubscription(
                expectedRadioId: radioId,
                generation: receiveGeneration
            )
            try requireCurrentAuthentication(authenticationOwnership)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            mediaReady = false
            presentMediaNotice(error)
        }
        do {
            try await acquireControl(authenticationOwnership: authenticationOwnership)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            controlToken = nil
            presentNotice("已连接，但电台控制权当前由其他操作员持有")
        }
        try await refreshRigState(authenticationOwnership: authenticationOwnership)
        await refreshRadioCapabilitiesAutomatically(authenticationOwnership: authenticationOwnership)
        await refreshRigControlsAutomatically(authenticationOwnership: authenticationOwnership)
        try requireCurrentAuthentication(authenticationOwnership)
        do {
            try await refreshDigitalSnapshot(authenticationOwnership: authenticationOwnership)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            presentNotice("FT8/FT4 暂不可用：\(error.localizedDescription)")
        }
        try requireCurrentAuthentication(authenticationOwnership)
        phase = .ready
        if !telemetryReady { startPolling() }
        scheduleCredentialRefresh()
        if !mediaReady {
            scheduleMediaRetry()
        }
        Task { [weak self] in
            await self?.refreshLogs(authenticationOwnership: authenticationOwnership)
            await self?.refreshUsers(authenticationOwnership: authenticationOwnership)
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
        case "rig.telemetry":
            if let sample: RadioLiteTelemetry = value.decoded(),
               telemetrySubscriptionOwnership?.owns(sample) == true {
                telemetry = sample
                rigState = sample.state
            }
        case "control.alive":
            controlExpiresAtMs = value["expiresAtMs"]?.int64Value
        case "rig.action.completed":
            if let completion: RadioLiteActionCompletion = value.decoded() {
                handleTuningCompletion(completion)
            }
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
                    self.endTuning(reason: .operatorCancellation)
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

    private func subscribeTelemetryIfAvailable(radioId: String) async -> Bool {
        do {
            try await subscribeTelemetry(radioId: radioId)
            return true
        } catch {
            return false
        }
    }

    private func subscribeTelemetry(radioId: String) async throws {
        let ownership = RadioLiteTelemetrySubscriptionOwnership(radioId: radioId)
        telemetrySubscriptionOwnership = ownership
        telemetry = nil
        let commandId = UUID().uuidString
        do {
            _ = try await control.request(
                ownership.subscribeMessage(commandId: commandId),
                expecting: ["rig.telemetry.subscribed"],
                commandId: commandId
            )
            guard selectedRadioId == radioId,
                  telemetrySubscriptionOwnership == ownership else {
                throw CancellationError()
            }
        } catch {
            if telemetrySubscriptionOwnership == ownership {
                telemetrySubscriptionOwnership = nil
                telemetry = nil
            }
            throw error
        }
    }

    private func unsubscribeTelemetry() async {
        guard let ownership = telemetrySubscriptionOwnership else {
            telemetry = nil
            return
        }
        telemetrySubscriptionOwnership = nil
        telemetry = nil
        guard control.state == .ready else { return }
        let commandId = UUID().uuidString
        _ = try? await control.request(
            ownership.unsubscribeMessage(commandId: commandId),
            expecting: ["rig.telemetry.unsubscribed"],
            commandId: commandId
        )
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
                    let receiveRestore = self.takeVoicePTTReceiveRestore(
                        transmitGeneration: generation,
                        reason: .transmitFailure
                    )
                    guard self.stopLocalTransmit(expectedEpoch: generation) else { return }
                    self.errorMessage = "发射心跳中断：\(error.localizedDescription)"
                    self.finishReceiveMonitoringAfterTransmit(
                        reason: .transmitFailure,
                        voicePTTRestore: receiveRestore
                    )
                    await self.stopRemoteTransmit(radioId: radioId, transmitToken: transmitToken)
                    return
                }
            }
        }
    }

    @discardableResult
    private func stopRemoteTransmit(
        radioId: String,
        transmitToken: String
    ) async -> Bool {
        let commandId = UUID().uuidString
        do {
            _ = try await control.request(
                .object([
                    "t": .string("tx.stop"),
                    "radioId": .string(radioId),
                    "transmitToken": .string(transmitToken),
                    "commandId": .string(commandId),
                ]),
                expecting: ["tx.stopped"],
                commandId: commandId
            )
            return true
        } catch {
            return false
        }
    }

    private func takeVoicePTTReceiveRestore(
        transmitGeneration: UInt64,
        reason: RadioLiteVoicePTTStopReason
    ) -> RadioLiteReceiveMonitoringOwnership? {
        guard reason.restoresReceiveMonitoring else {
            voicePTTReceiveRestoreState.invalidate()
            return nil
        }
        return voicePTTReceiveRestoreState.take(transmitGeneration: transmitGeneration)
    }

    @discardableResult
    private func stopLocalTransmit(
        expectedEpoch: UInt64? = nil,
        resumeMonitoringAfterCapture: Bool = true
    ) -> Bool {
        if let expectedEpoch, !transmitEpoch.owns(expectedEpoch) { return false }
        if let startOwnership = voicePTTStartOwnership {
            voicePTTStartReleaseState.release(startOwnership)
            voicePTTStartOwnership = nil
        }
        voicePTTReleaseState.beginTransmit()
        voicePTTReceiveResumeTask?.cancel()
        voicePTTReceiveResumeTask = nil
        transmitEpoch.invalidate()
        voicePTTStartupTask?.cancel()
        tuningStartupTask?.cancel()
        tuningPendingTask?.cancel()
        voicePTTStartupTask = nil
        tuningStartupTask = nil
        tuningPendingTask = nil
        voicePTTGeneration = nil
        isVoicePTTHeld = false
        isTuning = false
        isTuningPending = false
        earlyTuningCompletionToken = nil
        if let capture = activeCaptureOwnership {
            audio.stopMicrophoneCapture(
                epoch: capture.epoch,
                resumeMonitoringAfterCapture: resumeMonitoringAfterCapture
            )
        } else {
            audio.stopMicrophoneCapture(
                resumeMonitoringAfterCapture: resumeMonitoringAfterCapture
            )
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
        voicePTTReceiveRestoreState.invalidate()
        return true
    }

    private func handleConnectionLoss(_ error: Error) {
        audioInterruptionReceiveRestore = nil
        audioInterruptionRecoveryTask?.cancel()
        audioInterruptionRecoveryTask = nil
        if let generation = voicePTTGeneration {
            _ = takeVoicePTTReceiveRestore(
                transmitGeneration: generation,
                reason: .connectionLoss
            )
        }
        stopLocalTransmit()
        suspendReceiveAudio()
        invalidateRigControlCatalogue()
        controlToken = nil
        controlExpiresAtMs = nil
        telemetrySubscriptionOwnership = nil
        telemetry = nil
        guard !intentionalDisconnect, phase == .ready else { return }
        presentNotice(
            "连接中断，正在自动重连：\(error.localizedDescription)",
            deduplicationKey: "connection.loss:\(error.localizedDescription)"
        )
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil, phase == .ready else { return }
        let ownership = reconnectOwnershipState.begin()
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            var delay = 2.0
            while !Task.isCancelled,
                  self.phase == .ready,
                  self.reconnectOwnershipState.isCurrent(ownership) {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled,
                      self.reconnectOwnershipState.isCurrent(ownership) else {
                    self.clearReconnect(ownership)
                    return
                }

                if case .device(let device) = self.credential,
                   self.credentialNeedsRefresh(device) {
                    do {
                        try await self.refreshCredential()
                        try self.requireCurrentReconnect(ownership)
                    } catch {
                        switch RadioLiteReconnectFailurePolicy.disposition(
                            for: error,
                            stage: .credentialRefresh
                        ) {
                        case .benign:
                            self.clearReconnect(ownership)
                            return
                        case .retry:
                            guard self.reconnectOwnershipState.isCurrent(ownership) else { return }
                            self.presentNotice(
                                "凭据刷新暂时失败，将继续尝试：\(error.localizedDescription)",
                                deduplicationKey: "credential.refresh:\(error.localizedDescription)"
                            )
                            delay = min(30, delay * 1.8)
                            continue
                        case .signOut:
                            await self.signOutAfterCredentialRefreshFailure(
                                error,
                                reconnectOwnership: ownership
                            )
                            return
                        }
                    }
                }

                do {
                    try self.requireCurrentReconnect(ownership)
                    guard let server = self.server, let credential = self.credential else {
                        throw RadioLiteSessionError.notConnected
                    }
                    let mediaReady = try await self.reconnectChannels(
                        server: server,
                        credential: credential,
                        reconnectOwnership: ownership
                    )
                    try self.requireCurrentReconnect(ownership)
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
                    self.clearReconnect(ownership)
                    return
                } catch {
                    switch RadioLiteReconnectFailurePolicy.disposition(
                        for: error,
                        stage: .channelReconnect
                    ) {
                    case .benign:
                        self.clearReconnect(ownership)
                        return
                    case .retry:
                        guard self.reconnectOwnershipState.isCurrent(ownership) else { return }
                        self.presentNotice(
                            "重连失败，将继续尝试：\(error.localizedDescription)",
                            deduplicationKey: "connection.reconnect:\(error.localizedDescription)"
                        )
                        delay = min(30, delay * 1.8)
                    case .signOut:
                        await self.signOutAfterCredentialRefreshFailure(
                            error,
                            reconnectOwnership: ownership
                        )
                        return
                    }
                }
            }
            self.clearReconnect(ownership)
        }
    }

    private func requireCurrentReconnect(_ ownership: RadioLiteReconnectOwnership?) throws {
        try Task.checkCancellation()
        guard let ownership else { return }
        guard reconnectOwnershipState.isCurrent(ownership) else {
            throw CancellationError()
        }
    }

    private func requireCurrentAuthentication(
        _ ownership: RadioLiteAuthenticationOwnership
    ) throws {
        try Task.checkCancellation()
        guard authenticationOwnershipState.isCurrent(ownership) else {
            throw CancellationError()
        }
    }

    private func clearReconnect(_ ownership: RadioLiteReconnectOwnership) {
        guard reconnectOwnershipState.complete(ownership) else { return }
        reconnectTask = nil
    }

    private func signOutAfterCredentialRefreshFailure(
        _ error: Error,
        reconnectOwnership: RadioLiteReconnectOwnership
    ) async {
        guard reconnectOwnershipState.isCurrent(reconnectOwnership) else { return }
        let storedLogin = server.flatMap { server in
            credential.map { credential in
                RadioLiteStoredLogin(
                    serverAddress: server.displayAddress,
                    credential: credential,
                    username: username
                )
            }
        }
        clearReconnect(reconnectOwnership)
        authenticationOwnershipState.invalidate()
        credentialPersistenceRetryTask?.cancel()
        credentialPersistenceRetryTask = nil
        credentialAccountOwnershipState.invalidate()
        intentionalDisconnect = true
        _ = stopLocalTransmit()
        stopReceiveAudio()
        cancelRuntimeTasks()
        await unsubscribeTelemetry()
        control.disconnect()
        media.disconnect()
        clearAuthenticatedState()
        if let storedLogin {
            try? credentialStore.delete(ifMatching: storedLogin)
        }
        phase = .signedOut
        errorMessage = "设备配对刷新失败，请重新配对：\(error.localizedDescription)"
        intentionalDisconnect = false
    }

    private func reconnectChannels(
        server: RadioLiteServer,
        credential: RadioLiteCredential,
        reconnectOwnership: RadioLiteReconnectOwnership? = nil
    ) async throws -> Bool {
        try requireCurrentReconnect(reconnectOwnership)
        let receiveGeneration = suspendReceiveAudio()
        invalidateRigControlCatalogue()
        intentionalDisconnect = true
        await unsubscribeTelemetry()
        control.disconnect()
        media.disconnect()
        intentionalDisconnect = false
        let welcome = try await control.connect(server: server, credential: credential)
        try requireCurrentReconnect(reconnectOwnership)
        _ = try await media.connect(server: server, credential: credential)
        try requireCurrentReconnect(reconnectOwnership)
        principal = welcome.principal
        radios = welcome.radios
        guard let radioId = selectedRadioId, radios.contains(where: { $0.id == radioId }) else {
            throw RadioLiteSessionError.radioUnavailable
        }
        let telemetryReady = await subscribeTelemetryIfAvailable(radioId: radioId)
        var mediaReady = true
        do {
            try await media.subscribe(radioId: radioId)
            try requireCurrentReconnect(reconnectOwnership)
            guard selectedRadioId == radioId,
                  receiveMonitoringIntent.isCurrent(receiveGeneration),
                  media.subscribedRadioId == radioId else {
                throw CancellationError()
            }
            resolveMediaNotices()
            await restoreReceiveAudioAfterSubscription(
                expectedRadioId: radioId,
                generation: receiveGeneration
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            mediaReady = false
            presentMediaNotice(error)
        }
        do {
            try await acquireControl(
                expectedRadioId: radioId,
                reconnectOwnership: reconnectOwnership
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try requireCurrentReconnect(reconnectOwnership)
            controlToken = nil
        }
        try await refreshRigState(
            expectedRadioId: radioId,
            reconnectOwnership: reconnectOwnership
        )
        await refreshRadioCapabilitiesAutomatically()
        await refreshRigControlsAutomatically()
        try requireCurrentReconnect(reconnectOwnership)
        try? await refreshDigitalSnapshot(
            expectedRadioId: radioId,
            reconnectOwnership: reconnectOwnership
        )
        try requireCurrentReconnect(reconnectOwnership)
        if !telemetryReady { startPolling() }
        return mediaReady
    }

    private func scheduleCredentialRefresh() {
        credentialRefreshTask?.cancel()
        guard case .device(let device) = credential else { return }
        credentialRefreshTask = Task { [weak self] in
            guard let self else { return }
            let hasPendingCommit = self.server.map {
                self.credentialRefreshCoordinator.hasPendingCommit(
                    server: $0,
                    deviceId: device.deviceId
                )
            } ?? false
            let delay = hasPendingCommit
                ? 1
                : max(1, Double(device.accessExpiresAtMs - self.nowMs() - 60_000) / 1_000)
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self.refreshCredentialAndReconnect()
        }
    }

    private func scheduleCredentialPersistenceRetry(
        server: RadioLiteServer,
        credential: RadioLiteDeviceCredentials,
        username: String?,
        expectedRequest: RadioLiteCredentialRefreshRequest,
        authenticationOwnership: RadioLiteAuthenticationOwnership
    ) {
        credentialPersistenceRetryTask?.cancel()
        credentialPersistenceRetryTask = Task { [weak self] in
            guard let self else { return }
            var delay = 1.0
            while !Task.isCancelled,
                  self.authenticationOwnershipState.isCurrent(authenticationOwnership) {
                do {
                    let lease = try await self.credentialRefreshCoordinator.refresh(
                        server: server,
                        current: credential,
                        operation: { _ in throw CancellationError() },
                        commit: { [weak self] request, refreshed in
                            guard let self,
                                  self.authenticationOwnershipState.isCurrent(authenticationOwnership),
                                  request == expectedRequest,
                                  refreshed == credential else {
                                throw CancellationError()
                            }
                            try self.credentialStore.save(RadioLiteStoredLogin(
                                serverAddress: server.displayAddress,
                                credential: .device(refreshed),
                                username: username
                            ))
                        }
                    )
                    guard self.authenticationOwnershipState.isCurrent(authenticationOwnership),
                          lease.request == expectedRequest,
                          lease.credentials == credential else {
                        return
                    }
                    self.resolveCredentialNotices()
                    self.credentialPersistenceRetryTask = nil
                    return
                } catch is CancellationError {
                    return
                } catch {
                    guard self.authenticationOwnershipState.isCurrent(authenticationOwnership) else {
                        return
                    }
                    self.presentNotice(
                        "安全保存暂时失败，正在后台重试：\(error.localizedDescription)",
                        deduplicationKey: "credential.persistence"
                    )
                    try? await Task.sleep(for: .seconds(delay))
                    delay = min(30, delay * 1.8)
                }
            }
        }
    }

    private func credentialNeedsRefresh(_ device: RadioLiteDeviceCredentials) -> Bool {
        if device.accessExpiresAtMs <= nowMs() + 30_000 { return true }
        guard let server else { return false }
        return credentialRefreshCoordinator.hasPendingCommit(
            server: server,
            deviceId: device.deviceId
        )
    }

    private func shouldDiscardStoredCredential(after error: Error) -> Bool {
        if let httpError = error as? RadioLiteHTTPError, httpError.isUnauthorized {
            return true
        }
        if let keychainError = error as? RadioLiteCredentialStoreError,
           case .unexpectedData = keychainError {
            return true
        }
        return false
    }

    private func scheduleMediaRetry() {
        guard phase == .ready, let radioId = selectedRadioId else { return }
        let ownership = RadioLiteReceiveMonitoringOwnership(
            radioId: radioId,
            generation: suspendReceiveAudio()
        )
        mediaRetryTask?.cancel()
        mediaRetryOwnership = ownership
        mediaRetryTask = Task { [weak self] in
            guard let self else { return }
            var delay = 2.0
            while !Task.isCancelled, self.phase == .ready {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled,
                      self.isCurrentMediaRetry(ownership) else {
                    self.clearMediaRetry(ownership)
                    return
                }
                guard self.media.state == .ready else {
                    self.clearMediaRetry(ownership)
                    self.scheduleReconnect()
                    return
                }
                do {
                    try await self.media.subscribe(radioId: ownership.radioId)
                    guard self.isCurrentMediaRetry(ownership),
                          self.media.subscribedRadioId == ownership.radioId else {
                        self.clearMediaRetry(ownership)
                        return
                    }
                    self.resolveMediaNotices(cancelRetry: false)
                    await self.restoreReceiveAudioAfterSubscription(
                        expectedRadioId: ownership.radioId,
                        generation: ownership.generation
                    )
                    self.clearMediaRetry(ownership)
                    return
                } catch is CancellationError {
                    self.clearMediaRetry(ownership)
                    return
                } catch {
                    guard self.isCurrentMediaRetry(ownership) else {
                        self.clearMediaRetry(ownership)
                        return
                    }
                    self.presentMediaNotice(error)
                    delay = min(30, delay * 1.8)
                }
            }
            self.clearMediaRetry(ownership)
        }
    }

    private func transferMediaRetryMonitoringToVoicePTT(
        radioId: String,
        transmitGeneration: UInt64
    ) {
        guard let monitoring = mediaRetryOwnership,
              monitoring.radioId == radioId,
              isCurrentMediaRetry(monitoring) else { return }
        mediaRetryTask?.cancel()
        mediaRetryTask = nil
        mediaRetryOwnership = nil
        voicePTTReceiveRestoreState.assign(
            monitoring,
            transmitGeneration: transmitGeneration
        )
    }

    private func restoreOrRetryReceiveAudioAfterVoicePTT(
        _ ownership: RadioLiteReceiveMonitoringOwnership
    ) async {
        guard allowsReceiveMonitoringInCurrentScene,
              ownership.isCurrent(
            selectedRadioId: selectedRadioId,
            generation: receiveMonitoringIntent.generation
        ) else {
            return
        }
        guard media.subscribedRadioId == ownership.radioId else {
            scheduleMediaRetry()
            return
        }
        await restoreReceiveAudioAfterSubscription(
            expectedRadioId: ownership.radioId,
            generation: ownership.generation
        )
    }

    private var allowsReceiveMonitoringInCurrentScene: Bool {
        AudioRuntimePolicy.allowsReceiveRecovery(
            isAppActive: isAppActive,
            keepsReceivingInBackground: keepsReceiveAudioInBackground
        )
    }

    private func isCurrentMediaRetry(_ ownership: RadioLiteReceiveMonitoringOwnership) -> Bool {
        mediaRetryOwnership == ownership
            && ownership.isCurrent(
                selectedRadioId: selectedRadioId,
                generation: receiveMonitoringIntent.generation
            )
    }

    private func clearMediaRetry(_ ownership: RadioLiteReceiveMonitoringOwnership) {
        guard mediaRetryOwnership == ownership else { return }
        mediaRetryTask = nil
        mediaRetryOwnership = nil
    }

    private func refreshCredentialAndReconnect() async {
        reconnectTask?.cancel()
        reconnectTask = nil
        let ownership = reconnectOwnershipState.begin()

        do {
            try await refreshCredential()
            try requireCurrentReconnect(ownership)
        } catch {
            switch RadioLiteReconnectFailurePolicy.disposition(
                for: error,
                stage: .credentialRefresh
            ) {
            case .benign:
                clearReconnect(ownership)
            case .retry:
                guard reconnectOwnershipState.isCurrent(ownership) else { return }
                presentNotice(
                    "凭据刷新暂时失败，连接恢复将在后台继续：\(error.localizedDescription)",
                    deduplicationKey: "credential.refresh:\(error.localizedDescription)"
                )
                clearReconnect(ownership)
                scheduleReconnect()
            case .signOut:
                await signOutAfterCredentialRefreshFailure(error, reconnectOwnership: ownership)
            }
            return
        }

        do {
            try requireCurrentReconnect(ownership)
            guard let server, let credential else {
                throw RadioLiteSessionError.notConnected
            }
            let mediaReady = try await reconnectChannels(
                server: server,
                credential: credential,
                reconnectOwnership: ownership
            )
            try requireCurrentReconnect(ownership)
            scheduleCredentialRefresh()
            if !mediaReady {
                scheduleMediaRetry()
            }
            clearReconnect(ownership)
        } catch {
            switch RadioLiteReconnectFailurePolicy.disposition(
                for: error,
                stage: .channelReconnect
            ) {
            case .benign:
                clearReconnect(ownership)
            case .retry:
                guard reconnectOwnershipState.isCurrent(ownership) else { return }
                presentNotice(
                    "凭据已刷新，连接恢复将在后台继续：\(error.localizedDescription)",
                    deduplicationKey: "connection.reconnect:\(error.localizedDescription)"
                )
                clearReconnect(ownership)
                scheduleReconnect()
            case .signOut:
                await signOutAfterCredentialRefreshFailure(error, reconnectOwnership: ownership)
            }
        }
    }

    private func refreshCredential() async throws {
        guard let server, case .device(let current) = credential else { return }
        let request = RadioLiteCredentialRefreshRequest(server: server, current: current)
        guard let accountOwnership = credentialAccountOwnershipState.ownership(
            matching: request.key
        ) else {
            throw CancellationError()
        }
        let lease = try await credentialRefreshCoordinator.refresh(
            server: server,
            current: current,
            operation: { credential in
                try await RadioLiteHTTPClient(server: server).refreshDevice(credential)
            },
            commit: { [weak self] refreshRequest, refreshed in
                guard let self,
                      self.credentialAccountOwnershipState.isCurrent(accountOwnership),
                      refreshRequest.matchesCurrentOrRefreshed(
                        server: self.server,
                        credential: self.credential,
                        refreshed: refreshed
                      ) else {
                    throw CancellationError()
                }

                let updated: RadioLiteCredential = .device(refreshed)
                let stored = RadioLiteStoredLogin(
                    serverAddress: server.displayAddress,
                    credential: updated,
                    username: self.username
                )
                do {
                    try self.credentialStore.save(stored)
                } catch {
                    // The server has already rotated the token. Keep the new
                    // credential alive in memory while the coordinator retains
                    // the response for a persistence-only retry.
                    self.credential = updated
                    self.http = RadioLiteHTTPClient(server: server, credential: updated)
                    throw error
                }
                self.credential = updated
                self.http = RadioLiteHTTPClient(server: server, credential: updated)
            }
        )
        guard credentialAccountOwnershipState.isCurrent(accountOwnership),
              lease.request.key == request.key else {
            throw CancellationError()
        }
        resolveCredentialNotices()
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
        tuningPendingTask?.cancel()
        receiveAudioStartupTask?.cancel()
        voicePTTReceiveResumeTask?.cancel()
        audioInterruptionRecoveryTask?.cancel()
        transmitEpoch.invalidate()
        receiveAudioEpoch.invalidate()
        reconnectOwnershipState.invalidate()
        credentialAccountOwnershipState.invalidate()
        radioConfigurationReconnectState.invalidate()
        voicePTTReceiveRestoreState.invalidate()
        voicePTTReleaseState.beginTransmit()
        audioInterruptionReceiveRestore = nil
        voicePTTReceiveResumeTask = nil
        audioInterruptionRecoveryTask = nil
        controlHeartbeatTask = nil
        pollingTask = nil
        transmitHeartbeatTask = nil
        credentialRefreshTask = nil
        reconnectTask = nil
        mediaRetryTask = nil
        mediaRetryOwnership = nil
        voicePTTStartupTask = nil
        voicePTTGeneration = nil
        tuningStartupTask = nil
        tuningPendingTask = nil
        isTuningPending = false
        earlyTuningCompletionToken = nil
        receiveAudioStartupTask = nil
        receiveAudioStartupOwnership = nil
    }

    private func prepareForAuthentication() async {
        credentialPersistenceRetryTask?.cancel()
        credentialPersistenceRetryTask = nil
        intentionalDisconnect = true
        _ = stopLocalTransmit()
        stopReceiveAudio()
        cancelRuntimeTasks()
        await unsubscribeTelemetry()
        control.disconnect()
        media.disconnect()
        clearAuthenticatedState()
        intentionalDisconnect = false
    }

    private func clearAuthenticatedState() {
        server = nil
        credential = nil
        http = nil
        serverFeatures = nil
        principal = nil
        username = nil
        radios = []
        selectedRadioId = nil
        controlToken = nil
        controlExpiresAtMs = nil
        rigState = nil
        telemetrySubscriptionOwnership = nil
        telemetry = nil
        invalidateRigControlCatalogue()
        decodeBatches = []
        callQueue = nil
        automaticQSO = nil
        qsos = []
        qsoTotal = 0
        grids = []
        users = []
        issuedPairingCode = nil
        resetNotices()
    }

    private func clearRadioState() {
        controlToken = nil
        controlExpiresAtMs = nil
        rigState = nil
        telemetrySubscriptionOwnership = nil
        telemetry = nil
        invalidateRigControlCatalogue()
        decodeBatches = []
        callQueue = nil
        automaticQSO = nil
    }

    @discardableResult
    private func beginRigControlDiscovery() -> UInt64 {
        let generation = rigControlCatalogue.beginDiscovery()
        rigControls = rigControlCatalogue.controls
        return generation
    }

    @discardableResult
    private func beginCapabilityDiscovery() -> UInt64 {
        let generation = capabilityCatalogue.beginDiscovery()
        publishCapabilityCatalogue()
        return generation
    }

    private func publishCapabilityCatalogue() {
        radioCapabilities = capabilityCatalogue.controls
        radioCapabilitiesAvailable = capabilityCatalogue.isAvailable
    }

    private func invalidateRigControlCatalogue() {
        rigControlCatalogue.invalidate()
        rigControls = rigControlCatalogue.controls
        capabilityCatalogue.invalidate()
        publishCapabilityCatalogue()
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

    private func resolveMediaNotices(cancelRetry: Bool = true) {
        if cancelRetry {
            mediaRetryTask?.cancel()
            mediaRetryTask = nil
            mediaRetryOwnership = nil
        }
        noticeState.resolve(keysWithPrefix: "media.")
        noticeMessage = noticeState.message
    }

    private func resolveModeNotices() {
        noticeState.resolve(keysWithPrefix: "rig.mode.")
        noticeMessage = noticeState.message
    }

    private func resolveCredentialNotices() {
        noticeState.resolve(keysWithPrefix: "credential.")
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
            ptt: ptt ?? current.ptt,
            supportsInternalTuner: current.supportsInternalTuner
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
