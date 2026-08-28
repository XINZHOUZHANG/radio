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

struct RadioLiteMicrophoneProcessor: Equatable, Sendable {
    private static let initialNoiseFloorRMS: Float = 0.002
    private static let minimumNoiseFloorRMS: Float = 0.0005
    private static let maximumNoiseFloorRMS: Float = 0.02
    private static let minimumSpeechRMS: Float = 0.009
    private static let minimumSpeechToNoiseRatio: Float = 3
    private static let targetSpeechRMS: Float = 0.08
    private static let maximumAdaptiveGain: Float = 1.995_262
    private static let speechFramesBeforeBoost = 3
    private static let speechHangoverFrames = 10
    private static let gainAttack: Float = 0.18
    private static let gainRelease: Float = 0.12

    private var noiseFloorRMS = RadioLiteMicrophoneProcessor.initialNoiseFloorRMS
    private var adaptiveGain: Float = 1
    private var consecutiveSpeechFrames = 0
    private var speechHangoverFramesRemaining = 0

    init() {}

    mutating func reset() {
        self = Self()
    }

    mutating func processFrame(
        _ samples: [Float],
        gain: RadioLiteMicrophoneGain
    ) -> RadioLiteProcessedMicrophoneFrame {
        guard !samples.isEmpty else {
            return RadioLiteProcessedMicrophoneFrame(samples: [], level: 0)
        }

        let inputRMS = Self.rootMeanSquare(samples)
        let speechThreshold = max(
            Self.minimumSpeechRMS,
            noiseFloorRMS * Self.minimumSpeechToNoiseRatio
        )
        let isSpeechCandidate = inputRMS >= speechThreshold
        if isSpeechCandidate {
            if consecutiveSpeechFrames < Self.speechFramesBeforeBoost {
                consecutiveSpeechFrames += 1
            }
            if consecutiveSpeechFrames >= Self.speechFramesBeforeBoost {
                speechHangoverFramesRemaining = Self.speechHangoverFrames
            }
        } else {
            consecutiveSpeechFrames = 0
            if speechHangoverFramesRemaining > 0 {
                speechHangoverFramesRemaining -= 1
            } else {
                updateNoiseFloor(with: inputRMS)
            }
        }

        let isConfirmedSpeech = consecutiveSpeechFrames >= Self.speechFramesBeforeBoost
        let isSpeechActive = isConfirmedSpeech || speechHangoverFramesRemaining > 0
        let frameAdaptiveGain = isSpeechActive ? adaptiveGain : 1
        let combinedGain = gain.linearAmplitudeMultiplier * frameAdaptiveGain
        let processed = samples.map { RadioLiteMicrophoneDSP.softLimit($0 * combinedGain) }

        if isConfirmedSpeech {
            let postUserGainRMS = inputRMS * gain.linearAmplitudeMultiplier
            let targetGain = postUserGainRMS > 0
                ? min(
                    Self.maximumAdaptiveGain,
                    max(1, Self.targetSpeechRMS / postUserGainRMS)
                )
                : 1
            adaptiveGain += (targetGain - adaptiveGain) * Self.gainAttack
        } else if isSpeechActive {
            adaptiveGain += (1 - adaptiveGain) * Self.gainRelease
        } else {
            adaptiveGain = 1
        }
        adaptiveGain = min(Self.maximumAdaptiveGain, max(1, adaptiveGain))

        return RadioLiteProcessedMicrophoneFrame(
            samples: processed,
            level: min(1, Double(Self.rootMeanSquare(processed)))
        )
    }

    private mutating func updateNoiseFloor(with inputRMS: Float) {
        let observation = min(
            Self.maximumNoiseFloorRMS,
            max(Self.minimumNoiseFloorRMS, inputRMS)
        )
        let smoothing: Float = observation < noiseFloorRMS ? 0.2 : 0.025
        noiseFloorRMS += (observation - noiseFloorRMS) * smoothing
    }

    private static func rootMeanSquare(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let meanSquare = samples.reduce(0.0) { partial, sample in
            let magnitude: Double
            if sample.isNaN {
                magnitude = 0
            } else if sample.isFinite {
                magnitude = min(1, abs(Double(sample)))
            } else {
                magnitude = 1
            }
            return partial + magnitude * magnitude
        } / Double(samples.count)
        return Float(sqrt(meanSquare))
    }
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
