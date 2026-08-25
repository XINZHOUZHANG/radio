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
