import Foundation

enum TX5DRServerError: LocalizedError, Equatable {
    case emptyAddress
    case unsupportedScheme
    case invalidAddress

    var errorDescription: String? {
        switch self {
        case .emptyAddress: "请输入服务器地址"
        case .unsupportedScheme: "服务器地址只支持 HTTP 或 HTTPS"
        case .invalidAddress: "服务器地址格式无效"
        }
    }
}

struct TX5DRServer: Codable, Hashable, Sendable {
    let baseURL: URL

    init(address: String) throws {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TX5DRServerError.emptyAddress }
        let candidate = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard var components = URLComponents(string: candidate), let scheme = components.scheme?.lowercased() else {
            throw TX5DRServerError.invalidAddress
        }
        guard scheme == "http" || scheme == "https" else { throw TX5DRServerError.unsupportedScheme }
        guard let host = components.host, !host.isEmpty else { throw TX5DRServerError.invalidAddress }
        components.scheme = scheme
        components.path = components.path.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw TX5DRServerError.invalidAddress }
        baseURL = url
    }

    var displayAddress: String { baseURL.absoluteString }

    func apiURL(_ path: String, queryItems: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw TX5DRServerError.invalidAddress
        }
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        let apiPath = normalizedPath.hasPrefix("/api/") || normalizedPath == "/api"
            ? normalizedPath
            : "/api\(normalizedPath)"
        components.path = baseURL.path + apiPath
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else { throw TX5DRServerError.invalidAddress }
        return url
    }

    func webSocketURL(_ path: String, queryItems: [URLQueryItem] = []) throws -> URL {
        let httpURL = try apiURL(path, queryItems: queryItems)
        guard var components = URLComponents(url: httpURL, resolvingAgainstBaseURL: false) else {
            throw TX5DRServerError.invalidAddress
        }
        components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        guard let url = components.url else { throw TX5DRServerError.invalidAddress }
        return url
    }

    func externalizedOfferURL(_ offeredURL: URL, token: String) throws -> URL {
        guard var components = URLComponents(url: offeredURL, resolvingAgainstBaseURL: false),
              let baseComponents = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw TX5DRServerError.invalidAddress
        }
        if components.host == "127.0.0.1" || components.host == "localhost" || components.host == "0.0.0.0" {
            components.host = baseComponents.host
            components.port = baseComponents.port
        }
        components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "token" }
        items.append(URLQueryItem(name: "token", value: token))
        components.queryItems = items
        guard let url = components.url else { throw TX5DRServerError.invalidAddress }
        return url
    }
}
