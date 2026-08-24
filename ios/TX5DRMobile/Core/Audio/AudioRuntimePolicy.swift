import Foundation

enum AudioRuntimeIntent: Equatable {
    case inactive
    case playback
    case playAndRecord
}

enum AudioRuntimePolicy {
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
