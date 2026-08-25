import AVFoundation
import Foundation

struct RadioLiteMicrophoneRuntimeConfiguration: Equatable {
    let audioSessionMode: AVAudioSession.Mode
    let voiceProcessingEnabled: Bool
}

enum RadioLiteMicrophoneProcessingMode: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case rawDistance
    case voiceProcessed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rawDistance: "远距原声"
        case .voiceProcessed: "人声处理"
        }
    }

    var detail: String {
        switch self {
        case .rawDistance: "Measurement 模式，关闭系统语音降噪与自动增益，适合远距拾音。"
        case .voiceProcessed: "Voice Chat 模式，启用系统回声消除、语音降噪与自动增益。"
        }
    }

    var configuration: RadioLiteMicrophoneRuntimeConfiguration {
        switch self {
        case .rawDistance:
            RadioLiteMicrophoneRuntimeConfiguration(
                audioSessionMode: .measurement,
                voiceProcessingEnabled: false
            )
        case .voiceProcessed:
            RadioLiteMicrophoneRuntimeConfiguration(
                audioSessionMode: .voiceChat,
                voiceProcessingEnabled: true
            )
        }
    }
}

enum RadioLiteMicrophoneGain: Int, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case zeroDB = 0
    case plus6DB = 6
    case plus12DB = 12
    case plus18DB = 18

    var id: Int { rawValue }
    var decibels: Int { rawValue }
    var label: String { rawValue == 0 ? "0 dB" : "+\(rawValue) dB" }

    var linearAmplitudeMultiplier: Float {
        Float(pow(10, Double(decibels) / 20))
    }
}

struct RadioLiteMicrophonePreferences: Codable, Equatable, Sendable {
    let processingMode: RadioLiteMicrophoneProcessingMode
    let gain: RadioLiteMicrophoneGain

    static let defaults = Self(processingMode: .rawDistance, gain: .plus12DB)

    private static let processingModeKey = "radio-lite.microphone.processing-mode"
    private static let gainKey = "radio-lite.microphone.gain-db"

    static func load(from defaults: UserDefaults = .standard) -> Self {
        let processingMode = defaults.string(forKey: processingModeKey)
            .flatMap(RadioLiteMicrophoneProcessingMode.init(rawValue:))
            ?? Self.defaults.processingMode
        let gain = (defaults.object(forKey: gainKey) as? NSNumber)
            .flatMap { RadioLiteMicrophoneGain(rawValue: $0.intValue) }
            ?? Self.defaults.gain
        return Self(processingMode: processingMode, gain: gain)
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(processingMode.rawValue, forKey: Self.processingModeKey)
        defaults.set(gain.rawValue, forKey: Self.gainKey)
    }
}

struct RadioLiteProcessedMicrophoneFrame: Equatable, Sendable {
    let samples: [Float]
    let level: Double
}

enum RadioLiteMicrophoneDSP {
    static func softLimit(_ sample: Float) -> Float {
        guard sample.isFinite else {
            if sample.isNaN { return 0 }
            return sample.sign == .minus ? -1 : 1
        }
        return Float(tanh(Double(sample)))
    }

    static func processSample(_ sample: Float, gain: RadioLiteMicrophoneGain) -> Float {
        softLimit(sample * gain.linearAmplitudeMultiplier)
    }

    static func processFrame(
        _ samples: [Float],
        gain: RadioLiteMicrophoneGain
    ) -> RadioLiteProcessedMicrophoneFrame {
        guard !samples.isEmpty else {
            return RadioLiteProcessedMicrophoneFrame(samples: [], level: 0)
        }
        let processed = samples.map { processSample($0, gain: gain) }
        let meanSquare = processed.reduce(0.0) { partial, sample in
            partial + Double(sample * sample)
        } / Double(processed.count)
        return RadioLiteProcessedMicrophoneFrame(
            samples: processed,
            level: min(1, sqrt(meanSquare))
        )
    }
}
