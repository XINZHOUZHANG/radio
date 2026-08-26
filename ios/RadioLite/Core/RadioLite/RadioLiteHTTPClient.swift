import Foundation

enum RadioLiteHTTPError: LocalizedError, Equatable {
    case invalidResponse
    case missingSessionCookie
    case http(status: Int, code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "服务器返回了无法识别的数据"
        case .missingSessionCookie:
            "登录成功，但服务器没有返回会话 Cookie"
        case .http(_, let code, let message):
            Self.localizedHTTPMessage(code: code, message: message)
        }
    }

    private static func localizedHTTPMessage(code: String, message: String) -> String {
        if code == "invalid_request",
           message.localizedCaseInsensitiveContains("password") {
            return "密码被服务器拒绝。新版 Radio Lite 仅要求密码非空，不限制位数或复杂度；请升级服务端后重试。服务器信息：\(message)"
        }
        switch code {
        case "invalid_or_expired_code":
            return "6 位验证码无效或已过期，请在服务器终端重新生成后再试"
        case "code_rate_limited":
            return "验证码尝试次数过多，请稍后再试或在服务器终端重新生成"
        case "invalid_login":
            return "用户名或密码不正确"
        case "already_initialized":
            return "服务器已经完成初始化，请返回账户登录"
        case "admin_required":
            return "此操作需要管理员权限"
        case "authentication_required":
            return "登录已失效，请重新登录"
        default:
            return message
        }
    }

    var isUnauthorized: Bool {
        if case .http(let status, _, _) = self { return status == 401 }
        return false
    }
}

struct RadioLiteAccountLogin: Sendable {
    let user: RadioLiteUser
    let credential: RadioLiteCredential
}

