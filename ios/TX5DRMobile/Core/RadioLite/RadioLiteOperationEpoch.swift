import Foundation

struct RadioLiteOperationEpoch: Equatable, Sendable {
    private(set) var current: UInt64 = 0

    mutating func begin() -> UInt64 {
        advance()
        return current
    }

    mutating func invalidate() {
        advance()
    }

    func owns(_ value: UInt64) -> Bool {
        value != 0 && value == current
    }

    private mutating func advance() {
        current &+= 1
        if current == 0 { current = 1 }
    }
}

struct RadioLiteReconnectOwnership: Equatable, Sendable {
    let epoch: UInt64
}

struct RadioLiteReconnectOwnershipState: Equatable, Sendable {
    private var epoch = RadioLiteOperationEpoch()
    private var current: RadioLiteReconnectOwnership?

    mutating func begin() -> RadioLiteReconnectOwnership {
        let ownership = RadioLiteReconnectOwnership(epoch: epoch.begin())
        current = ownership
        return ownership
    }

    func isCurrent(_ ownership: RadioLiteReconnectOwnership) -> Bool {
        current == ownership && epoch.owns(ownership.epoch)
    }

    @discardableResult
    mutating func complete(_ ownership: RadioLiteReconnectOwnership) -> Bool {
        guard isCurrent(ownership) else { return false }
        epoch.invalidate()
        current = nil
        return true
    }

    mutating func invalidate() {
        epoch.invalidate()
        current = nil
    }
}

struct RadioLiteAuthenticationOwnership: Equatable, Sendable {
    let epoch: UInt64
}

struct RadioLiteAuthenticationOwnershipState: Equatable, Sendable {
    private var epoch = RadioLiteOperationEpoch()
    private var current: RadioLiteAuthenticationOwnership?

    mutating func begin() -> RadioLiteAuthenticationOwnership {
        let ownership = RadioLiteAuthenticationOwnership(epoch: epoch.begin())
        current = ownership
        return ownership
    }

    func isCurrent(_ ownership: RadioLiteAuthenticationOwnership) -> Bool {
        current == ownership && epoch.owns(ownership.epoch)
    }

    var currentOwnership: RadioLiteAuthenticationOwnership? {
        guard let current, epoch.owns(current.epoch) else { return nil }
        return current
    }

    mutating func invalidate() {
        epoch.invalidate()
        current = nil
    }
}

enum RadioLiteReconnectFailureStage: Equatable, Sendable {
    case credentialRefresh
    case channelReconnect
}

enum RadioLiteReconnectFailureDisposition: Equatable, Sendable {
    case benign
    case retry
    case signOut
}

enum RadioLiteReconnectFailurePolicy {
    static func disposition(
        for error: Error,
        stage: RadioLiteReconnectFailureStage
    ) -> RadioLiteReconnectFailureDisposition {
        if error is CancellationError { return .benign }
        if stage == .credentialRefresh,
           let httpError = error as? RadioLiteHTTPError,
           httpError.isUnauthorized {
            return .signOut
        }
        return .retry
    }
}

private struct RadioLiteVoicePTTReceiveRestoreEntry: Equatable, Sendable {
    let monitoring: RadioLiteReceiveMonitoringOwnership
    let transmitGeneration: UInt64
}

struct RadioLiteVoicePTTReceiveRestoreState: Equatable, Sendable {
    private var current: RadioLiteVoicePTTReceiveRestoreEntry?

    mutating func assign(
        _ monitoring: RadioLiteReceiveMonitoringOwnership,
        transmitGeneration: UInt64
    ) {
        current = RadioLiteVoicePTTReceiveRestoreEntry(
            monitoring: monitoring,
            transmitGeneration: transmitGeneration
        )
    }

    mutating func take(transmitGeneration: UInt64) -> RadioLiteReceiveMonitoringOwnership? {
        guard current?.transmitGeneration == transmitGeneration else { return nil }
        defer { current = nil }
        return current?.monitoring
    }

    mutating func invalidate() {
        current = nil
    }
}

enum RadioLiteVoicePTTStopReason: Equatable, Sendable {
    case userRelease
    case transmitFailure
    case connectionLoss
    case audioInterruption

    var restoresReceiveMonitoring: Bool {
        switch self {
        case .userRelease, .transmitFailure: return true
        case .connectionLoss, .audioInterruption: return false
        }
    }
}

struct RadioLiteRadioConfigurationReconnectOwnership: Equatable, Sendable {
    let radioId: String
    let epoch: UInt64
}

struct RadioLiteRadioConfigurationReconnectOwnershipState: Equatable, Sendable {
    private var epoch = RadioLiteOperationEpoch()
    private var current: RadioLiteRadioConfigurationReconnectOwnership?

    mutating func begin(radioId: String) -> RadioLiteRadioConfigurationReconnectOwnership {
        let ownership = RadioLiteRadioConfigurationReconnectOwnership(
            radioId: radioId,
            epoch: epoch.begin()
        )
        current = ownership
        return ownership
    }

    func isCurrent(
        _ ownership: RadioLiteRadioConfigurationReconnectOwnership,
        selectedRadioId: String?
    ) -> Bool {
        current == ownership
            && epoch.owns(ownership.epoch)
            && selectedRadioId == ownership.radioId
    }

    @discardableResult
    mutating func complete(
        _ ownership: RadioLiteRadioConfigurationReconnectOwnership,
        selectedRadioId: String?
    ) -> Bool {
        guard isCurrent(ownership, selectedRadioId: selectedRadioId) else { return false }
        epoch.invalidate()
        current = nil
        return true
    }

    mutating func invalidate() {
        epoch.invalidate()
        current = nil
    }
}
