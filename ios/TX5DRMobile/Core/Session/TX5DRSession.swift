import Combine
import Foundation

enum TX5DRSessionPhase: Equatable {
    case launching
    case signedOut
    case authenticating
    case ready
    case failed(String)
}

enum TX5DRSessionError: LocalizedError {
    case viewerNotSupported
    case notConnected
    case invalidFrequency
    case operatorRequired
    case adminRequired
    case rigctldPermissionRequired

    var errorDescription: String? {
        switch self {
        case .viewerNotSupported: "此 App 不提供观察员模式，请使用管理员或操作员账户"
        case .notConnected: "尚未连接 TX-5DR 服务器"
        case .invalidFrequency: "请输入有效的 MHz 频率"
        case .operatorRequired: "请先选择一个操作员"
        case .adminRequired: "此操作需要管理员账户"
        case .rigctldPermissionRequired: "当前账户没有 Rigctld 桥管理权限"
        }
    }
}

@MainActor
final class TX5DRSession: ObservableObject {
    @Published private(set) var phase: TX5DRSessionPhase = .launching
    @Published var serverAddress: String
    @Published private(set) var currentUser: AuthMeResponse?
    @Published private(set) var pairingAvailable = false
    @Published private(set) var loginServerReachable = false
    @Published private(set) var availableModes: [ModeDescriptor] = []
    @Published private(set) var profiles: [RadioProfile] = []
    @Published private(set) var activeProfileId: String?
    @Published private(set) var supportedRigs: [SupportedRig] = []
    @Published private(set) var serialPorts: [SerialPortInfo] = []
    @Published private(set) var audioDevices: AudioDevicesResponse?
    @Published private(set) var powerSupport: [String: RadioPowerSupportInfo] = [:]
    @Published private(set) var operators: [RadioOperatorConfig] = []
    @Published private(set) var logbooks: [LogbookInfo] = []
    @Published private(set) var logbookDetails: [String: LogbookDetail] = [:]
    @Published private(set) var logbookBackups: [String: LogbookBackupStatus] = [:]
    @Published private(set) var qsos: [QSORecord] = []
    @Published private(set) var accounts: [AuthTokenInfo] = []
    @Published private(set) var selectedOperatorId: String?
    @Published private(set) var selectedLogbookId: String?
    @Published private(set) var voiceKeyerPanel: VoiceKeyerPanel?
    @Published private(set) var cwMessagePanel: CWMessagePanel?
    @Published private(set) var cwKeyerConfig: CWKeyerConfig?
    @Published private(set) var cwDecoderConfig: CWDecoderConfig?
    @Published private(set) var cwDecoderBackends: [CWDecoderBackendDescriptor] = []
    @Published private(set) var pskReporterConfig: PSKReporterConfig?
    @Published private(set) var pskReporterStatus: PSKReporterStatus?
    @Published private(set) var rigctldStatus: RigctldStatus?
    @Published private(set) var openWebRXStations: [OpenWebRXStation] = []
    @Published private(set) var openWebRXListenStatus: OpenWebRXListenStatus?
    @Published private(set) var isVoicePTTHeld = false
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?
    @Published var noticeMessage: String?

    let radio = RadioWebSocket()
    let audio = TX5DRAudioClient()
    let openWebRXAudio = TX5DRAudioClient()

    private let tokenStore = KeychainTokenStore()
    private var apiClient: TX5DRAPIClient?
    private var server: TX5DRServer?
    private var jwt: String?
    private var pttTask: Task<Void, Never>?
    private var pttGeneration = 0

    private static let serverDefaultsKey = "tx5dr.serverAddress"
    private static let operatorDefaultsKey = "tx5dr.selectedOperator"

    init() {
        serverAddress = UserDefaults.standard.string(forKey: Self.serverDefaultsKey) ?? "http://localhost:8076"
    }

    var isAuthenticated: Bool {
        if case .ready = phase { return true }
        return false
    }

    var isAdmin: Bool { currentUser?.role == .admin }

    var canManageRigctld: Bool {
        if isAdmin { return true }
        return currentUser?.permissionGrants?.contains {
            $0["permission"]?.stringValue == "rigctld:bridge"
        } == true
    }

    var selectedOperator: RadioOperatorConfig? {
        guard let selectedOperatorId else { return nil }
        return operators.first { $0.id == selectedOperatorId }
    }

    var keyerCallsign: String? {
        guard let rawCallsign = selectedOperator?.myCallsign else { return nil }
        let callsign = rawCallsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !callsign.isEmpty else { return nil }
        return callsign
    }

    var effectiveCWDecoderConfig: CWDecoderConfig? { radio.cwDecoder?.config ?? cwDecoderConfig }

    func probeLoginCapabilities() async {
        do {
            let parsedServer = try TX5DRServer(address: serverAddress)
            let client = TX5DRAPIClient(server: parsedServer)
            _ = try await client.authStatus()
            guard !Task.isCancelled else { return }
            loginServerReachable = true
            pairingAvailable = await client.supportsMobilePairing()
        } catch {
            guard !Task.isCancelled else { return }
            loginServerReachable = false
            pairingAvailable = false
        }
    }

    func restoreSession() async {
        phase = .launching
        errorMessage = nil
        do {
            guard let savedJWT = try tokenStore.load(), !savedJWT.isEmpty else {
                phase = .signedOut
                return
            }
            let parsedServer = try TX5DRServer(address: serverAddress)
            let client = TX5DRAPIClient(server: parsedServer, jwt: savedJWT)
            let me = try await client.me()
            try ensureSupportedRole(me.role)
            try await finishLogin(server: parsedServer, client: client, jwt: savedJWT, user: me)
        } catch {
            try? tokenStore.delete()
            phase = .signedOut
            errorMessage = "登录恢复失败：\(error.localizedDescription)"
        }
    }

