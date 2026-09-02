import Foundation

struct RadioLiteCredentialRefreshKey: Hashable, Sendable {
    let server: RadioLiteServer
    let deviceId: String
}

struct RadioLiteCredentialRefreshRequest: Equatable, Sendable {
    let key: RadioLiteCredentialRefreshKey
    let refreshToken: String

    init(server: RadioLiteServer, current: RadioLiteDeviceCredentials) {
        key = RadioLiteCredentialRefreshKey(server: server, deviceId: current.deviceId)
        refreshToken = current.refreshToken
    }

    func matches(server: RadioLiteServer?, credential: RadioLiteCredential?) -> Bool {
        guard server == key.server,
              case .device(let device) = credential else {
            return false
        }
        return device.deviceId == key.deviceId && device.refreshToken == refreshToken
    }

    func matchesCurrentOrRefreshed(
        server: RadioLiteServer?,
        credential: RadioLiteCredential?,
        refreshed: RadioLiteDeviceCredentials
    ) -> Bool {
        matches(server: server, credential: credential)
            || (server == key.server && credential == .device(refreshed))
    }
}

struct RadioLiteCredentialRefreshLease: Identifiable, Equatable, Sendable {
    let id: UUID
    let request: RadioLiteCredentialRefreshRequest
    let credentials: RadioLiteDeviceCredentials
}

struct RadioLiteCredentialAccountOwnership: Equatable, Sendable {
    let key: RadioLiteCredentialRefreshKey
    let epoch: UInt64
}

struct RadioLiteCredentialAccountOwnershipState: Equatable, Sendable {
    private var epoch = RadioLiteOperationEpoch()
    private var current: RadioLiteCredentialAccountOwnership?

    mutating func activate(
        server: RadioLiteServer,
        credential: RadioLiteDeviceCredentials
    ) -> RadioLiteCredentialAccountOwnership {
        let ownership = RadioLiteCredentialAccountOwnership(
            key: RadioLiteCredentialRefreshKey(server: server, deviceId: credential.deviceId),
            epoch: epoch.begin()
        )
        current = ownership
        return ownership
    }

    func ownership(
        matching key: RadioLiteCredentialRefreshKey
    ) -> RadioLiteCredentialAccountOwnership? {
        guard let current, current.key == key, epoch.owns(current.epoch) else { return nil }
        return current
    }

    func isCurrent(_ ownership: RadioLiteCredentialAccountOwnership) -> Bool {
        current == ownership && epoch.owns(ownership.epoch)
    }

    mutating func invalidate() {
        epoch.invalidate()
        current = nil
    }
}

@MainActor
final class RadioLiteCredentialRefreshCoordinator {
    typealias RefreshOperation = @Sendable (
        RadioLiteDeviceCredentials
    ) async throws -> RadioLiteDeviceCredentials
    typealias CommitOperation = @MainActor @Sendable (
        RadioLiteCredentialRefreshRequest,
        RadioLiteDeviceCredentials
    ) throws -> Void

    private enum FlightState {
        case running(Task<RadioLiteCredentialRefreshLease, Error>)
        case pendingCommit(RadioLiteDeviceCredentials)
        case retryingCommit(
            RadioLiteDeviceCredentials,
            Task<RadioLiteCredentialRefreshLease, Error>
        )
        case committed(RadioLiteCredentialRefreshLease)
    }

    private struct Flight {
        let id: UUID
        let request: RadioLiteCredentialRefreshRequest
        var waiterCount: Int
        var state: FlightState
    }

    private var flights: [RadioLiteCredentialRefreshKey: Flight] = [:]

    func hasPendingCommit(server: RadioLiteServer, deviceId: String) -> Bool {
        let key = RadioLiteCredentialRefreshKey(server: server, deviceId: deviceId)
        guard let flight = flights[key] else { return false }
        switch flight.state {
        case .pendingCommit, .retryingCommit:
            return true
        case .running, .committed:
            return false
        }
    }

    func pendingCommitCredentials(
        server: RadioLiteServer,
        deviceId: String
    ) -> RadioLiteDeviceCredentials? {
        let key = RadioLiteCredentialRefreshKey(server: server, deviceId: deviceId)
        guard let flight = flights[key] else { return nil }
        switch flight.state {
        case .pendingCommit(let credentials), .retryingCommit(let credentials, _):
            return credentials
        case .running, .committed:
            return nil
        }
    }

    func refresh(
        server: RadioLiteServer,
        current: RadioLiteDeviceCredentials,
        operation: @escaping RefreshOperation,
        commit: @escaping CommitOperation
    ) async throws -> RadioLiteCredentialRefreshLease {
        let key = RadioLiteCredentialRefreshKey(server: server, deviceId: current.deviceId)
        let flightID: UUID
        let task: Task<RadioLiteCredentialRefreshLease, Error>

        if var flight = flights[key] {
            flight.waiterCount += 1
            flightID = flight.id
            switch flight.state {
            case .running(let existing), .retryingCommit(_, let existing):
                task = existing
            case .pendingCommit(let credentials):
                let retry = makeCommitRetryTask(
                    key: key,
                    flightID: flight.id,
                    credentials: credentials,
                    commit: commit
                )
                flight.state = .retryingCommit(credentials, retry)
                task = retry
            case .committed(let lease):
                flights[key] = flight
                releaseWaiter(key: key, flightID: flight.id)
                try Task.checkCancellation()
                return lease
            }
            flights[key] = flight
        } else {
            let request = RadioLiteCredentialRefreshRequest(server: server, current: current)
            let id = UUID()
            let created = makeRefreshTask(
                key: key,
                flightID: id,
                request: request,
                current: current,
                operation: operation,
                commit: commit
            )
            flights[key] = Flight(
                id: id,
                request: request,
                waiterCount: 1,
                state: .running(created)
            )
            flightID = id
            task = created
        }

        do {
            let lease = try await waitForSharedTask(task)
            releaseWaiter(key: key, flightID: flightID)
            return lease
        } catch {
            releaseWaiter(key: key, flightID: flightID)
            throw error
        }
    }

