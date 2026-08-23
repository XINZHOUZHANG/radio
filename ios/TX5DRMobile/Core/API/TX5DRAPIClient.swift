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

    func logbooks() async throws -> [LogbookInfo] {
        let response: LogbookListResponse = try await request(.get, "/logbooks")
        return response.data
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

    func realtimeSession(direction: String) async throws -> RealtimeTransportOffer {
        let body = RealtimeSessionRequest(
            scope: "radio",
            direction: direction,
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
        authenticated: Bool
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
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TX5DRAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let envelope = try? decoder.decode(TX5DRErrorEnvelope.self, from: data)
            throw TX5DRAPIError.http(status: http.statusCode, payload: envelope?.error)
        }
        return data
    }
}
