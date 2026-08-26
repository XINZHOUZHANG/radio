import Combine
import Foundation

@MainActor
final class RadioLiteControlClient: ObservableObject {
    @Published private(set) var state: RadioLiteSocketState = .disconnected
    @Published private(set) var lastRoundTripMs: Double = 0

    var onEvent: ((JSONValue) -> Void)?
    var onDisconnect: ((Error) -> Void)?

    private let channel = RadioLiteWebSocketChannel()
    private var pingStartedAt: Date?
    private var pingTask: Task<Void, Never>?

    init() {
        channel.onJSON = { [weak self] value in
            guard let self else { return }
            if value["t"]?.stringValue == "pong", let started = self.pingStartedAt {
                self.lastRoundTripMs = max(0, Date().timeIntervalSince(started) * 1_000)
                self.pingStartedAt = nil
            }
            self.onEvent?(value)
        }
        channel.onDisconnect = { [weak self] error in
            self?.state = .failed(error.localizedDescription)
            self?.pingTask?.cancel()
            self?.onDisconnect?(error)
        }
    }

    func connect(server: RadioLiteServer, credential: RadioLiteCredential) async throws -> RadioLiteAuthWelcome {
        state = .connecting
        do {
            let welcome = try await channel.connect(
                server: server,
                credential: credential,
                path: "/ws/control",
                expectedChannel: "control"
            )
            state = .ready
            startPings()
            return welcome
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    func disconnect() {
        pingTask?.cancel()
        pingTask = nil
        pingStartedAt = nil
        channel.disconnect()
        state = .disconnected
    }

    func send(_ value: JSONValue) async throws {
        try await channel.send(value)
    }

    func request(
        _ value: JSONValue,
        expecting: Set<String>,
        commandId: String? = nil
    ) async throws -> JSONValue {
        try await channel.request(
            value,
            expecting: expecting,
            commandId: commandId,
            requestType: value["t"]?.stringValue
        )
    }

    private func startPings() {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled, let self, self.state == .ready else { return }
                self.pingStartedAt = Date()
                try? await self.channel.send(.object(["t": .string("ping")]))
            }
        }
    }
}