final class RadioLiteHTTPClient: @unchecked Sendable {
    let server: RadioLiteServer
    let credential: RadioLiteCredential?
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        server: RadioLiteServer,
        credential: RadioLiteCredential? = nil,
        session: URLSession? = nil
    ) {
        self.server = server
        self.credential = credential
        self.session = session ?? URLSession(configuration: RadioLiteNetworkPolicy.configuration())
    }

    func health() async throws -> RadioLiteHealth {
        try await send(method: "GET", path: "/healthz", authenticated: false)
    }

    func setupStatus() async throws -> RadioLiteSetupStatus {
        try await send(method: "GET", path: "/api/v1/setup/status", authenticated: false)
    }

    func initialize(setupCode: String, username: String, password: String) async throws -> RadioLiteUser {
        struct Body: Encodable { let setupCode: String; let username: String; let password: String }
        let response: RadioLiteCreatedUserResponse = try await send(
            method: "POST",
            path: "/api/v1/setup/initialize",
            body: Body(setupCode: setupCode, username: username, password: password),
            authenticated: false
        )
        return response.user
    }

    func login(username: String, password: String) async throws -> RadioLiteAccountLogin {
        struct Body: Encodable { let username: String; let password: String }
        struct Response: Decodable { let user: RadioLiteUser; let csrfToken: String }

        let url = try server.url("/api/v1/session/login")
        var request = RadioLiteNetworkPolicy.request(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try encoder.encode(Body(username: username, password: password))
        let (data, rawResponse) = try await session.data(for: request)
        guard let response = rawResponse as? HTTPURLResponse else {
            throw RadioLiteHTTPError.invalidResponse
        }
        try validate(response: response, data: data)
        let payload = try decoder.decode(Response.self, from: data)
        guard let sessionToken = sessionCookie(from: response, url: url) else {
            throw RadioLiteHTTPError.missingSessionCookie
        }
        let credential = RadioLiteBrowserCredentials(
            sessionToken: sessionToken,
            csrfToken: payload.csrfToken,
            createdAtMs: Int64(Date().timeIntervalSince1970 * 1_000)
        )
        return RadioLiteAccountLogin(user: payload.user, credential: .browser(credential))
    }

    func currentSession() async throws -> RadioLiteAccountLogin {
        struct Response: Decodable { let user: RadioLiteUser; let csrfToken: String }
        guard case .browser(let browser) = credential else {
            throw RadioLiteHTTPError.http(
                status: 401,
                code: "browser_session_required",
                message: "当前凭据不是账户会话"
            )
        }
        let response: Response = try await send(method: "GET", path: "/api/v1/session")
        return RadioLiteAccountLogin(
            user: response.user,
            credential: .browser(.init(
                sessionToken: browser.sessionToken,
                csrfToken: response.csrfToken,
                createdAtMs: browser.createdAtMs
            ))
        )
    }

    func logout() async throws {
        struct Response: Decodable { let ok: Bool }
        let _: Response = try await send(method: "POST", path: "/api/v1/session/logout")
    }

    func redeemPairingCode(_ code: String, deviceName: String) async throws -> RadioLiteDeviceCredentials {
        struct Body: Encodable { let code: String; let deviceName: String }
        return try await send(
            method: "POST",
            path: "/api/v1/pairing/redeem",
            body: Body(code: code, deviceName: deviceName),
            authenticated: false
        )
    }

    func refreshDevice(_ value: RadioLiteDeviceCredentials) async throws -> RadioLiteDeviceCredentials {
        struct Body: Encodable { let deviceId: String; let refreshToken: String }
        return try await send(
            method: "POST",
            path: "/api/v1/device/refresh",
            body: Body(deviceId: value.deviceId, refreshToken: value.refreshToken),
            authenticated: false
        )
    }

    func radios() async throws -> RadioLiteRadiosResponse {
        try await send(method: "GET", path: "/api/v1/radios")
    }

    func hardwareDiscovery() async throws -> RadioLiteHardwareDiscovery {
        try await send(method: "GET", path: "/api/v1/hardware/discovery")
    }

    func testHardware(_ profile: RadioLiteRadioProfile) async throws -> RadioLiteHardwarePreflightResult {
        struct Body: Encodable { let profile: RadioLiteRadioProfile }
        return try await send(
            method: "POST",
            path: "/api/v1/hardware/test",
            body: Body(profile: profile)
        )
    }

    func upsertRadio(
        _ profile: RadioLiteRadioProfile,
        confirmHardwareTransmission: Bool
    ) async throws -> RadioLiteSavedRadioResponse {
        try await send(
            method: "POST",
            path: "/api/v1/radios",
            body: RadioLiteRadioUpsertRequest(
                profile: profile,
                confirmHardwareTransmission: confirmHardwareTransmission
            )
        )
    }

    func users() async throws -> [RadioLiteUser] {
        let response: RadioLiteUsersResponse = try await send(method: "GET", path: "/api/v1/users")
        return response.users
    }

    func createUser(
        username: String,
        password: String,
        role: RadioLiteUserRole,
        canTransmit: Bool,
        mustChangePassword: Bool
    ) async throws -> RadioLiteUser {
        struct Body: Encodable {
            let username: String
            let password: String
            let role: RadioLiteUserRole
            let canTransmit: Bool
            let mustChangePassword: Bool
        }
        let response: RadioLiteCreatedUserResponse = try await send(
            method: "POST",
            path: "/api/v1/users",
            body: Body(
                username: username,
                password: password,
                role: role,
                canTransmit: canTransmit,
                mustChangePassword: mustChangePassword
            )
        )
        return response.user
    }

    func issuePairingCode(userId: String) async throws -> RadioLiteIssuedCode {
        struct Body: Encodable { let userId: String }
        return try await send(
            method: "POST",
            path: "/api/v1/pairing/code",
            body: Body(userId: userId)
        )
    }

    func logs(limit: Int = 100, offset: Int = 0) async throws -> RadioLiteLogPage {
        try await send(
            method: "GET",
            path: "/api/v1/logs",
            queryItems: [
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "offset", value: String(offset)),
            ]
        )
    }

    func grids(resolution: Int = 4) async throws -> RadioLiteGridResponse {
        try await send(
            method: "GET",
            path: "/api/v1/logs/grids",
            queryItems: [URLQueryItem(name: "resolution", value: String(resolution))]
        )
    }

    func addManualQSO(_ qso: RadioLiteManualQSO) async throws -> RadioLiteSavedQSO {
        try await send(method: "POST", path: "/api/v1/logs", body: qso)
    }

    func exportADIF() async throws -> Data {
        let (data, _) = try await rawRequest(
            method: "GET",
            path: "/api/v1/logs/export",
            contentType: nil,
            body: nil
        )
        return data
    }

    func importADIF(_ data: Data) async throws -> (imported: Int, duplicates: Int) {
        struct Response: Decodable { let imported: Int; let duplicates: Int }
        let (responseData, _) = try await rawRequest(
            method: "POST",
            path: "/api/v1/logs/import",
            contentType: "application/adif",
            body: data
        )
        let value = try decoder.decode(Response.self, from: responseData)
        return (value.imported, value.duplicates)
    }

    private func send<Response: Decodable>(
        method: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        authenticated: Bool = true
    ) async throws -> Response {
        let (data, _) = try await rawRequest(
            method: method,
            path: path,
            queryItems: queryItems,
            contentType: nil,
            body: nil,
            authenticated: authenticated
        )
        return try decoder.decode(Response.self, from: data)
    }

    private func send<Response: Decodable, Body: Encodable>(
        method: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        body: Body,
        authenticated: Bool = true
    ) async throws -> Response {
        let encoded = try encoder.encode(body)
        let (data, _) = try await rawRequest(
            method: method,
            path: path,
            queryItems: queryItems,
            contentType: "application/json",
            body: encoded,
            authenticated: authenticated
        )
        return try decoder.decode(Response.self, from: data)
    }

    private func rawRequest(
        method: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        contentType: String?,
        body: Data?,
        authenticated: Bool = true
    ) async throws -> (Data, HTTPURLResponse) {
        let url = try server.url(path, queryItems: queryItems)
        var request = RadioLiteNetworkPolicy.request(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if authenticated { try applyCredential(to: &request, mutating: method != "GET" && method != "HEAD") }
        let (data, rawResponse) = try await session.data(for: request)
        guard let response = rawResponse as? HTTPURLResponse else {
            throw RadioLiteHTTPError.invalidResponse
        }
        try validate(response: response, data: data)
        return (data, response)
    }

    private func applyCredential(to request: inout URLRequest, mutating: Bool) throws {
        guard let credential else {
            throw RadioLiteHTTPError.http(status: 401, code: "authentication_required", message: "请先登录")
        }
        switch credential {
        case .device(let device):
            request.setValue("Bearer \(device.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(device.deviceId, forHTTPHeaderField: "X-Radio-Lite-Device-Id")
        case .browser(let browser):
            request.setValue("rr_session=\(browser.sessionToken)", forHTTPHeaderField: "Cookie")
            if mutating {
                request.setValue(browser.csrfToken, forHTTPHeaderField: "X-CSRF-Token")
            }
        }
    }

    private func validate(response: HTTPURLResponse, data: Data) throws {
        guard (200..<300).contains(response.statusCode) else {
            struct Envelope: Decodable {
                struct Item: Decodable { let code: String; let message: String }
                let error: Item
            }
            let envelope = try? decoder.decode(Envelope.self, from: data)
            throw RadioLiteHTTPError.http(
                status: response.statusCode,
                code: envelope?.error.code ?? "http_\(response.statusCode)",
                message: envelope?.error.message ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            )
        }
    }

    private func sessionCookie(from response: HTTPURLResponse, url: URL) -> String? {
        var fields: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String, let value = value as? String else { continue }
            fields[key] = value
        }
        if let cookie = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
            .first(where: { $0.name == "rr_session" }) {
            return cookie.value
        }
        guard let raw = response.value(forHTTPHeaderField: "Set-Cookie") else { return nil }
        return raw
            .split(separator: ";", maxSplits: 1)
            .first
            .flatMap { pair -> String? in
                let parts = pair.split(separator: "=", maxSplits: 1)
                guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "rr_session" else {
                    return nil
                }
                return String(parts[1])
            }
    }
}
