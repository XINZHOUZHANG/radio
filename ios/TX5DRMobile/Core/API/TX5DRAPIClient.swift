import Foundation

enum HTTPMethod: String, Sendable, Hashable, CaseIterable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
}

struct TX5DRErrorPayload: Codable, Sendable {
    let code: String?
    let message: String?
    let userMessage: String?
    let suggestions: [String]?
}

struct TX5DRErrorEnvelope: Codable, Sendable {
    let success: Bool?
    let error: TX5DRErrorPayload?
}

enum TX5DRAPIError: LocalizedError {
    case invalidResponse
    case http(status: Int, payload: TX5DRErrorPayload?)
    case emptyRealtimeOffer

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "服务器返回了无法识别的响应"
        case .emptyRealtimeOffer: "服务器没有提供可用的实时音频通道"
        case .http(let status, let payload):
            payload?.userMessage ?? payload?.message ?? "服务器请求失败（HTTP \(status)）"
        }
    }
}

actor TX5DRAPIClient {
    private var server: TX5DRServer
    private var jwt: String?
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(server: TX5DRServer, jwt: String? = nil, session: URLSession = .shared) {
        self.server = server
        self.jwt = jwt
        self.session = session
        encoder = JSONEncoder()
        decoder = JSONDecoder()
    }

    func configure(server: TX5DRServer, jwt: String?) {
        self.server = server
        self.jwt = jwt
    }

    func setJWT(_ jwt: String?) { self.jwt = jwt }

    func authStatus() async throws -> AuthStatus {
        try await request(.get, "/auth/status")
    }

    func login(username: String, password: String) async throws -> LoginResponse {
        struct Body: Encodable { let username: String; let password: String }
        let response: LoginResponse = try await request(.post, "/auth/login-password", body: Body(username: username, password: password), authenticated: false)
        jwt = response.jwt
        return response
    }

    func login(token: String) async throws -> LoginResponse {
        struct Body: Encodable { let token: String }
        let response: LoginResponse = try await request(.post, "/auth/login", body: Body(token: token), authenticated: false)
        jwt = response.jwt
        return response
    }

    func me() async throws -> AuthMeResponse { try await request(.get, "/auth/me") }

    func accounts() async throws -> [AuthTokenInfo] {
        try await request(.get, "/auth/tokens")
    }

    func createAccount(_ account: CreateAccountRequest) async throws -> CreateAccountResponse {
        try await request(.post, "/auth/tokens", body: account)
    }

    func deleteAccount(id: String) async throws {
        let _: GenericSuccessResponse = try await request(.delete, "/auth/tokens/\(id)")
    }

    func updateOwnLogin(username: String, password: String?) async throws -> AuthMeResponse {
        struct Body: Encodable {
            let username: String
            let password: String?
        }
        return try await request(.put, "/auth/me/login-credential", body: Body(username: username, password: password))
    }

    func createBrowserLoginCode() async throws -> BrowserLoginCodeResponse {
        try await request(.post, "/auth/browser-login-codes")
    }

    func exchangeBrowserLoginCode(_ code: String) async throws -> LoginResponse {
        struct Body: Encodable { let code: String }
        let response: LoginResponse = try await request(
            .post,
            "/auth/browser-login-codes/exchange",
            body: Body(code: code),
            authenticated: false
        )
        jwt = response.jwt
        return response
    }

    func createMobilePairingCode() async throws -> MobilePairingCodeResponse {
        try await request(.post, "/auth/mobile-pairing-codes")
    }

    func exchangeMobilePairingCode(_ code: String) async throws -> LoginResponse {
        struct Body: Encodable { let code: String }
        let response: LoginResponse = try await request(
            .post,
            "/auth/mobile-pairing-codes/exchange",
            body: Body(code: code),
            authenticated: false
        )
        jwt = response.jwt
        return response
    }

    /// The upstream server does not advertise optional native-app pairing. A
    /// malformed (non-rate-limited) probe distinguishes the extension's 400
    /// response from an upstream 404 without consuming a six-digit attempt.
    func supportsMobilePairing() async -> Bool {
        struct Body: Encodable { let code: String }
        do {
            let _: LoginResponse = try await request(
                .post,
                "/auth/mobile-pairing-codes/exchange",
                body: Body(code: ""),
                authenticated: false
            )
            return true
        } catch TX5DRAPIError.http(let status, let payload) {
            return status == 400 && payload?.code == "INVALID_PAIRING_CODE_FORMAT"
        } catch {
            return false
        }
    }

    func profiles() async throws -> ProfileListResponse {
        try await request(.get, "/profiles")
    }

    func supportedRigs() async throws -> [SupportedRig] {
        let response: SupportedRigsResponse = try await request(.get, "/radio/rigs")
        return response.rigs
    }

    func serialPorts() async throws -> [SerialPortInfo] {
        let response: SerialPortsResponse = try await request(.get, "/radio/serial-ports")
        return response.ports
    }

    func audioDevices() async throws -> AudioDevicesResponse {
        try await request(.get, "/audio/devices")
    }

    func createProfile(name: String, description: String?, radio: JSONValue, audio: JSONValue) async throws -> RadioProfile {
        struct Body: Encodable {
            let name: String
            let radio: JSONValue
            let audio: JSONValue
            let description: String?
        }
        let response: ProfileActionResponse = try await request(
            .post,
            "/profiles",
            body: Body(name: name, radio: radio, audio: audio, description: description)
        )
        guard response.success, let profile = response.profile else { throw TX5DRAPIError.invalidResponse }
        return profile
    }

    func updateProfile(id: String, name: String, description: String?, radio: JSONValue, audio: JSONValue) async throws -> RadioProfile {
        struct Body: Encodable {
            let name: String
            let radio: JSONValue
            let audio: JSONValue
            let description: String?
        }
        let response: ProfileActionResponse = try await request(
            .put,
            "/profiles/\(id)",
            body: Body(name: name, radio: radio, audio: audio, description: description)
        )
        guard response.success, let profile = response.profile else { throw TX5DRAPIError.invalidResponse }
        return profile
    }

    func deleteProfile(id: String) async throws {
        let response: GenericSuccessResponse = try await request(.delete, "/profiles/\(id)")
        if !response.success { throw TX5DRAPIError.invalidResponse }
    }

    func activateProfile(id: String) async throws -> ActivateProfileResponse {
        try await request(.post, "/profiles/\(id)/activate")
    }

    func reorderProfiles(ids: [String]) async throws {
        struct Body: Encodable { let profileIds: [String] }
        let response: GenericSuccessResponse = try await request(.put, "/profiles/reorder", body: Body(profileIds: ids))
        if !response.success { throw TX5DRAPIError.invalidResponse }
    }

    func radioPowerSupport(profileId: String) async throws -> RadioPowerSupportInfo {
        try await request(.get, "/radio/power/support", queryItems: [URLQueryItem(name: "profileId", value: profileId)])
    }

    func setRadioPower(profileId: String, target: RadioPowerTarget, autoEngine: Bool = true) async throws -> RadioPowerResponse {
        struct Body: Encodable {
            let profileId: String
            let state: RadioPowerTarget
            let autoEngine: Bool
        }
        return try await request(
            .post,
            "/radio/power",
            body: Body(profileId: profileId, state: target, autoEngine: autoEngine)
        )
    }

    func modes() async throws -> [ModeDescriptor] {
        let response: DataResponse<[ModeDescriptor]> = try await request(.get, "/mode")
        return response.data
    }

    func switchMode(_ mode: ModeDescriptor) async throws -> ModeDescriptor {
        let response: DataResponse<ModeDescriptor> = try await request(.post, "/mode/switch", body: mode)
        return response.data
    }

    func operators() async throws -> [RadioOperatorConfig] {
        let response: OperatorListResponse = try await request(.get, "/operators")
        return response.data
    }

    func createOperator(_ operatorRequest: SaveRadioOperatorRequest) async throws -> RadioOperatorConfig {
        let response: RadioOperatorActionResponse = try await request(.post, "/operators", body: operatorRequest)
        guard response.success, let created = response.data else { throw TX5DRAPIError.invalidResponse }
        return created
    }

    func updateOperator(id: String, request operatorRequest: SaveRadioOperatorRequest) async throws -> RadioOperatorConfig {
        let response: RadioOperatorActionResponse = try await request(.put, "/operators/\(id)", body: operatorRequest)
        guard response.success, let updated = response.data else { throw TX5DRAPIError.invalidResponse }
        return updated
    }

    func deleteOperator(id: String) async throws {
        let response: GenericSuccessResponse = try await request(.delete, "/operators/\(id)")
        if !response.success { throw TX5DRAPIError.invalidResponse }
    }

    func setFrequency(_ frequency: Double, mode: String, band: String, radioMode: String? = nil) async throws {
        var body: [String: JSONValue] = [
            "frequency": .number(frequency),
            "mode": .string(mode),
            "band": .string(band),
        ]
        if let radioMode { body["radioMode"] = .string(radioMode) }
        _ = try await json(.post, "/radio/frequency", body: .object(body))
    }

    func setTuner(enabled: Bool) async throws {
        _ = try await json(.post, "/radio/tuner", body: .object(["enabled": .bool(enabled)]))
    }

    func startTuning() async throws {
        let response: GenericSuccessResponse = try await request(.post, "/radio/tuner/tune")
        if !response.success { throw TX5DRAPIError.invalidResponse }
    }

    func capabilities() async throws -> CapabilityList {
        struct Response: Codable, Sendable {
            let success: Bool
            let descriptors: [CapabilityDescriptor]
            let capabilities: [CapabilityState]
        }
        let response: Response = try await request(.get, "/radio/capabilities")
        return CapabilityList(descriptors: response.descriptors, capabilities: response.capabilities)
    }

    func writeCapability(id: String, value: JSONValue? = nil, action: Bool? = nil) async throws {
        var body: [String: JSONValue] = [:]
        if let value { body["value"] = value }
        if let action { body["action"] = .bool(action) }
        _ = try await json(.post, "/radio/capabilities/\(id)", body: .object(body))
    }

    func startOperator(id: String) async throws {
        let _: GenericSuccessResponse = try await request(.post, "/operators/\(id)/start")
    }

    func stopOperator(id: String) async throws {
        let _: GenericSuccessResponse = try await request(.post, "/operators/\(id)/stop")
    }

    func voiceKeyerPanel(callsign: String) async throws -> VoiceKeyerPanel {
        let response: VoiceKeyerPanelResponse = try await request(
            .get,
            "/voice/keyer/\(pathSegment(callsign))"
        )
        return response.panel
    }

    func updateVoiceKeyerPanel(callsign: String, slotCount: Int) async throws -> VoiceKeyerPanel {
        struct Body: Encodable { let slotCount: Int }
        let response: VoiceKeyerPanelResponse = try await request(
            .patch,
            "/voice/keyer/\(pathSegment(callsign))",
            body: Body(slotCount: slotCount)
        )
        return response.panel
    }

    func updateVoiceKeyerSlot(
        callsign: String,
        slotId: String,
        update: VoiceKeyerSlotUpdate
    ) async throws -> VoiceKeyerPanel {
        let response: VoiceKeyerPanelResponse = try await request(
            .patch,
            "/voice/keyer/\(pathSegment(callsign))/slots/\(pathSegment(slotId))",
            body: update
        )
        return response.panel
    }

    func uploadVoiceKeyerAudio(callsign: String, slotId: String, wavData: Data) async throws -> VoiceKeyerPanel {
        let boundary = "tx5dr-ios-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"voice-keyer.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        let responseData = try await data(
            .post,
            "/voice/keyer/\(pathSegment(callsign))/slots/\(pathSegment(slotId))/audio",
            body: body,
            authenticated: true,
            headers: ["Content-Type": "multipart/form-data; boundary=\(boundary)"]
        )
        return try decoder.decode(VoiceKeyerPanelResponse.self, from: responseData).panel
    }

    func voiceKeyerAudio(callsign: String, slotId: String) async throws -> Data {
        try await download(
            "/voice/keyer/\(pathSegment(callsign))/slots/\(pathSegment(slotId))/audio"
        )
    }

    func deleteVoiceKeyerAudio(callsign: String, slotId: String) async throws -> VoiceKeyerPanel {
        let response: VoiceKeyerPanelResponse = try await request(
            .delete,
            "/voice/keyer/\(pathSegment(callsign))/slots/\(pathSegment(slotId))/audio"
        )
        return response.panel
    }

    func cwKeyerConfig() async throws -> CWKeyerConfig {
        let response: CWKeyerConfigResponse = try await request(.get, "/cw/config")
        return response.config
    }

    func updateCWKeyerConfig(backend: CWKeyerBackend? = nil, wpm: Int? = nil) async throws -> CWKeyerConfig {
        struct Body: Encodable { let backend: CWKeyerBackend?; let wpm: Int? }
        let response: CWKeyerConfigResponse = try await request(
            .put,
            "/cw/config",
            body: Body(backend: backend, wpm: wpm)
        )
        return response.config
    }

    func cwMessagePanel(callsign: String) async throws -> CWMessagePanel {
        let response: CWMessagePanelResponse = try await request(
            .get,
            "/cw/panel/\(pathSegment(callsign))"
        )
        return response.panel
    }

    func updateCWMessagePanel(callsign: String, slotCount: Int) async throws -> CWMessagePanel {
        struct Body: Encodable { let slotCount: Int }
        let response: CWMessagePanelResponse = try await request(
            .patch,
            "/cw/panel/\(pathSegment(callsign))",
            body: Body(slotCount: slotCount)
        )
        return response.panel
    }

    func updateCWMessageSlot(
        callsign: String,
        slotId: String,
        update: CWMessageSlotUpdate
    ) async throws -> CWMessagePanel {
        let response: CWMessagePanelResponse = try await request(
            .patch,
            "/cw/panel/\(pathSegment(callsign))/slots/\(pathSegment(slotId))",
            body: update
        )
        return response.panel
    }

    func deleteCWMessageSlot(callsign: String, slotId: String) async throws -> CWMessagePanel {
        let response: CWMessagePanelResponse = try await request(
            .delete,
            "/cw/panel/\(pathSegment(callsign))/slots/\(pathSegment(slotId))"
        )
        return response.panel
    }

    func swapCWMessageSlots(callsign: String, firstSlotId: String, secondSlotId: String) async throws -> CWMessagePanel {
        struct Body: Encodable { let slotIdA: String; let slotIdB: String }
        let response: CWMessagePanelResponse = try await request(
            .post,
            "/cw/panel/\(pathSegment(callsign))/slots/swap",
            body: Body(slotIdA: firstSlotId, slotIdB: secondSlotId)
        )
        return response.panel
    }

    func cwDecoderBackends() async throws -> [CWDecoderBackendDescriptor] {
        let response: CWDecoderBackendsResponse = try await request(.get, "/cw/decoder/backends")
        return response.backends
    }

    func cwDecoderConfiguration() async throws -> CWDecoderConfigResponse {
        try await request(.get, "/cw/decoder/config")
    }

    func updateCWDecoderConfiguration(_ update: CWDecoderConfigUpdate) async throws -> CWDecoderConfigResponse {
        try await request(.put, "/cw/decoder/config", body: update)
    }

    func tuneCWDecoder(targetFreqHz: Int? = nil, filterWidthHz: Int? = nil) async throws -> CWDecoderConfigResponse {
        struct Body: Encodable { let targetFreqHz: Int?; let filterWidthHz: Int? }
        return try await request(
            .patch,
            "/cw/decoder/tuning",
            body: Body(targetFreqHz: targetFreqHz, filterWidthHz: filterWidthHz)
        )
    }

    func startCWDecoder(_ update: CWDecoderConfigUpdate = .init()) async throws -> CWDecoderConfigResponse {
        try await request(.post, "/cw/decoder/start", body: update)
    }

    func stopCWDecoder() async throws -> CWDecoderConfigResponse {
        try await request(.post, "/cw/decoder/stop")
    }

    func clearCWDecoder() async throws -> CWDecoderConfigResponse {
        try await request(.post, "/cw/decoder/clear")
    }

    func pskReporterConfig() async throws -> PSKReporterConfig {
        let response: DataResponse<PSKReporterConfig> = try await request(.get, "/pskreporter/config")
        guard response.success else { throw TX5DRAPIError.invalidResponse }
        return response.data
    }

    func updatePSKReporterConfig(_ update: PSKReporterConfigUpdate) async throws -> PSKReporterConfig {
        let response: DataResponse<PSKReporterConfig> = try await request(
            .put,
            "/pskreporter/config",
            body: update
        )
        guard response.success else { throw TX5DRAPIError.invalidResponse }
        return response.data
    }

    func pskReporterStatus() async throws -> PSKReporterStatus {
        let response: DataResponse<PSKReporterStatus> = try await request(.get, "/pskreporter/status")
        guard response.success else { throw TX5DRAPIError.invalidResponse }
        return response.data
    }

    func sendPendingPSKReporterSpots() async throws -> PSKReporterStatus {
        let response: DataResponse<PSKReporterStatus> = try await request(.post, "/pskreporter/report")
        guard response.success else { throw TX5DRAPIError.invalidResponse }
        return response.data
    }

    func resetPSKReporterStats() async throws {
        let response: GenericSuccessResponse = try await request(.post, "/pskreporter/reset-stats")
        guard response.success else { throw TX5DRAPIError.invalidResponse }
    }

    func pluginSnapshot() async throws -> TX5DRPluginSystemSnapshot {
        try await request(.get, "/plugins")
    }

    func pluginRuntimeInfo() async throws -> TX5DRPluginRuntimeInfo {
        try await request(.get, "/plugins/runtime-info")
    }

    func setPluginEnabled(name: String, enabled: Bool) async throws {
        if enabled {
            let response: GenericSuccessResponse = try await request(
                .post,
                "/plugins/\(pathSegment(name))/enable"
            )
            guard response.success else { throw TX5DRAPIError.invalidResponse }
        } else {
            let response: GenericSuccessResponse = try await request(
                .post,
                "/plugins/\(pathSegment(name))/disable"
            )
            guard response.success else { throw TX5DRAPIError.invalidResponse }
        }
    }

    func reloadPlugins() async throws {
        let response: GenericSuccessResponse = try await request(.post, "/plugins/reload")
        guard response.success else { throw TX5DRAPIError.invalidResponse }
    }

    func rescanPlugins() async throws {
        let response: GenericSuccessResponse = try await request(.post, "/plugins/rescan")
        guard response.success else { throw TX5DRAPIError.invalidResponse }
    }

    func reloadPlugin(name: String) async throws {
        let response: GenericSuccessResponse = try await request(
            .post,
            "/plugins/\(pathSegment(name))/reload"
        )
        guard response.success else { throw TX5DRAPIError.invalidResponse }
    }

    func pluginSettings(name: String) async throws -> [String: JSONValue] {
        let response: TX5DRPluginSettingsResponse = try await request(
            .get,
            "/plugins/\(pathSegment(name))/settings"
        )
        return response.settings
    }

    func updatePluginSettings(name: String, settings: [String: JSONValue]) async throws {
        struct Body: Encodable { let settings: [String: JSONValue] }
        let response: GenericSuccessResponse = try await request(
            .put,
            "/plugins/\(pathSegment(name))/settings",
            body: Body(settings: settings)
        )
        guard response.success else { throw TX5DRAPIError.invalidResponse }
    }

    func pluginOperatorState(operatorId: String) async throws -> TX5DRPluginOperatorState {
        try await request(.get, "/plugins/operators/\(pathSegment(operatorId))")
    }

    func pluginOperatorSettings(name: String, operatorId: String) async throws -> [String: JSONValue] {
        let response: TX5DRPluginSettingsResponse = try await request(
            .get,
            "/plugins/\(pathSegment(name))/operator/\(pathSegment(operatorId))/settings"
        )
        return response.settings
    }

    func updatePluginOperatorSettings(
        name: String,
        operatorId: String,
        settings: [String: JSONValue]
    ) async throws {
        struct Body: Encodable { let settings: [String: JSONValue] }
        let response: GenericSuccessResponse = try await request(
            .put,
            "/plugins/\(pathSegment(name))/operator/\(pathSegment(operatorId))/settings",
            body: Body(settings: settings)
        )
        guard response.success else { throw TX5DRAPIError.invalidResponse }
    }

    func setPluginPaused(name: String, operatorId: String, paused: Bool) async throws -> TX5DRPluginPauseResponse {
        struct Body: Encodable { let paused: Bool }
        return try await request(
            .put,
            "/plugins/\(pathSegment(name))/operator/\(pathSegment(operatorId))/pause",
            body: Body(paused: paused)
        )
    }

    func setAllTransmitControlPluginsPaused(
        operatorId: String,
        paused: Bool
    ) async throws -> TX5DRPluginPauseResponse {
        if paused {
            return try await request(
                .post,
                "/plugins/operators/\(pathSegment(operatorId))/transmit-control/pause-all"
            )
        }
        return try await request(
            .post,
            "/plugins/operators/\(pathSegment(operatorId))/transmit-control/resume-all"
        )
    }

    func setPluginStrategy(operatorId: String, pluginName: String) async throws {
        struct Body: Encodable { let pluginName: String }
        let response: GenericSuccessResponse = try await request(
            .put,
            "/plugins/operators/\(pathSegment(operatorId))/strategy",
            body: Body(pluginName: pluginName)
        )
        guard response.success else { throw TX5DRAPIError.invalidResponse }
    }

    func pluginMarketCatalog(channel: String) async throws -> TX5DRPluginMarketCatalogResponse {
        try await request(
            .get,
            "/plugins/market/catalog",
            queryItems: [URLQueryItem(name: "channel", value: channel)]
        )
    }

    func installPlugin(name: String, channel: String) async throws -> TX5DRPluginMarketInstallResult {
        struct Body: Encodable { let channel: String }
        return try await request(
            .post,
            "/plugins/market/\(pathSegment(name))/install",
            body: Body(channel: channel)
        )
    }

    func updatePlugin(name: String, channel: String) async throws -> TX5DRPluginMarketInstallResult {
        struct Body: Encodable { let channel: String }
        return try await request(
            .post,
            "/plugins/market/\(pathSegment(name))/update",
            body: Body(channel: channel)
        )
    }

    func uninstallPlugin(name: String) async throws -> TX5DRPluginMarketInstallResult {
        try await request(.delete, "/plugins/market/\(pathSegment(name))")
    }

    func pluginPageRequest(
        name: String,
        endpoint: TX5DRPluginPageEndpoint,
        body: JSONValue
    ) async throws -> JSONValue? {
        let envelope: JSONValue
        switch endpoint {
        case .invoke:
            envelope = try await json(.post, "/plugins/\(pathSegment(name))/ui-invoke", body: body)
        case .store:
            envelope = try await json(.post, "/plugins/\(pathSegment(name))/ui-store", body: body)
        case .files:
            envelope = try await json(.post, "/plugins/\(pathSegment(name))/ui-files", body: body)
        case .heartbeat:
            envelope = try await json(.post, "/plugins/\(pathSegment(name))/ui-session/heartbeat", body: body)
        case .pushes:
            envelope = try await json(.post, "/plugins/\(pathSegment(name))/ui-session/pushes", body: body)
        }
        if let error = envelope["error"]?.stringValue, !error.isEmpty {
            throw TX5DRPluginPageBridgeError.server(error)
        }
        return envelope["result"]
    }

    func rigctldStatus() async throws -> RigctldStatus {
        try await request(.get, "/rigctld/status")
    }

    func updateRigctldConfig(_ config: RigctldBridgeConfig) async throws -> RigctldStatus {
        try await request(.put, "/rigctld/config", body: config)
    }

    func logbooks() async throws -> [LogbookInfo] {
        let response: LogbookListResponse = try await request(.get, "/logbooks")
        return response.data
    }

    func logbookDetail(id: String) async throws -> LogbookDetail {
        let response: LogbookDetailResponse = try await request(.get, "/logbooks/\(id)")
        return response.data
    }

    func createLogbook(id: String, name: String, description: String?) async throws -> LogbookInfo {
        struct Body: Encodable {
            let id: String
            let name: String
            let description: String?
            let autoCreateFile = true
        }
        let response: LogbookActionResponse = try await request(
            .post,
            "/logbooks",
            body: Body(id: id, name: name, description: description)
        )
        guard response.success, let logbook = response.data else { throw TX5DRAPIError.invalidResponse }
        return logbook
    }

    func updateLogbook(id: String, name: String, description: String?, isActive: Bool) async throws -> LogbookInfo {
        struct Body: Encodable {
            let name: String
            let description: String?
            let isActive: Bool
        }
        let response: LogbookActionResponse = try await request(
            .put,
            "/logbooks/\(id)",
            body: Body(name: name, description: description, isActive: isActive)
        )
        guard response.success, let logbook = response.data else { throw TX5DRAPIError.invalidResponse }
        return logbook
    }

    func deleteLogbook(id: String) async throws {
        let response: GenericSuccessResponse = try await request(.delete, "/logbooks/\(id)")
        if !response.success { throw TX5DRAPIError.invalidResponse }
    }

    func connectOperator(_ operatorId: String, toLogbook id: String) async throws {
        struct Body: Encodable { let operatorId: String; let logBookId: String }
        let response: GenericSuccessResponse = try await request(
            .post,
            "/logbooks/\(id)/connect",
            body: Body(operatorId: operatorId, logBookId: id)
        )
        if !response.success { throw TX5DRAPIError.invalidResponse }
    }

    func disconnectOperator(_ operatorId: String) async throws {
        let response: GenericSuccessResponse = try await request(.post, "/logbooks/disconnect/\(operatorId)")
        if !response.success { throw TX5DRAPIError.invalidResponse }
    }

    func exportLogbook(id: String, format: String) async throws -> Data {
        try await download(
            "/logbooks/\(id)/export",
            queryItems: [URLQueryItem(name: "format", value: format)]
        )
    }

    func importLogbook(id: String, fileName: String, data fileData: Data) async throws -> LogbookImportResponse {
        let boundary = "tx5dr-ios-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        let responseData = try await data(
            .post,
            "/logbooks/\(id)/import",
            body: body,
            authenticated: true,
            headers: ["Content-Type": "multipart/form-data; boundary=\(boundary)"]
        )
        return try decoder.decode(LogbookImportResponse.self, from: responseData)
    }

    func logbookBackupStatus(id: String) async throws -> LogbookBackupStatus {
        let response: LogbookBackupStatusResponse = try await request(.get, "/logbooks/\(id)/backup")
        return response.data
    }

    func createLogbookBackup(id: String) async throws -> LogbookBackupStatus {
        let encoded = try encoder.encode(JSONValue.object([:]))
        let responseData = try await data(
            .post,
            "/logbooks/\(id)/backup",
            body: encoded,
            authenticated: true,
            headers: ["Idempotency-Key": UUID().uuidString]
        )
        return try decoder.decode(LogbookBackupStatusResponse.self, from: responseData).data
    }

    func downloadLogbookBackup(id: String) async throws -> Data {
        try await download("/logbooks/\(id)/backup/download")
    }

    func qsos(logbookId: String, limit: Int = 100, offset: Int = 0, callsign: String? = nil) async throws -> QSOListResponse {
        var query = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
        ]
        if let callsign, !callsign.isEmpty {
            query.append(URLQueryItem(name: "callsign", value: callsign))
        }
        return try await request(.get, "/logbooks/\(logbookId)/qsos", queryItems: query)
    }

    func createQSO(logbookId: String, request body: CreateQSORequest) async throws -> QSOActionResponse {
        try await request(.post, "/logbooks/\(logbookId)/qsos", body: body)
    }

    func deleteQSO(logbookId: String, qsoId: String) async throws {
        let _: GenericSuccessResponse = try await request(.delete, "/logbooks/\(logbookId)/qsos/\(qsoId)")
    }

    func openWebRXStations() async throws -> [OpenWebRXStation] {
        let response: OpenWebRXStationListResponse = try await request(.get, "/openwebrx/stations")
        return response.stations
    }

    func addOpenWebRXStation(name: String, url: String, description: String?) async throws -> OpenWebRXStation {
        struct Body: Encodable {
            let name: String
            let url: String
            let description: String?
        }
        let response: OpenWebRXStationActionResponse = try await request(
            .post,
            "/openwebrx/stations",
            body: Body(name: name, url: url, description: description)
        )
        guard response.success else { throw TX5DRAPIError.invalidResponse }
        return response.station
    }

    func updateOpenWebRXStation(id: String, name: String, url: String, description: String?) async throws {
        struct Body: Encodable {
            let name: String
            let url: String
            let description: String?
        }
        let response: GenericSuccessResponse = try await request(
            .put,
            "/openwebrx/stations/\(pathSegment(id))",
            body: Body(name: name, url: url, description: description)
        )
        if !response.success { throw TX5DRAPIError.invalidResponse }
    }

    func deleteOpenWebRXStation(id: String) async throws {
        let response: GenericSuccessResponse = try await request(
            .delete,
            "/openwebrx/stations/\(pathSegment(id))"
        )
        if !response.success { throw TX5DRAPIError.invalidResponse }
    }

    func testOpenWebRX(url: String) async throws -> OpenWebRXTestResult {
        struct Body: Encodable { let url: String }
        return try await request(.post, "/openwebrx/test-url", body: Body(url: url))
    }

    func startOpenWebRXListen(_ options: OpenWebRXListenStart) async throws -> OpenWebRXListenStatus {
        let response: OpenWebRXListenStartResponse = try await request(
            .post,
            "/openwebrx/listen/start",
            body: options
        )
        guard response.success else { throw TX5DRAPIError.invalidResponse }
        return response.status
    }

    func stopOpenWebRXListen() async throws {
        let response: GenericSuccessResponse = try await request(.post, "/openwebrx/listen/stop")
        if !response.success { throw TX5DRAPIError.invalidResponse }
    }

    func tuneOpenWebRXListen(_ options: OpenWebRXListenTune) async throws {
        let response: GenericSuccessResponse = try await request(
            .post,
            "/openwebrx/listen/tune",
            body: options
        )
        if !response.success { throw TX5DRAPIError.invalidResponse }
    }

    func openWebRXListenStatus() async throws -> OpenWebRXListenStatus? {
        let response: OpenWebRXListenStatusResponse = try await request(.get, "/openwebrx/listen/status")
        return response.status
    }

    func realtimeSession(
        scope: String = "radio",
        direction: String,
        previewSessionId: String? = nil
    ) async throws -> RealtimeTransportOffer {
        let body = RealtimeSessionRequest(
            scope: scope,
            direction: direction,
            previewSessionId: previewSessionId,
            transportOverride: "ws-compat",
            audioCodecPreference: "pcm",
            audioCodecCapabilities: .init(pcmS16le: true)
        )
        let response: RealtimeSessionResponse = try await request(.post, "/realtime/session", body: body)
        guard let offer = response.offers.first(where: { $0.transport == "ws-compat" }) else {
            throw TX5DRAPIError.emptyRealtimeOffer
        }
        return offer
    }

    func json(_ method: HTTPMethod, _ path: String, body: JSONValue? = nil) async throws -> JSONValue {
        let bodyData = try body.map(encoder.encode)
        let data = try await data(method, path, body: bodyData, authenticated: true)
        return try decoder.decode(JSONValue.self, from: data)
    }

    func download(_ path: String, queryItems: [URLQueryItem] = []) async throws -> Data {
        try await data(.get, path, queryItems: queryItems, body: nil, authenticated: true)
    }

    private func pathSegment(_ value: String) -> String {
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    private func request<Response: Decodable>(
        _ method: HTTPMethod,
        _ path: String,
        queryItems: [URLQueryItem] = [],
        authenticated: Bool = true
    ) async throws -> Response {
        let data = try await data(method, path, queryItems: queryItems, body: nil, authenticated: authenticated)
        return try decoder.decode(Response.self, from: data)
    }

    private func request<Body: Encodable, Response: Decodable>(
        _ method: HTTPMethod,
        _ path: String,
        body: Body,
        authenticated: Bool = true
    ) async throws -> Response {
        let bodyData = try encoder.encode(body)
        let data = try await data(method, path, body: bodyData, authenticated: authenticated)
        return try decoder.decode(Response.self, from: data)
    }

    private func data(
        _ method: HTTPMethod,
        _ path: String,
        queryItems: [URLQueryItem] = [],
        body: Data?,
        authenticated: Bool,
        headers: [String: String] = [:]
    ) async throws -> Data {
        var request = URLRequest(url: try server.apiURL(path, queryItems: queryItems))
        request.httpMethod = method.rawValue
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if authenticated, let jwt {
            request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        }
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TX5DRAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let envelope = try? decoder.decode(TX5DRErrorEnvelope.self, from: data)
            throw TX5DRAPIError.http(status: http.statusCode, payload: envelope?.error)
        }
        return data
    }
}
