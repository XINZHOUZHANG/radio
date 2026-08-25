import Foundation

enum AudioRuntimeIntent: Equatable {
    case inactive
    case playback
    case playAndRecord
}

enum AudioRuntimePolicy {
    /// A media subscription is also used for spectrum and FT8 audio. Speaker
    /// playback remains opt-in so login cannot fail because an iOS audio route
    /// is temporarily unavailable, and so opening the app does not consume
    /// power playing audio the operator did not request.
    static let startsMonitoringOnMediaSubscription = false

    static func intent(isCapturingMicrophone: Bool, isListening: Bool) -> AudioRuntimeIntent {
        if isCapturingMicrophone { return .playAndRecord }
        if isListening { return .playback }
        return .inactive
    }
}

struct AudioTelemetryLimiter {
    let minimumInterval: TimeInterval
    private var lastPublishedAt: TimeInterval?

    init(minimumInterval: TimeInterval) {
        self.minimumInterval = max(0, minimumInterval)
    }

    mutating func shouldPublish(at timestamp: TimeInterval) -> Bool {
        guard let lastPublishedAt else {
            self.lastPublishedAt = timestamp
            return true
        }
        guard timestamp < lastPublishedAt || timestamp >= lastPublishedAt + minimumInterval else {
            return false
        }
        self.lastPublishedAt = timestamp
        return true
    }

    mutating func reset() {
        lastPublishedAt = nil
    }
}
