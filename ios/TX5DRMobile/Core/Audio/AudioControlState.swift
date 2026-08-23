import Foundation

enum AudioMonitorMuteReason: Equatable, Sendable {
    case transmitting
    case squelchClosed

    var label: String {
        switch self {
        case .transmitting: "发射期间监听自动静音"
        case .squelchClosed: "电台静噪门关闭，监听自动静音"
        }
    }
}

struct AudioMonitorGateState: Equatable, Sendable {
    let muteReason: AudioMonitorMuteReason?

    init(
        engineMode: String,
        ptt: PTTStatus,
        localVoicePTTHeld: Bool,
        squelch: SquelchStatus,
        voiceLock: JSONValue?
    ) {
        let voiceMode = engineMode.uppercased() == "VOICE"
        let voiceKeyerIsTransmitting = voiceLock?["locked"]?.boolValue == true
            && voiceLock?["lockedBy"]?.stringValue?.hasPrefix("voice-keyer:") == true

        if voiceMode && !voiceKeyerIsTransmitting && (ptt.isTransmitting || localVoicePTTHeld) {
            muteReason = .transmitting
        } else if voiceMode && squelch.supported && squelch.open == false {
            muteReason = .squelchClosed
        } else {
            muteReason = nil
        }
    }

    var shouldMute: Bool { muteReason != nil }
}

enum AudioGain {
    static let minimumDecibels = -60.0
    static let maximumDecibels = 20.0

    static func clampedDecibels(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(maximumDecibels, max(minimumDecibels, value))
    }

    static func decibels(from payload: JSONValue?) -> Double? {
        guard let payload else { return nil }

        if let gainDb = payload["gainDb"]?.doubleValue ?? payload["volumeGainDb"]?.doubleValue {
            guard gainDb.isFinite else { return nil }
            return clampedDecibels(gainDb)
        }

        if let gain = payload["gain"]?.doubleValue ?? payload["volumeGain"]?.doubleValue {
            return decibels(fromLinearGain: gain)
        }

        if let gain = payload.doubleValue {
            return decibels(fromLinearGain: gain)
        }

        return nil
    }

    static func decibels(fromLinearGain gain: Double) -> Double? {
        guard gain.isFinite, gain >= 0 else { return nil }
        return clampedDecibels(20 * log10(max(0.001, gain)))
    }
}