    func login(username: String, password: String) async {
        await performAuthentication {
            let parsedServer = try TX5DRServer(address: self.serverAddress)
            let client = TX5DRAPIClient(server: parsedServer)
            let login = try await client.login(username: username, password: password)
            try self.ensureSupportedRole(login.role)
            let me = try await client.me()
            try await self.finishLogin(server: parsedServer, client: client, jwt: login.jwt, user: me)
        }
    }

    func login(permanentToken: String) async {
        await performAuthentication {
            let parsedServer = try TX5DRServer(address: self.serverAddress)
            let client = TX5DRAPIClient(server: parsedServer)
            let login = try await client.login(token: permanentToken)
            try self.ensureSupportedRole(login.role)
            let me = try await client.me()
            try await self.finishLogin(server: parsedServer, client: client, jwt: login.jwt, user: me)
        }
    }

    func login(pairingCode: String) async {
        await performAuthentication {
            let parsedServer = try TX5DRServer(address: self.serverAddress)
            let client = TX5DRAPIClient(server: parsedServer)
            let normalized = pairingCode.filter(\.isNumber)
            guard normalized.count == 6 else {
                throw NSError(
                    domain: "TX5DRPairing",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "配对码必须是 6 位数字"]
                )
            }
            let login = try await client.exchangeMobilePairingCode(normalized)
            try self.ensureSupportedRole(login.role)
            let me = try await client.me()
            try await self.finishLogin(server: parsedServer, client: client, jwt: login.jwt, user: me)
        }
    }

    func logout() {
        endVoicePTT()
        audio.stopAll()
        openWebRXAudio.stopAll()
        radio.disconnect()
        try? tokenStore.delete()
        apiClient = nil
        server = nil
        jwt = nil
        currentUser = nil
        profiles = []
        activeProfileId = nil
        supportedRigs = []
        serialPorts = []
        audioDevices = nil
        powerSupport = [:]
        availableModes = []
        operators = []
        logbooks = []
        logbookDetails = [:]
        logbookBackups = [:]
        qsos = []
        accounts = []
        voiceKeyerPanel = nil
        cwMessagePanel = nil
        cwKeyerConfig = nil
        cwDecoderConfig = nil
        cwDecoderBackends = []
        pskReporterConfig = nil
        pskReporterStatus = nil
        rigctldStatus = nil
        openWebRXStations = []
        openWebRXListenStatus = nil
        selectedOperatorId = nil
        selectedLogbookId = nil
        phase = .signedOut
    }

    func refreshPrimaryData() async {
        guard let apiClient else { return }
        isWorking = true
        defer { isWorking = false }

        do {
            let response = try await apiClient.profiles()
            profiles = response.profiles
            activeProfileId = response.activeProfileId
        } catch { recordNonfatal("读取电台 Profile 失败", error: error) }

        do { availableModes = try await apiClient.modes() }
        catch { recordNonfatal("读取模式失败", error: error) }

        do {
            operators = try await apiClient.operators()
            resolveSelectedOperator()
        } catch { recordNonfatal("读取操作员失败", error: error) }

        do {
            logbooks = try await apiClient.logbooks()
            if selectedLogbookId == nil || !logbooks.contains(where: { $0.id == selectedLogbookId }) {
                selectedLogbookId = logbooks.first(where: \.isActive)?.id ?? logbooks.first?.id
            }
        } catch { recordNonfatal("读取日志本失败", error: error) }

        if isAdmin {
            do { accounts = try await apiClient.accounts() }
            catch { recordNonfatal("读取账户失败", error: error) }

            do { openWebRXStations = try await apiClient.openWebRXStations() }
            catch { recordNonfatal("读取 OpenWebRX 站点失败", error: error) }
        }
    }

    func refreshProfiles() async {
        guard let apiClient else { return fail(TX5DRSessionError.notConnected) }
        do {
            let response = try await apiClient.profiles()
            profiles = response.profiles
            activeProfileId = response.activeProfileId
        } catch {
            fail(error)
        }
    }

    func loadProfileEditorResources() async {
        guard isAdmin, let apiClient else { return }
        async let rigsRequest = apiClient.supportedRigs()
        async let portsRequest = apiClient.serialPorts()
        async let audioRequest = apiClient.audioDevices()
        do { supportedRigs = try await rigsRequest }
        catch { recordNonfatal("读取 Hamlib 型号失败", error: error) }
        do { serialPorts = try await portsRequest }
        catch { recordNonfatal("读取串口失败", error: error) }
        do { audioDevices = try await audioRequest }
        catch { recordNonfatal("读取音频设备失败", error: error) }
    }

    func createProfile(name: String, description: String?, radio: JSONValue, audio: JSONValue) async -> Bool {
        guard isAdmin, let apiClient else {
            fail(TX5DRSessionError.adminRequired)
            return false
        }
        var created = false
        await performOperation(success: "Profile 已创建") {
            let profile = try await apiClient.createProfile(
                name: name,
                description: description,
                radio: radio,
                audio: audio
            )
            let response = try await apiClient.profiles()
            self.profiles = response.profiles
            self.activeProfileId = response.activeProfileId
            created = self.profiles.contains(where: { $0.id == profile.id })
        }
        return created
    }

    func updateProfile(id: String, name: String, description: String?, radio: JSONValue, audio: JSONValue) async -> Bool {
        guard isAdmin, let apiClient else {
            fail(TX5DRSessionError.adminRequired)
            return false
        }
        var updated = false
        await performOperation(success: "Profile 已更新") {
            _ = try await apiClient.updateProfile(
                id: id,
                name: name,
                description: description,
                radio: radio,
                audio: audio
            )
            let response = try await apiClient.profiles()
            self.profiles = response.profiles
            self.activeProfileId = response.activeProfileId
            updated = true
        }
        return updated
    }

    func deleteProfile(_ profile: RadioProfile) async {
        guard isAdmin, let apiClient else { return fail(TX5DRSessionError.adminRequired) }
        await performOperation(success: "Profile 已删除") {
            try await apiClient.deleteProfile(id: profile.id)
            let response = try await apiClient.profiles()
            self.profiles = response.profiles
            self.activeProfileId = response.activeProfileId
            self.powerSupport[profile.id] = nil
        }
    }

    func activateProfile(_ profile: RadioProfile) async {
        guard isAdmin, let apiClient else { return fail(TX5DRSessionError.adminRequired) }
        await performOperation(success: "已切换至 \(profile.name)") {
            let result = try await apiClient.activateProfile(id: profile.id)
            self.activeProfileId = result.profile.id
            let response = try await apiClient.profiles()
            self.profiles = response.profiles
            self.activeProfileId = response.activeProfileId
        }
    }

    func reorderProfiles(_ profileIds: [String]) async {
        guard isAdmin, let apiClient else { return fail(TX5DRSessionError.adminRequired) }
        await performOperation {
            try await apiClient.reorderProfiles(ids: profileIds)
            let response = try await apiClient.profiles()
            self.profiles = response.profiles
            self.activeProfileId = response.activeProfileId
        }
    }

    func loadPowerSupport(profileId: String) async {
        guard isAdmin, let apiClient else { return }
        do { powerSupport[profileId] = try await apiClient.radioPowerSupport(profileId: profileId) }
        catch { powerSupport[profileId] = nil }
    }

    func setRadioPower(profile: RadioProfile, target: RadioPowerTarget) async {
        guard isAdmin, let apiClient else { return fail(TX5DRSessionError.adminRequired) }
        await performOperation(success: "\(profile.name) 电源命令已提交") {
            _ = try await apiClient.setRadioPower(profileId: profile.id, target: target)
        }
    }

    func selectOperator(_ id: String?) {
        selectedOperatorId = id
        voiceKeyerPanel = nil
        cwMessagePanel = nil
        if let id { UserDefaults.standard.set(id, forKey: Self.operatorDefaultsKey) }
        else { UserDefaults.standard.removeObject(forKey: Self.operatorDefaultsKey) }
        radio.setSelectedOperator(id)
        Task { await loadKeyerPanels() }
    }

    func createOperator(_ request: SaveRadioOperatorRequest) async -> Bool {
        guard let apiClient else {
            fail(TX5DRSessionError.notConnected)
            return false
        }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let created = try await apiClient.createOperator(request)
            operators = try await apiClient.operators()
            selectOperator(created.id)
            noticeMessage = "操作员已创建"
            return true
        } catch {
            fail(error)
            return false
        }
    }

    func updateOperator(id: String, request: SaveRadioOperatorRequest) async -> Bool {
        guard let apiClient else {
            fail(TX5DRSessionError.notConnected)
            return false
        }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            _ = try await apiClient.updateOperator(id: id, request: request)
            operators = try await apiClient.operators()
            resolveSelectedOperator()
            noticeMessage = "操作员已更新"
            return true
        } catch {
            fail(error)
            return false
        }
    }

    func deleteOperator(id: String) async {
        guard let apiClient else { return fail(TX5DRSessionError.notConnected) }
        await performOperation(success: "操作员已删除") {
            try await apiClient.deleteOperator(id: id)
            self.operators = try await apiClient.operators()
            if self.selectedOperatorId == id { self.selectedOperatorId = nil }
            self.resolveSelectedOperator()
            self.radio.setSelectedOperator(self.selectedOperatorId)
        }
    }

    func selectLogbook(_ id: String?) {
        selectedLogbookId = id
        Task { await loadQSOs() }
    }

    func switchMode(_ mode: ModeDescriptor) async {
        guard let apiClient else { return fail(TX5DRSessionError.notConnected) }
        await performOperation(success: "已切换至 \(mode.name)") {
            _ = try await apiClient.switchMode(mode)
        }
    }

    func setFrequency(mhzText: String, radioMode: String? = nil) async {
        guard let apiClient else { return fail(TX5DRSessionError.notConnected) }
        guard let mhz = Double(mhzText.replacingOccurrences(of: ",", with: ".")), mhz > 0 else {
            return fail(TX5DRSessionError.invalidFrequency)
        }
        let hz = mhz * 1_000_000
        let engineMode = radio.currentMode.name
        let band = Self.bandName(for: hz)
        await performOperation(success: "频率已设为 \(String(format: "%.6f", mhz)) MHz") {
            try await apiClient.setFrequency(hz, mode: engineMode, band: band, radioMode: radioMode)
        }
    }

    func setTuner(enabled: Bool) async {
        guard let apiClient else { return fail(TX5DRSessionError.notConnected) }
        await performOperation(success: enabled ? "天调已启用" : "天调已旁路") {
            try await apiClient.setTuner(enabled: enabled)
        }
    }

    func startTuning() async {
        guard let apiClient else { return fail(TX5DRSessionError.notConnected) }
        await performOperation(success: "天调调谐完成") {
            try await apiClient.startTuning()
        }
    }

    func toggleListening() async {
        do {
            if audio.listeningState == .streaming || audio.listeningState == .ready {
                audio.stopListening()
            } else {
                try await audio.startListening()
            }
        } catch {
            fail(error)
        }
    }

    func beginVoicePTT() {
        guard !isVoicePTTHeld else { return }
        guard let selectedOperatorId else {
            fail(TX5DRSessionError.operatorRequired)
            return
        }
        isVoicePTTHeld = true
        pttGeneration += 1
        let generation = pttGeneration
        pttTask?.cancel()
        pttTask = Task { [weak self] in
            guard let self else { return }
            do {
                let identity = try await self.audio.prepareUplink()
                guard self.isVoicePTTHeld, generation == self.pttGeneration else { return }
                try await self.audio.beginMicrophoneCapture()
                guard self.isVoicePTTHeld, generation == self.pttGeneration else {
                    self.audio.stopMicrophoneCapture()
                    return
                }
                self.radio.requestVoicePTT(audioClientId: identity, operatorId: selectedOperatorId)
            } catch is CancellationError {
                self.audio.stopMicrophoneCapture()
            } catch {
                self.isVoicePTTHeld = false
                self.audio.stopMicrophoneCapture()
                self.fail(error)
            }
        }
    }

    func endVoicePTT() {
        guard isVoicePTTHeld || radio.ptt.isTransmitting else { return }
        isVoicePTTHeld = false
        pttGeneration += 1
        pttTask?.cancel()
        pttTask = nil
        radio.releaseVoicePTT()
        audio.stopMicrophoneCapture()
    }

    func forceStopTransmission() {
        isVoicePTTHeld = false
        pttGeneration += 1
        pttTask?.cancel()
        pttTask = nil
        audio.stopMicrophoneCapture()
        radio.forceStopTransmission()
    }

    func requestFT8Call(_ callsign: String) {
        guard let selectedOperatorId else { return fail(TX5DRSessionError.operatorRequired) }
        let normalized = callsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalized.isEmpty else { return }
        radio.requestCall(operatorId: selectedOperatorId, callsign: normalized)
    }

    func setOperatorRunning(_ running: Bool) {
        guard let selectedOperatorId else { return fail(TX5DRSessionError.operatorRequired) }
        if running { radio.startOperator(selectedOperatorId) }
        else { radio.stopOperator(selectedOperatorId) }
    }

    func sendCW(_ text: String, callsign: String? = nil) {
        guard let selectedOperatorId else { return fail(TX5DRSessionError.operatorRequired) }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        radio.sendCWText(normalized, operatorId: selectedOperatorId, callsign: callsign)
    }

    func setCWKey(down: Bool) {
        guard let selectedOperatorId else { return fail(TX5DRSessionError.operatorRequired) }
        radio.setCWKey(down: down, operatorId: selectedOperatorId)
    }

    func loadKeyerPanels() async {
        guard let apiClient, let callsign = keyerCallsign else {
            voiceKeyerPanel = nil
            cwMessagePanel = nil
            cwKeyerConfig = nil
            return
        }

        do { voiceKeyerPanel = try await apiClient.voiceKeyerPanel(callsign: callsign) }
        catch { recordNonfatal("读取语音键控器失败", error: error) }

        do { cwMessagePanel = try await apiClient.cwMessagePanel(callsign: callsign) }
        catch { recordNonfatal("读取 CW 报文槽失败", error: error) }

        do { cwKeyerConfig = try await apiClient.cwKeyerConfig() }
        catch { recordNonfatal("读取 CW 键控配置失败", error: error) }
    }

    func updateVoiceKeyerSlotCount(_ slotCount: Int) async {
        guard let apiClient, let callsign = keyerCallsign else { return fail(TX5DRSessionError.operatorRequired) }
        await performOperation(success: "语音槽位数量已更新") {
            self.voiceKeyerPanel = try await apiClient.updateVoiceKeyerPanel(
                callsign: callsign,
                slotCount: slotCount
            )
        }
    }

    func updateVoiceKeyerSlot(_ slotId: String, update: VoiceKeyerSlotUpdate) async {
        guard let apiClient, let callsign = keyerCallsign else { return fail(TX5DRSessionError.operatorRequired) }
        await performOperation {
            self.voiceKeyerPanel = try await apiClient.updateVoiceKeyerSlot(
                callsign: callsign,
                slotId: slotId,
                update: update
            )
        }
    }

    func uploadVoiceKeyerAudio(slotId: String, wavData: Data) async -> Bool {
        guard let apiClient, let callsign = keyerCallsign else {
            fail(TX5DRSessionError.operatorRequired)
            return false
        }
        do {
            isWorking = true
            defer { isWorking = false }
            voiceKeyerPanel = try await apiClient.uploadVoiceKeyerAudio(
                callsign: callsign,
                slotId: slotId,
                wavData: wavData
            )
            noticeMessage = "语音录音已保存"
            return true
        } catch {
            fail(error)
            return false
        }
    }

    func downloadVoiceKeyerAudio(slotId: String) async throws -> Data {
        guard let apiClient, let callsign = keyerCallsign else { throw TX5DRSessionError.operatorRequired }
        return try await apiClient.voiceKeyerAudio(callsign: callsign, slotId: slotId)
    }

    func deleteVoiceKeyerAudio(slotId: String) async {
        guard let apiClient, let callsign = keyerCallsign else { return fail(TX5DRSessionError.operatorRequired) }
        await performOperation(success: "语音录音已删除") {
            self.voiceKeyerPanel = try await apiClient.deleteVoiceKeyerAudio(
                callsign: callsign,
                slotId: slotId
            )
        }
    }

    func playVoiceKeyerSlot(_ slot: VoiceKeyerSlot) {
        guard let callsign = keyerCallsign else { return fail(TX5DRSessionError.operatorRequired) }
        radio.playVoiceKeyer(
            callsign: callsign,
            slotId: slot.id,
            repeatPlayback: slot.repeatEnabled,
            operatorId: selectedOperatorId
        )
    }

    func updateCWKeyerConfig(backend: CWKeyerBackend? = nil, wpm: Int? = nil) async {
        guard let apiClient else { return fail(TX5DRSessionError.notConnected) }
        await performOperation(success: "CW 键控配置已更新") {
            self.cwKeyerConfig = try await apiClient.updateCWKeyerConfig(backend: backend, wpm: wpm)
        }
    }

    func updateCWMessageSlotCount(_ slotCount: Int) async {
        guard let apiClient, let callsign = keyerCallsign else { return fail(TX5DRSessionError.operatorRequired) }
        await performOperation(success: "CW 槽位数量已更新") {
            self.cwMessagePanel = try await apiClient.updateCWMessagePanel(
                callsign: callsign,
                slotCount: slotCount
            )
        }
    }

    func updateCWMessageSlot(_ slotId: String, update: CWMessageSlotUpdate) async {
        guard let apiClient, let callsign = keyerCallsign else { return fail(TX5DRSessionError.operatorRequired) }
        await performOperation {
            self.cwMessagePanel = try await apiClient.updateCWMessageSlot(
                callsign: callsign,
                slotId: slotId,
                update: update
            )
        }
    }

    func clearCWMessageSlot(_ slotId: String) async {
        guard let apiClient, let callsign = keyerCallsign else { return fail(TX5DRSessionError.operatorRequired) }
        await performOperation(success: "CW 报文槽已清空") {
            self.cwMessagePanel = try await apiClient.deleteCWMessageSlot(callsign: callsign, slotId: slotId)
        }
    }

    func swapCWMessageSlots(_ firstSlotId: String, _ secondSlotId: String) async {
        guard let apiClient, let callsign = keyerCallsign else { return fail(TX5DRSessionError.operatorRequired) }
        await performOperation {
            self.cwMessagePanel = try await apiClient.swapCWMessageSlots(
                callsign: callsign,
                firstSlotId: firstSlotId,
                secondSlotId: secondSlotId
            )
        }
    }

    func playCWMessageSlot(_ slot: CWMessageSlot) {
        guard let callsign = keyerCallsign, let selectedOperatorId else {
            return fail(TX5DRSessionError.operatorRequired)
        }
        radio.playCWMessage(
            callsign: callsign,
            slotId: slot.id,
            repeatPlayback: slot.repeatEnabled,
            operatorId: selectedOperatorId
        )
    }

    func loadCWDecoder() async {
        guard let apiClient else { return }
        do { cwDecoderBackends = try await apiClient.cwDecoderBackends() }
        catch { recordNonfatal("读取 CW 解码后端失败", error: error) }

        do {
            let response = try await apiClient.cwDecoderConfiguration()
            cwDecoderConfig = response.config
            radio.applyCWDecoderSnapshot(response.status)
        } catch {
            recordNonfatal("读取 CW 解码器配置失败", error: error)
        }
    }

    func updateCWDecoder(_ update: CWDecoderConfigUpdate) async {
        guard let apiClient else { return fail(TX5DRSessionError.notConnected) }
        await performOperation(success: "CW 解码器配置已更新") {
            let response = try await apiClient.updateCWDecoderConfiguration(update)
            self.cwDecoderConfig = response.config
            self.radio.applyCWDecoderSnapshot(response.status)
        }
    }

    func tuneCWDecoder(targetFreqHz: Int? = nil, filterWidthHz: Int? = nil) async {
        guard let apiClient else { return fail(TX5DRSessionError.notConnected) }
        await performOperation {
            let response = try await apiClient.tuneCWDecoder(
                targetFreqHz: targetFreqHz,
                filterWidthHz: filterWidthHz
            )
            self.cwDecoderConfig = response.config
            self.radio.applyCWDecoderSnapshot(response.status)
        }
    }

    func startCWDecoder() async {
        guard let apiClient else { return fail(TX5DRSessionError.notConnected) }
        await performOperation(success: "CW 解码器已启动") {
            let response = try await apiClient.startCWDecoder()
            self.cwDecoderConfig = response.config
            self.radio.applyCWDecoderSnapshot(response.status)
        }
    }

    func stopCWDecoder() async {
        guard let apiClient else { return fail(TX5DRSessionError.notConnected) }
        await performOperation(success: "CW 解码器已停止") {
            let response = try await apiClient.stopCWDecoder()
            self.cwDecoderConfig = response.config
            self.radio.applyCWDecoderSnapshot(response.status)
        }
    }

    func clearCWDecoderTranscript() async {
        guard let apiClient else { return fail(TX5DRSessionError.notConnected) }
        await performOperation(success: "CW 转写已清空") {
            let response = try await apiClient.clearCWDecoder()
            self.cwDecoderConfig = response.config
            self.radio.applyCWDecoderSnapshot(response.status)
            self.radio.clearCWDecoderTranscript()
        }
    }

    func loadPSKReporter() async {
        guard let apiClient else { return fail(TX5DRSessionError.notConnected) }
        do {
            pskReporterConfig = try await apiClient.pskReporterConfig()
            pskReporterStatus = try await apiClient.pskReporterStatus()
        } catch {
            fail(error)
        }
    }

    func refreshPSKReporterStatus(reportErrors: Bool = false) async {
        guard let apiClient else { return }
        do {
            pskReporterStatus = try await apiClient.pskReporterStatus()
        } catch {
            if reportErrors { fail(error) }
        }
    }

    func updatePSKReporter(_ update: PSKReporterConfigUpdate) async -> Bool {
        guard let apiClient else {
            fail(TX5DRSessionError.notConnected)
            return false
        }
        var updated = false
        await performOperation(success: "PSK Reporter 配置已保存") {
            pskReporterConfig = try await apiClient.updatePSKReporterConfig(update)
            pskReporterStatus = try await apiClient.pskReporterStatus()
            updated = true
        }
        return updated
    }

    func sendPendingPSKReporterSpots() async {
        guard let apiClient else { return fail(TX5DRSessionError.notConnected) }
        await performOperation(success: "PSK Reporter 上报已触发") {
            pskReporterStatus = try await apiClient.sendPendingPSKReporterSpots()
            pskReporterConfig = try await apiClient.pskReporterConfig()
        }
    }

    func resetPSKReporterStats() async {
        guard let apiClient else { return fail(TX5DRSessionError.notConnected) }
        await performOperation(success: "PSK Reporter 统计已重置") {
            try await apiClient.resetPSKReporterStats()
            pskReporterConfig = try await apiClient.pskReporterConfig()
            pskReporterStatus = try await apiClient.pskReporterStatus()
        }
    }

    func loadRigctldStatus(reportErrors: Bool = true) async {
        guard let apiClient else { return }
        do {
            rigctldStatus = try await apiClient.rigctldStatus()
        } catch {
            if reportErrors { fail(error) }
        }
    }

    func applyRigctldSnapshot(_ status: RigctldStatus) {
        rigctldStatus = status
    }

    func updateRigctld(_ config: RigctldBridgeConfig) async -> Bool {
        guard canManageRigctld else {
            fail(TX5DRSessionError.rigctldPermissionRequired)
            return false
        }
        guard let apiClient else {
            fail(TX5DRSessionError.notConnected)
            return false
        }
        var updated = false
        await performOperation(success: "Rigctld 桥配置已保存") {
            rigctldStatus = try await apiClient.updateRigctldConfig(config)
            updated = true
        }
        return updated
    }

    func loadQSOs(callsign: String? = nil) async {
        guard let apiClient, let selectedLogbookId else { return }
        do {
            qsos = try await apiClient.qsos(logbookId: selectedLogbookId, callsign: callsign).data
        } catch {
            recordNonfatal("读取 QSO 失败", error: error)
        }
    }

    func createQSO(_ request: CreateQSORequest) async {
        guard let apiClient, let selectedLogbookId else { return fail(TX5DRSessionError.notConnected) }
        await performOperation(success: "QSO 已写入日志本") {
            _ = try await apiClient.createQSO(logbookId: selectedLogbookId, request: request)
            await self.loadQSOs()
        }
    }

    func deleteQSO(_ qso: QSORecord) async {
        guard let apiClient, let selectedLogbookId else { return fail(TX5DRSessionError.notConnected) }
        await performOperation(success: "QSO 已删除") {
            try await apiClient.deleteQSO(logbookId: selectedLogbookId, qsoId: qso.id)
            self.qsos.removeAll { $0.id == qso.id }
        }
    }

    func loadLogbookDetail(id: String) async {
        guard let apiClient else { return }
        do { logbookDetails[id] = try await apiClient.logbookDetail(id: id) }
        catch { recordNonfatal("读取日志本详情失败", error: error) }
    }

    func createLogbook(name: String, description: String?) async -> Bool {
        guard isAdmin, let apiClient else {
            fail(TX5DRSessionError.adminRequired)
            return false
        }
        let slug = name
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let id = slug.isEmpty ? "logbook-\(Int(Date().timeIntervalSince1970))" : slug
        var created = false
        await performOperation(success: "日志本已创建") {
            let logbook = try await apiClient.createLogbook(id: id, name: name, description: description)
            self.logbooks = try await apiClient.logbooks()
            self.selectedLogbookId = logbook.id
            created = true
        }
        return created
    }

    func updateLogbook(_ logbook: LogbookInfo, name: String, description: String?, isActive: Bool) async -> Bool {
        guard let apiClient else {
            fail(TX5DRSessionError.notConnected)
            return false
        }
        var updated = false
        await performOperation(success: "日志本已更新") {
            _ = try await apiClient.updateLogbook(
                id: logbook.id,
                name: name,
                description: description,
                isActive: isActive
            )
            self.logbooks = try await apiClient.logbooks()
            self.logbookDetails[logbook.id] = try await apiClient.logbookDetail(id: logbook.id)
            updated = true
        }
        return updated
    }

    func deleteLogbook(_ logbook: LogbookInfo) async {
        guard isAdmin, let apiClient else { return fail(TX5DRSessionError.adminRequired) }
        await performOperation(success: "日志本已删除") {
            try await apiClient.deleteLogbook(id: logbook.id)
            self.logbooks = try await apiClient.logbooks()
            self.logbookDetails[logbook.id] = nil
            self.logbookBackups[logbook.id] = nil
            if self.selectedLogbookId == logbook.id {
                self.selectedLogbookId = self.logbooks.first(where: \.isActive)?.id ?? self.logbooks.first?.id
            }
        }
    }

    func connectOperator(_ operatorId: String, to logbookId: String) async {
        guard isAdmin, let apiClient else { return fail(TX5DRSessionError.adminRequired) }
        await performOperation(success: "操作员已连接到日志本") {
            try await apiClient.connectOperator(operatorId, toLogbook: logbookId)
            self.logbookDetails[logbookId] = try await apiClient.logbookDetail(id: logbookId)
            self.operators = try await apiClient.operators()
        }
    }

    func disconnectOperatorFromLogbook(_ operatorId: String) async {
        guard isAdmin, let apiClient else { return fail(TX5DRSessionError.adminRequired) }
        await performOperation(success: "操作员已与日志本断开") {
            try await apiClient.disconnectOperator(operatorId)
            self.operators = try await apiClient.operators()
        }
    }

    func exportLogbook(id: String, format: String) async throws -> Data {
        guard let apiClient else { throw TX5DRSessionError.notConnected }
        return try await apiClient.exportLogbook(id: id, format: format)
    }

    func importLogbook(id: String, fileName: String, data: Data) async -> Bool {
        guard let apiClient else {
            fail(TX5DRSessionError.notConnected)
            return false
        }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let result = try await apiClient.importLogbook(id: id, fileName: fileName, data: data)
            noticeMessage = "导入完成：新增 \(result.data.imported)，合并 \(result.data.merged)，跳过 \(result.data.skipped)"
            await loadQSOs()
            await loadLogbookDetail(id: id)
            return true
        } catch {
            fail(error)
            return false
        }
    }

    func loadLogbookBackup(id: String) async {
        guard let apiClient else { return }
        do { logbookBackups[id] = try await apiClient.logbookBackupStatus(id: id) }
        catch { recordNonfatal("读取备份状态失败", error: error) }
    }

    func createLogbookBackup(id: String) async {
        guard let apiClient else { return fail(TX5DRSessionError.notConnected) }
        await performOperation(success: "日志本备份已创建") {
            self.logbookBackups[id] = try await apiClient.createLogbookBackup(id: id)
        }
    }

    func downloadLogbookBackup(id: String) async throws -> Data {
        guard let apiClient else { throw TX5DRSessionError.notConnected }
        return try await apiClient.downloadLogbookBackup(id: id)
    }

    func refreshAccounts() async {
        guard isAdmin, let apiClient else { return fail(TX5DRSessionError.adminRequired) }
        do { accounts = try await apiClient.accounts() }
        catch { fail(error) }
    }

    func refreshOpenWebRXStations() async {
        guard isAdmin, let apiClient else { return fail(TX5DRSessionError.adminRequired) }
        do {
            openWebRXStations = try await apiClient.openWebRXStations()
        } catch {
            fail(error)
        }
    }

    func addOpenWebRXStation(name: String, url: String, description: String?) async -> Bool {
        guard isAdmin, let apiClient else {
            fail(TX5DRSessionError.adminRequired)
            return false
        }
        var created = false
        await performOperation(success: "OpenWebRX 站点已添加") {
            _ = try await apiClient.addOpenWebRXStation(name: name, url: url, description: description)
            openWebRXStations = try await apiClient.openWebRXStations()
            created = true
        }
        return created
    }

    func updateOpenWebRXStation(
        id: String,
        name: String,
        url: String,
        description: String?
    ) async -> Bool {
        guard isAdmin, let apiClient else {
            fail(TX5DRSessionError.adminRequired)
            return false
        }
        var updated = false
        await performOperation(success: "OpenWebRX 站点已更新") {
            try await apiClient.updateOpenWebRXStation(
                id: id,
                name: name,
                url: url,
                description: description
            )
            openWebRXStations = try await apiClient.openWebRXStations()
            updated = true
        }
        return updated
    }

    func deleteOpenWebRXStation(_ station: OpenWebRXStation) async {
        guard isAdmin, let apiClient else { return fail(TX5DRSessionError.adminRequired) }
        if openWebRXListenStatus?.stationId == station.id {
            await stopOpenWebRXListen()
        }
        await performOperation(success: "OpenWebRX 站点已删除") {
            try await apiClient.deleteOpenWebRXStation(id: station.id)
            openWebRXStations.removeAll { $0.id == station.id }
        }
    }

    func testOpenWebRX(url: String) async -> OpenWebRXTestResult? {
        guard isAdmin, let apiClient else {
            fail(TX5DRSessionError.adminRequired)
            return nil
        }
        do {
            return try await apiClient.testOpenWebRX(url: url)
        } catch {
            fail(error)
            return nil
        }
    }

    func startOpenWebRXListen(
        stationId: String,
        profileId: String,
        frequency: Double?,
        modulation: String
    ) async -> Bool {
        guard isAdmin, let apiClient else {
            fail(TX5DRSessionError.adminRequired)
            return false
        }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            openWebRXAudio.stopListening()
            let status = try await apiClient.startOpenWebRXListen(.init(
                stationId: stationId,
                profileId: profileId,
                frequency: frequency,
                modulation: modulation
            ))
            openWebRXListenStatus = status
            try await openWebRXAudio.startListening(
                scope: "openwebrx-preview",
                previewSessionId: status.previewSessionId
            )
            noticeMessage = "OpenWebRX 试听已启动"
            return true
        } catch {
            openWebRXAudio.stopListening()
            try? await apiClient.stopOpenWebRXListen()
            openWebRXListenStatus = nil
            fail(error)
            return false
        }
    }

    func tuneOpenWebRXListen(
        profileId: String?,
        frequency: Double?,
        modulation: String?,
        bandpassLow: Double? = nil,
        bandpassHigh: Double? = nil
    ) async -> Bool {
        guard isAdmin, let apiClient else {
            fail(TX5DRSessionError.adminRequired)
            return false
        }
        var tuned = false
        await performOperation(success: "OpenWebRX 调谐已应用") {
            try await apiClient.tuneOpenWebRXListen(.init(
                profileId: profileId,
                frequency: frequency,
                modulation: modulation,
                bandpassLow: bandpassLow,
                bandpassHigh: bandpassHigh
            ))
            openWebRXListenStatus = try await apiClient.openWebRXListenStatus()
            tuned = true
        }
        return tuned
    }

    func refreshOpenWebRXListenStatus() async {
        guard isAdmin, let apiClient else { return }
        do {
            openWebRXListenStatus = try await apiClient.openWebRXListenStatus()
            if openWebRXListenStatus?.isListening != true {
                openWebRXAudio.stopListening()
            }
        } catch {
            recordNonfatal("读取 OpenWebRX 试听状态失败", error: error)
        }
    }

    func connectOpenWebRXPreviewAudio() async -> Bool {
        guard let status = openWebRXListenStatus, status.isListening else {
            fail(TX5DRAPIError.invalidResponse)
            return false
        }
        do {
            try await openWebRXAudio.startListening(
                scope: "openwebrx-preview",
                previewSessionId: status.previewSessionId
            )
            return true
        } catch {
            fail(error)
            return false
        }
    }

    func stopOpenWebRXListen() async {
        guard isAdmin, let apiClient else { return fail(TX5DRSessionError.adminRequired) }
        openWebRXAudio.stopListening()
        do {
            try await apiClient.stopOpenWebRXListen()
            openWebRXListenStatus = nil
            noticeMessage = "OpenWebRX 试听已停止"
        } catch {
            fail(error)
        }
    }

    func createAccount(
        label: String,
        username: String,
        password: String,
        role: UserRole,
        operatorIds: [String],
        allowSelfService: Bool
    ) async -> CreateAccountResponse? {
        guard isAdmin, let apiClient else {
            fail(TX5DRSessionError.adminRequired)
            return nil
        }
        guard role != .viewer else {
            fail(TX5DRSessionError.viewerNotSupported)
            return nil
        }
        do {
            let request = CreateAccountRequest(
                label: label,
                role: role,
                operatorIds: operatorIds,
                expiresAt: nil,
                maxOperators: 0,
                allowSelfLoginCredential: allowSelfService,
                loginCredential: .init(username: username, password: password)
            )
            let created = try await apiClient.createAccount(request)
            accounts = try await apiClient.accounts()
            noticeMessage = "账户已创建"
            return created
        } catch {
            fail(error)
            return nil
        }
    }

    func deleteAccount(_ account: AuthTokenInfo) async {
        guard isAdmin, let apiClient else { return fail(TX5DRSessionError.adminRequired) }
        await performOperation(success: "账户已撤销") {
            try await apiClient.deleteAccount(id: account.id)
            self.accounts = try await apiClient.accounts()
        }
    }

    func updateOwnLogin(username: String, password: String?) async {
        guard let apiClient else { return fail(TX5DRSessionError.notConnected) }
        await performOperation(success: "登录账户已更新") {
            self.currentUser = try await apiClient.updateOwnLogin(username: username, password: password)
        }
    }

    func createPairingCode() async -> MobilePairingCodeResponse? {
        guard isAdmin, let apiClient else {
            fail(TX5DRSessionError.adminRequired)
            return nil
        }
        do {
            return try await apiClient.createMobilePairingCode()
        } catch {
            fail(error)
            return nil
        }
    }

    func readJSON(_ path: String) async throws -> JSONValue {
        guard let apiClient else { throw TX5DRSessionError.notConnected }
        return try await apiClient.json(.get, path)
    }

    func writeJSON(_ path: String, method: HTTPMethod = .put, value: JSONValue) async throws -> JSONValue {
        guard let apiClient else { throw TX5DRSessionError.notConnected }
        return try await apiClient.json(method, path, body: value)
    }

    func requestJSON(_ path: String, method: HTTPMethod, value: JSONValue? = nil) async throws -> JSONValue {
        guard let apiClient else { throw TX5DRSessionError.notConnected }
        return try await apiClient.json(method, path, body: value)
    }

    private func performAuthentication(_ operation: @escaping () async throws -> Void) async {
        phase = .authenticating
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await operation()
        } catch {
            phase = .signedOut
            fail(error)
        }
    }

    private func finishLogin(
        server: TX5DRServer,
        client: TX5DRAPIClient,
        jwt: String,
        user: AuthMeResponse
    ) async throws {
        try ensureSupportedRole(user.role)
        self.server = server
        apiClient = client
        self.jwt = jwt
        currentUser = user
        serverAddress = server.displayAddress
        UserDefaults.standard.set(server.displayAddress, forKey: Self.serverDefaultsKey)
        try tokenStore.save(jwt)

        audio.configure(server: server, apiClient: client)
        openWebRXAudio.configure(server: server, apiClient: client)
        await refreshPrimaryData()
        let enabledOperators: [String]? = user.role == .admin ? nil : user.operatorIds
        radio.configure(
            server: server,
            jwt: jwt,
            operatorIds: enabledOperators,
            selectedOperatorId: selectedOperatorId
        )
        radio.connect()
        phase = .ready
    }

    private func resolveSelectedOperator() {
        let saved = UserDefaults.standard.string(forKey: Self.operatorDefaultsKey)
        if let saved, operators.contains(where: { $0.id == saved }) {
            selectedOperatorId = saved
        } else if let permitted = currentUser?.operatorIds.first,
                  operators.contains(where: { $0.id == permitted }) {
            selectedOperatorId = permitted
        } else {
            selectedOperatorId = operators.first?.id
        }
    }

    private func ensureSupportedRole(_ role: UserRole) throws {
        if role == .viewer { throw TX5DRSessionError.viewerNotSupported }
    }

    private func performOperation(success: String? = nil, _ operation: () async throws -> Void) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await operation()
            if let success { noticeMessage = success }
        } catch {
            fail(error)
        }
    }

    private func recordNonfatal(_ prefix: String, error: Error) {
        noticeMessage = "\(prefix)：\(error.localizedDescription)"
    }

    private func fail(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    private static func bandName(for frequency: Double) -> String {
        switch frequency {
        case 1_800_000..<2_000_000: "160m"
        case 3_500_000..<4_000_000: "80m"
        case 5_000_000..<5_500_000: "60m"
        case 7_000_000..<7_300_000: "40m"
        case 10_100_000..<10_150_000: "30m"
        case 14_000_000..<14_350_000: "20m"
        case 18_068_000..<18_168_000: "17m"
        case 21_000_000..<21_450_000: "15m"
        case 24_890_000..<24_990_000: "12m"
        case 28_000_000..<29_700_000: "10m"
        case 50_000_000..<54_000_000: "6m"
        case 144_000_000..<148_000_000: "2m"
        case 420_000_000..<450_000_000: "70cm"
        default: "custom"
        }
    }
}
