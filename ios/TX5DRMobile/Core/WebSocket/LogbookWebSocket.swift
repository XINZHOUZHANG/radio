import Combine
import Foundation

enum LogbookSocketState: Equatable {
    case disconnected
    case connecting
    case ready
    case failed(String)

    var label: String {
        switch self {
        case .disconnected: "未连接"
        case .connecting: "连接中"
        case .ready: "实时同步"
        case .failed: "同步中断"
        }
    }
}

enum LogbookRealtimeEventKind: String, Sendable {
    case changeNotice = "logbookChangeNotice"
    case qsoAdded = "qsoRecordAdded"
    case qsoUpdated = "qsoRecordUpdated"
    case logbookUpdated
    case healthChanged = "logbookHealthChanged"
    case writeFailed = "logbookWriteFailed"
    case operatorStatus = "operatorStatusUpdate"
    case operatorsList
}

struct LogbookRealtimeEvent: Equatable, Sendable {
    let kind: LogbookRealtimeEventKind
    let payload: JSONValue

    init?(envelope: WSInboundEnvelope) {
        guard let kind = LogbookRealtimeEventKind(rawValue: envelope.type),
              let payload = envelope.data else {
            return nil
        }
        self.kind = kind
        self.payload = payload
    }

    var logBookId: String? { payload["logBookId"]?.stringValue }
    var operatorId: String? { payload["operatorId"]?.stringValue }
    var writeFailureMessage: String? { payload["error"]?["message"]?.stringValue }
    var writeFailureCode: String? { payload["error"]?["code"]?.stringValue }
    var unsavedCount: Int? { payload["unsavedCount"]?.intValue }
}

enum LogbookRealtimeRefreshPolicy {
    static func logBookId(
        for event: LogbookRealtimeEvent,
        selectedLogBookId: String?,
        selectedOperatorId: String?
    ) -> String? {
        let hasTarget = event.logBookId != nil || event.operatorId != nil
        let matchesSelectedLogbook = event.logBookId != nil && event.logBookId == selectedLogBookId
        let matchesSelectedOperator = event.operatorId != nil && event.operatorId == selectedOperatorId
        guard !hasTarget || matchesSelectedLogbook || matchesSelectedOperator else { return nil }
        return event.logBookId ?? selectedLogBookId
    }
}

@MainActor
final class LogbookWebSocket: ObservableObject {
    @Published private(set) var state: LogbookSocketState = .disconnected
    @Published private(set) var lastEvent: LogbookRealtimeEvent?

    var onEvent: ((LogbookRealtimeEvent) -> Void)?

    private let session: URLSession
    private let decoder = JSONDecoder()
    private var server: TX5DRServer?
    private var jwt: String?
    private var operatorId: String?
    private var logBookId: String?
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var shouldReconnect = false

    init(session: URLSession = TX5DRNetworkPolicy.webSocketSession) {
        self.session = session
    }

    func configure(server: TX5DRServer, jwt: String, operatorId: String?, logBookId: String?) {
        let changed = self.server != server
            || self.jwt != jwt
            || self.operatorId != operatorId
            || self.logBookId != logBookId
        guard changed else { return }

        disconnect()
        self.server = server
        self.jwt = jwt
        self.operatorId = operatorId
        self.logBookId = logBookId
    }

    func connect() {
        guard task == nil,
              let server,
              let jwt,
              !jwt.isEmpty,
              operatorId != nil || logBookId != nil else {
            return
        }

        shouldReconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil

        do {
            var queryItems: [URLQueryItem] = []
            if let operatorId { queryItems.append(URLQueryItem(name: "operatorId", value: operatorId)) }
            if let logBookId { queryItems.append(URLQueryItem(name: "logBookId", value: logBookId)) }
            queryItems.append(URLQueryItem(name: "token", value: jwt))

            let url = try server.webSocketURL("/ws/logbook", queryItems: queryItems)
            let socket = TX5DRNetworkPolicy.webSocketTask(session: session, url: url)
            task = socket
            state = .connecting
            socket.resume()
            state = .ready
            reconnectAttempt = 0
            receiveTask = Task { [weak self] in
                await self?.receiveLoop(socket)
            }
            heartbeatTask = Task { [weak self] in
                await self?.heartbeatLoop(socket)
            }
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
        state = .disconnected
    }

    private func receiveLoop(_ socket: URLSessionWebSocketTask) async {
        do {
            while !Task.isCancelled {
                let message = try await socket.receive()
                let envelope: WSInboundEnvelope
                switch message {
                case .string(let text):
                    guard let data = text.data(using: .utf8) else { continue }
                    envelope = try decoder.decode(WSInboundEnvelope.self, from: data)
                case .data(let data):
                    envelope = try decoder.decode(WSInboundEnvelope.self, from: data)
                @unknown default:
                    continue
                }
                handle(envelope)
            }
        } catch {
            guard task === socket else { return }
            task = nil
            receiveTask = nil
            heartbeatTask?.cancel()
            heartbeatTask = nil
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
            do { try await Task.sleep(for: .seconds(25)) }
            catch { return }
            guard task === socket, !Task.isCancelled else { return }
            socket.sendPing { _ in }
        }
    }

    private func handle(_ envelope: WSInboundEnvelope) {
        guard let event = LogbookRealtimeEvent(envelope: envelope) else { return }
        lastEvent = event
        onEvent?(event)
    }

    private func scheduleReconnect() {
        guard shouldReconnect, reconnectTask == nil else { return }
        reconnectAttempt += 1
        let delay = min(pow(2, Double(reconnectAttempt - 1)), 8)
        reconnectTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            guard let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            self.connect()
        }
    }
}
