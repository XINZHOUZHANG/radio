import Foundation

enum RadioLiteServerError: LocalizedError, Equatable {
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
struct RadioLiteServer: Codable, Hashable, Sendable {
    let baseURL: URL

    init(address: String) throws {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RadioLiteServerError.emptyAddress }
        let candidate = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else {
            if let scheme = URLComponents(string: candidate)?.scheme,
               scheme.lowercased() != "http", scheme.lowercased() != "https" {
                throw RadioLiteServerError.unsupportedScheme
            }
            throw RadioLiteServerError.invalidAddress
        }
        components.scheme = scheme
        components.path = components.path.replacingOccurrences(
            of: "/+$",
            with: "",
            options: .regularExpression
        )
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw RadioLiteServerError.invalidAddress }
        baseURL = url
    }

    var displayAddress: String { baseURL.absoluteString }

    func url(_ path: String, queryItems: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw RadioLiteServerError.invalidAddress
        }
        let suffix = path.hasPrefix("/") ? path : "/\(path)"
        components.path = baseURL.path + suffix
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let result = components.url else { throw RadioLiteServerError.invalidAddress }
        return result
    }

    func webSocketURL(_ path: String) throws -> URL {
        let value = try url(path)
        guard var components = URLComponents(url: value, resolvingAgainstBaseURL: false) else {
            throw RadioLiteServerError.invalidAddress
        }
        components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        guard let result = components.url else { throw RadioLiteServerError.invalidAddress }
        return result
    }
}

enum RadioLiteNetworkPolicy {
    static let timeout: TimeInterval = 300

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return configuration
    }

    static func request(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }
}

enum RadioLiteStartupRestorePolicy {
    static let deadline: TimeInterval = 10
    static let escapeDelay: TimeInterval = 3

    static func timeoutMessage(serverAddress: String) -> String {
        "无法连接到上次使用的服务器 \(serverAddress)，请检查网络或换一个地址"
    }
}
