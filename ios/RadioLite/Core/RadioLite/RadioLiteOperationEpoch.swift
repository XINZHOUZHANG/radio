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

struct RadioLiteVoicePTTStartOwnership: Equatable, Sendable {
    let epoch: UInt64
}

enum RadioLiteVoicePTTStartedDisposition: Equatable, Sendable {
    case bind
    case stop
    case ignore
}

private enum RadioLiteVoicePTTStartPhase: Equatable, Sendable {
    case pendingDispatch
    case dispatchedHolding
    case dispatchedReleased
}

struct RadioLiteVoicePTTStartReleaseState: Equatable, Sendable {
    private var epoch = RadioLiteOperationEpoch()
    private var attempts: [UInt64: RadioLiteVoicePTTStartPhase] = [:]
    private var current: RadioLiteVoicePTTStartOwnership?

    mutating func begin() -> RadioLiteVoicePTTStartOwnership {
        if let current {
            release(current)
        }
        let ownership = RadioLiteVoicePTTStartOwnership(epoch: epoch.begin())
        attempts[ownership.epoch] = .pendingDispatch
        current = ownership
        return ownership
    }

    @discardableResult
    mutating func markStartDispatched(_ ownership: RadioLiteVoicePTTStartOwnership) -> Bool {
        guard current == ownership,
              attempts[ownership.epoch] == .pendingDispatch else {
            return false
        }
        attempts[ownership.epoch] = .dispatchedHolding
        return true
    }

    mutating func release(_ ownership: RadioLiteVoicePTTStartOwnership) {
        guard let phase = attempts[ownership.epoch] else { return }
        if current == ownership {
            current = nil
        }
        switch phase {
        case .pendingDispatch:
            attempts.removeValue(forKey: ownership.epoch)
        case .dispatchedHolding:
            attempts[ownership.epoch] = .dispatchedReleased
        case .dispatchedReleased:
            break
        }
    }

    mutating func receiveStarted(
        _ ownership: RadioLiteVoicePTTStartOwnership
    ) -> RadioLiteVoicePTTStartedDisposition {
        guard let phase = attempts.removeValue(forKey: ownership.epoch) else {
            return .ignore
        }
        let wasCurrent = current == ownership
        if wasCurrent {
            current = nil
        }
        switch phase {
        case .pendingDispatch:
            return .ignore
        case .dispatchedHolding:
            return wasCurrent ? .bind : .stop
        case .dispatchedReleased:
            return .stop
        }
    }

    mutating func failStart(_ ownership: RadioLiteVoicePTTStartOwnership) {
        attempts.removeValue(forKey: ownership.epoch)
        if current == ownership {
            current = nil
        }
    }
}

struct RadioLiteVoicePTTReleaseOwnership: Equatable, Sendable {
    let epoch: UInt64
}

struct RadioLiteVoicePTTReleaseState: Equatable, Sendable {
    private var epoch = RadioLiteOperationEpoch()

    mutating func beginTransmit() {
        epoch.invalidate()
    }

    mutating func beginRelease() -> RadioLiteVoicePTTReleaseOwnership {
        RadioLiteVoicePTTReleaseOwnership(epoch: epoch.begin())
    }

    func mayResume(
        _ ownership: RadioLiteVoicePTTReleaseOwnership,
        voicePTTHeld: Bool,
        tuning: Bool,
        capturingMicrophone: Bool
    ) -> Bool {
        epoch.owns(ownership.epoch)
            && !voicePTTHeld
            && !tuning
            && !capturingMicrophone
    }
}

enum RadioLiteVoicePTTStopReason: Equatable, Sendable {
    case userRelease
    case transmitFailure
    case operatorCancellation
    case connectionLoss
    case audioInterruption

    var restoresReceiveMonitoring: Bool {
        switch self {
        case .userRelease, .transmitFailure, .operatorCancellation: return true
        case .connectionLoss, .audioInterruption: return false
        }
    }
}

enum RadioLiteTransmitReceiveRecoverySource: Equatable, Sendable {
    case voicePTT
    case audioInterruption
    case none

    static func select(
        voicePTTRestore: RadioLiteReceiveMonitoringOwnership?,
        audioInterruptionRestore: RadioLiteReceiveMonitoringOwnership?
    ) -> Self {
        if voicePTTRestore != nil { return .voicePTT }
        if audioInterruptionRestore != nil { return .audioInterruption }
        return .none
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
