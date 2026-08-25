import Foundation

enum RadioLiteSocketState: Equatable, Sendable {
    case disconnected
    case connecting
    case ready
    case failed(String)

    var label: String {
        switch self {
        case .disconnected: "未连接"
        case .connecting: "连接中"
        case .ready: "已连接"
        case .failed: "故障"
        }
    }
}

enum RadioLiteSocketError: LocalizedError, Equatable {
    case notConnected
    case invalidWelcome
    case unexpectedBinary
    case command(code: String, message: String)
    case timedOut
    case closed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: "WebSocket 尚未连接"
        case .invalidWelcome: "服务器没有返回有效的 Radio Lite 认证消息"
        case .unexpectedBinary: "认证期间收到了意外的二进制数据"
        case .command(_, let message): message
        case .timedOut: "等待服务器响应超过 5 分钟"
        case .closed(let message): message
        }
    }
}

@MainActor
final class RadioLiteWebSocketChannel {
    var onJSON: ((JSONValue) -> Void)?
    var onBinary: ((Data) -> Void)?
    var onDisconnect: ((Error) -> Void)?

    private struct PendingResponse {
        let expectedTypes: Set<String>
        let commandId: String?
        let requestType: String?
        let continuation: CheckedContinuation<JSONValue, Error>
        var timeoutTask: Task<Void, Never>?
    }

    private var socket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var receiveTask: Task<Void, Never>?
    private var generation = 0
    private var pending: [UUID: PendingResponse] = [:]
    private(set) var state: RadioLiteSocketState = .disconnected

    func connect(
        server: RadioLiteServer,
        credential: RadioLiteCredential,
        path: String,
        expectedChannel: String
    ) async throws -> RadioLiteAuthWelcome {
        disconnect(notify: false)
        generation += 1
        let activeGeneration = generation
        state = .connecting

        let configuration = RadioLiteNetworkPolicy.configuration()
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration)
        var request = RadioLiteNetworkPolicy.request(url: try server.webSocketURL(path))
        request.setValue("radio-lite.v1", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        if case .browser(let browser) = credential {
            request.setValue("rr_session=\(browser.sessionToken)", forHTTPHeaderField: "Cookie")
        }
        let task = session.webSocketTask(with: request)
        urlSession = session
        socket = task
        task.resume()

        do {
            if case .device(let device) = credential {
                try await task.send(.string(JSONValue.object(
                    ("t", .string("auth.device")),
                    ("deviceId", .string(device.deviceId)),
                    ("accessToken", .string(device.accessToken))
                ).encodedText))
            }
            let first = try await task.receive()
            guard activeGeneration == generation, socket === task else { throw CancellationError() }
            guard case .string(let text) = first else { throw RadioLiteSocketError.unexpectedBinary }
            let value = try JSONValue.parse(text)
            guard value["t"]?.stringValue == "auth.ok",
                  let welcome: RadioLiteAuthWelcome = value.decoded(),
                  welcome.channel == expectedChannel,
                  welcome.protocolVersion == 1 else {
                throw RadioLiteSocketError.invalidWelcome
            }
            state = .ready
            receiveTask = Task { [weak self] in
                await self?.receiveLoop(task, generation: activeGeneration)
            }
            return welcome
        } catch {
            guard activeGeneration == generation else { throw error }
            state = .failed(error.localizedDescription)
            task.cancel(with: .protocolError, reason: nil)
            socket = nil
            session.invalidateAndCancel()
            urlSession = nil
            throw error
        }
    }

    func disconnect(notify: Bool = false) {
        generation += 1
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        state = .disconnected
        failAllPending(RadioLiteSocketError.closed("连接已关闭"))
        if notify { onDisconnect?(RadioLiteSocketError.closed("连接已关闭")) }
    }

    func send(_ value: JSONValue) async throws {
        guard let socket, state == .ready else { throw RadioLiteSocketError.notConnected }
        try await socket.send(.string(value.encodedText))
    }

    func send(_ data: Data) async throws {
        guard let socket, state == .ready else { throw RadioLiteSocketError.notConnected }
        try await socket.send(.data(data))
    }

    func request(
        _ value: JSONValue,
        expecting expectedTypes: Set<String>,
        commandId: String? = nil,
        requestType: String? = nil
    ) async throws -> JSONValue {
        guard socket != nil, state == .ready else { throw RadioLiteSocketError.notConnected }
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = PendingResponse(
                expectedTypes: expectedTypes,
                commandId: commandId,
                requestType: requestType ?? value["t"]?.stringValue,
                continuation: continuation,
                timeoutTask: nil
            )
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(RadioLiteNetworkPolicy.timeout))
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.failPending(id, error: RadioLiteSocketError.timedOut) }
            }
            pending[id]?.timeoutTask = timeoutTask
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.send(value)
                } catch {
                    self.failPending(id, error: error)
                }
            }
        }
    }

    func sendPing() {
        socket?.sendPing { _ in }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask, generation activeGeneration: Int) async {
        do {
            while !Task.isCancelled {
                let message = try await task.receive()
                guard activeGeneration == generation, socket === task else { return }
                switch message {
                case .string(let text):
                    dispatch(try JSONValue.parse(text))
                case .data(let data):
                    onBinary?(data)
                @unknown default:
                    continue
                }
            }
        } catch {
            guard activeGeneration == generation, socket === task else { return }
            socket = nil
            state = .failed(error.localizedDescription)
            failAllPending(error)
            onDisconnect?(error)
        }
    }

    private func dispatch(_ value: JSONValue) {
        let type = value["t"]?.stringValue
        let commandId = value["commandId"]?.stringValue
        let requestType = value["requestType"]?.stringValue
        if let match = pending.first(where: { _, item in
            let commandMatches = item.commandId == nil || item.commandId == commandId
            if type == "command.error" {
                return commandMatches && (item.requestType == nil || item.requestType == requestType)
            }
            return commandMatches && type.map(item.expectedTypes.contains) == true
        }) {
            let id = match.key
            let item = match.value
            pending.removeValue(forKey: id)
            item.timeoutTask?.cancel()
            if type == "command.error" {
                item.continuation.resume(throwing: RadioLiteSocketError.command(
                    code: value["code"]?.stringValue ?? "command_error",
                    message: value["message"]?.stringValue ?? "服务器拒绝了操作"
                ))
            } else {
                item.continuation.resume(returning: value)
            }
        }
        onJSON?(value)
    }

    private func failPending(_ id: UUID, error: Error) {
        guard let item = pending.removeValue(forKey: id) else { return }
        item.timeoutTask?.cancel()
        item.continuation.resume(throwing: error)
    }

    private func failAllPending(_ error: Error) {
        let values = Array(pending.values)
        pending.removeAll()
        for item in values {
            item.timeoutTask?.cancel()
            item.continuation.resume(throwing: error)
        }
    }
}

private extension JSONValue {
    var encodedText: String {
        guard let data = try? JSONEncoder().encode(self),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