    private func makeRefreshTask(
        key: RadioLiteCredentialRefreshKey,
        flightID: UUID,
        request: RadioLiteCredentialRefreshRequest,
        current: RadioLiteDeviceCredentials,
        operation: @escaping RefreshOperation,
        commit: @escaping CommitOperation
    ) -> Task<RadioLiteCredentialRefreshLease, Error> {
        Task { @MainActor [weak self] in
            do {
                let credentials = try await operation(current)
                guard credentials.deviceId == key.deviceId else {
                    throw RadioLiteHTTPError.invalidResponse
                }
                guard let self else { throw CancellationError() }
                let lease = try self.commitResponse(
                    key: key,
                    flightID: flightID,
                    request: request,
                    credentials: credentials,
                    commit: commit
                )
                self.removeCommittedFlightIfUnobserved(key: key, flightID: flightID)
                return lease
            } catch {
                self?.removeFailedFlightIfNeeded(key: key, flightID: flightID)
                throw error
            }
        }
    }

    private func makeCommitRetryTask(
        key: RadioLiteCredentialRefreshKey,
        flightID: UUID,
        credentials: RadioLiteDeviceCredentials,
        commit: @escaping CommitOperation
    ) -> Task<RadioLiteCredentialRefreshLease, Error> {
        Task { @MainActor [weak self] in
            do {
                guard let self,
                      let request = self.request(key: key, flightID: flightID) else {
                    throw CancellationError()
                }
                let lease = try self.commitResponse(
                    key: key,
                    flightID: flightID,
                    request: request,
                    credentials: credentials,
                    commit: commit
                )
                self.removeCommittedFlightIfUnobserved(key: key, flightID: flightID)
                return lease
            } catch {
                self?.removeFailedFlightIfNeeded(key: key, flightID: flightID)
                throw error
            }
        }
    }

    private func waitForSharedTask(
        _ task: Task<RadioLiteCredentialRefreshLease, Error>
    ) async throws -> RadioLiteCredentialRefreshLease {
        let stream = AsyncThrowingStream<RadioLiteCredentialRefreshLease, Error> { continuation in
            let relay = Task { @MainActor in
                do {
                    continuation.yield(try await task.value)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in relay.cancel() }
        }
        var iterator = stream.makeAsyncIterator()
        guard let lease = try await iterator.next() else { throw CancellationError() }
        try Task.checkCancellation()
        return lease
    }

    private func commitResponse(
        key: RadioLiteCredentialRefreshKey,
        flightID: UUID,
        request: RadioLiteCredentialRefreshRequest,
        credentials: RadioLiteDeviceCredentials,
        commit: CommitOperation
    ) throws -> RadioLiteCredentialRefreshLease {
        guard var flight = flights[key],
              flight.id == flightID,
              flight.request == request else {
            throw CancellationError()
        }
        flight.state = .pendingCommit(credentials)
        flights[key] = flight

        do {
            try commit(request, credentials)
        } catch is CancellationError {
            discardFlight(key: key, flightID: flightID)
            throw CancellationError()
        } catch {
            throw error
        }

        let lease = RadioLiteCredentialRefreshLease(
            id: flightID,
            request: request,
            credentials: credentials
        )
        guard var committed = flights[key], committed.id == flightID else {
            throw CancellationError()
        }
        committed.state = .committed(lease)
        flights[key] = committed
        return lease
    }

    private func request(
        key: RadioLiteCredentialRefreshKey,
        flightID: UUID
    ) -> RadioLiteCredentialRefreshRequest? {
        guard let flight = flights[key], flight.id == flightID else { return nil }
        return flight.request
    }

    private func releaseWaiter(key: RadioLiteCredentialRefreshKey, flightID: UUID) {
        guard var flight = flights[key], flight.id == flightID else { return }
        flight.waiterCount = max(0, flight.waiterCount - 1)
        guard flight.waiterCount == 0 else {
            flights[key] = flight
            return
        }
        switch flight.state {
        case .running, .pendingCommit, .retryingCommit:
            flights[key] = flight
        case .committed:
            flights.removeValue(forKey: key)
        }
    }

    private func removeCommittedFlightIfUnobserved(
        key: RadioLiteCredentialRefreshKey,
        flightID: UUID
    ) {
        guard let flight = flights[key],
              flight.id == flightID,
              flight.waiterCount == 0,
              case .committed = flight.state else {
            return
        }
        flights.removeValue(forKey: key)
    }

    private func removeFailedFlightIfNeeded(
        key: RadioLiteCredentialRefreshKey,
        flightID: UUID
    ) {
        guard let flight = flights[key], flight.id == flightID else { return }
        if case .running = flight.state {
            flights.removeValue(forKey: key)
        }
    }

    private func discardFlight(key: RadioLiteCredentialRefreshKey, flightID: UUID) {
        guard flights[key]?.id == flightID else { return }
        flights.removeValue(forKey: key)
    }
}
