import Foundation

enum RadioLiteReceiveMonitoringVisitDecision: Equatable, Sendable {
    case start
    case stop
    case preserve
}

struct RadioLiteReceiveMonitoringPreference: Equatable, Sendable {
    private(set) var hasVisitedRadioPage: Bool
    private(set) var explicitUserChoice: Bool?

    init(hasVisitedRadioPage: Bool, explicitUserChoice: Bool?) {
        self.hasVisitedRadioPage = hasVisitedRadioPage
        self.explicitUserChoice = explicitUserChoice
    }

    mutating func radioPageDidAppear() -> RadioLiteReceiveMonitoringVisitDecision {
        let firstVisit = !hasVisitedRadioPage
        hasVisitedRadioPage = true
        if let explicitUserChoice {
            return explicitUserChoice ? .start : .stop
        }
        return firstVisit ? .start : .preserve
    }

    mutating func recordExplicitUserChoice(_ enabled: Bool) {
        explicitUserChoice = enabled
    }
}

struct RadioLiteReceiveMonitoringIntent: Equatable, Sendable {
    private(set) var isDesired = false
    private(set) var isSuspended = false
    private(set) var generation: UInt64 = 0

    var shouldMonitor: Bool {
        isDesired && !isSuspended
    }

    mutating func setDesired(_ enabled: Bool) {
        isDesired = enabled
    }

    @discardableResult
    mutating func activate() -> UInt64 {
        advanceGeneration()
        isSuspended = false
        return generation
    }

    @discardableResult
    mutating func suspend() -> UInt64 {
        advanceGeneration()
        isSuspended = true
        return generation
    }

    func isCurrent(_ candidate: UInt64) -> Bool {
        candidate != 0 && candidate == generation
    }

    @discardableResult
    mutating func resume(
        generation candidate: UInt64,
        expectedRadioId: String,
        selectedRadioId: String?,
        subscribedRadioId: String?
    ) -> Bool {
        guard isCurrent(candidate),
              selectedRadioId == expectedRadioId,
              subscribedRadioId == expectedRadioId else {
            return false
        }
        isSuspended = false
        return true
    }

    private mutating func advanceGeneration() {
        generation &+= 1
        if generation == 0 { generation = 1 }
    }
}

struct RadioLiteReceiveMonitoringOwnership: Equatable, Sendable {
    let radioId: String
    let generation: UInt64

    func isCurrent(selectedRadioId: String?, generation currentGeneration: UInt64) -> Bool {
        selectedRadioId == radioId && currentGeneration == generation
    }
}
