import AVFoundation
import Foundation
import XCTest
@testable import RadioLite

final class RadioLiteMicrophonePolicyTests: XCTestCase {
    func testRawDistanceModeIsTheDefaultAndKeepsVoiceProcessingOff() {
        let preferences = RadioLiteMicrophonePreferences.defaults
        let configuration = preferences.processingMode.configuration

        XCTAssertEqual(preferences.processingMode, .rawDistance)
        XCTAssertEqual(configuration.audioSessionMode, .measurement)
        XCTAssertFalse(configuration.voiceProcessingEnabled)
        XCTAssertEqual(preferences.gain, .plus12DB)
    }

    func testOptionalVoiceProcessedModeUsesVoiceChatProcessing() {
        let configuration = RadioLiteMicrophoneProcessingMode.voiceProcessed.configuration

        XCTAssertEqual(configuration.audioSessionMode, .voiceChat)
        XCTAssertTrue(configuration.voiceProcessingEnabled)
    }

    func testGainChoicesAreLimitedToTheFourApprovedSteps() {
        XCTAssertEqual(
            RadioLiteMicrophoneGain.allCases.map(\.decibels),
            [0, 6, 12, 18]
        )
        XCTAssertEqual(RadioLiteMicrophoneGain.zeroDB.linearAmplitudeMultiplier, 1, accuracy: 0.000_001)
        XCTAssertEqual(RadioLiteMicrophoneGain.plus6DB.linearAmplitudeMultiplier, 1.995_262, accuracy: 0.000_001)
        XCTAssertEqual(RadioLiteMicrophoneGain.plus12DB.linearAmplitudeMultiplier, 3.981_072, accuracy: 0.000_001)
        XCTAssertEqual(RadioLiteMicrophoneGain.plus18DB.linearAmplitudeMultiplier, 7.943_282, accuracy: 0.000_001)
    }

    func testSoftLimiterIsBoundedMonotonicAndSymmetric() {
        let positiveInputs: [Float] = [0, 0.25, 0.5, 1, 2]
        let positive = positiveInputs.map(RadioLiteMicrophoneDSP.softLimit)

        for (lower, upper) in zip(positive, positive.dropFirst()) {
            XCTAssertLessThan(lower, upper)
        }
        for (input, output) in zip(positiveInputs, positive) {
            XCTAssertEqual(
                RadioLiteMicrophoneDSP.softLimit(-input),
                -output,
                accuracy: 0.000_001
            )
        }
        XCTAssertLessThan(positive.last ?? 1, 1, "ordinary overloads must not hit a hard clip")
        XCTAssertLessThanOrEqual(abs(RadioLiteMicrophoneDSP.softLimit(100)), 1)
        XCTAssertLessThanOrEqual(abs(RadioLiteMicrophoneDSP.softLimit(-100)), 1)
    }

    func testSelectedGainIsAppliedBeforeTheSmoothLimiter() {
        let output = RadioLiteMicrophoneDSP.processSample(0.25, gain: .plus12DB)

        // tanh(0.25 * 10^(12/20))
        XCTAssertEqual(output, 0.759_600, accuracy: 0.000_001)
    }

    func testLevelTelemetryIsCalculatedFromPostGainPostLimiterSamples() throws {
        let result = RadioLiteMicrophoneDSP.processFrame(
            [0.25, -0.25],
            gain: .plus12DB
        )

        XCTAssertEqual(result.samples.count, 2)
        XCTAssertEqual(result.samples[0], 0.759_600, accuracy: 0.000_001)
        XCTAssertEqual(result.samples[1], -0.759_600, accuracy: 0.000_001)
        XCTAssertEqual(result.level, 0.759_600, accuracy: 0.000_001)
    }

    func testStatefulProcessorRaisesSustainedLowLevelSpeechAfterFixedGain() {
        var processor = RadioLiteMicrophoneProcessor()
        let voice = alternatingFrame(amplitude: 0.01)
        let first = processor.processFrame(voice, gain: .zeroDB)
        var settled = first

        for _ in 0..<30 {
            settled = processor.processFrame(voice, gain: .zeroDB)
        }

        XCTAssertEqual(settled.samples.count, 320, "processing must preserve one 20 ms Opus frame")
        XCTAssertGreaterThan(rms(settled.samples), rms(first.samples) * 1.7)
        XCTAssertLessThanOrEqual(rms(settled.samples), 0.0201, "adaptive gain must stay within about +6 dB")
    }

    func testStatefulProcessorDoesNotPumpSilenceOrNoiseFloor() {
        var processor = RadioLiteMicrophoneProcessor()
        let voice = alternatingFrame(amplitude: 0.01)
        for _ in 0..<30 {
            _ = processor.processFrame(voice, gain: .zeroDB)
        }

        let silence = processor.processFrame(Array(repeating: 0, count: 320), gain: .zeroDB)
        XCTAssertEqual(silence.samples, Array(repeating: 0, count: 320))

        let noise = alternatingFrame(amplitude: 0.002)
        var settledNoise = noise
        for _ in 0..<30 {
            let result = processor.processFrame(noise, gain: .zeroDB)
            settledNoise = result.samples
        }
        XCTAssertLessThanOrEqual(rms(settledNoise), 0.0021)
    }

    func testStatefulProcessorLearnsSteadyMediumNoiseInsteadOfCallingItSpeech() {
        var processor = RadioLiteMicrophoneProcessor()
        let noise = alternatingFrame(amplitude: 0.008)
        var settled = processor.processFrame(noise, gain: .zeroDB)

        for _ in 0..<40 {
            settled = processor.processFrame(noise, gain: .zeroDB)
        }

        XCTAssertLessThanOrEqual(rms(settled.samples), 0.0081)
    }

    func testStatefulProcessorKeepsGainThroughABriefLowEnergySyllable() {
        var processor = RadioLiteMicrophoneProcessor()
        let voice = alternatingFrame(amplitude: 0.01)
        for _ in 0..<30 {
            _ = processor.processFrame(voice, gain: .zeroDB)
        }

        let quietSyllable = processor.processFrame(
            alternatingFrame(amplitude: 0.004),
            gain: .zeroDB
        )
        let resumedVoice = processor.processFrame(voice, gain: .zeroDB)

        XCTAssertGreaterThan(rms(quietSyllable.samples), 0.006)
        XCTAssertGreaterThan(rms(resumedVoice.samples), 0.017)
    }

    func testStatefulProcessorKeepsBoostedPeaksSoftAndBounded() {
        var processor = RadioLiteMicrophoneProcessor()
        for _ in 0..<30 {
            _ = processor.processFrame(alternatingFrame(amplitude: 0.01), gain: .zeroDB)
        }

        let result = processor.processFrame([0.5, -0.5, 2, -2], gain: .zeroDB)

        XCTAssertTrue(result.samples.allSatisfy { abs($0) <= 1 })
        XCTAssertLessThan(result.samples.map { abs($0) }.max() ?? 1, 1, "finite overloads must not hard clip")
        XCTAssertEqual(result.samples[0], -result.samples[1], accuracy: 0.000_001)
        XCTAssertEqual(result.samples[2], -result.samples[3], accuracy: 0.000_001)
    }

    func testStatefulProcessorResetMatchesAFreshCaptureEpoch() {
        let voice = alternatingFrame(amplitude: 0.01)
        var processor = RadioLiteMicrophoneProcessor()
        for _ in 0..<30 {
            _ = processor.processFrame(voice, gain: .zeroDB)
        }
        let boosted = processor.processFrame(voice, gain: .zeroDB)

        processor.reset()
        let afterReset = processor.processFrame(voice, gain: .zeroDB)
        var fresh = RadioLiteMicrophoneProcessor()
        let freshFirst = fresh.processFrame(voice, gain: .zeroDB)

        XCTAssertEqual(afterReset, freshFirst)
        XCTAssertLessThan(rms(afterReset.samples), rms(boosted.samples) * 0.75)
    }

    func testPTTLocalReleaseInvalidatesCaptureAndUplinkSynchronously() {
        var captureState = RadioLiteCaptureEpochState()
        let capture = captureState.begin()
        XCTAssertTrue(captureState.activate(capture))

        var uplinkState = RadioLiteUplinkOwnershipState()
        let uplink = uplinkState.begin(transmitToken: "tx-token")
        XCTAssertTrue(uplinkState.complete(uplink))

        let captureResult = captureState.stop(epoch: capture.epoch)
        let uplinkResult = uplinkState.stop(
            transmitToken: uplink.transmitToken,
            epoch: uplink.epoch
        )

        XCTAssertEqual(captureResult, .stoppedActive)
        XCTAssertTrue(uplinkResult)
        XCTAssertFalse(captureState.isActive(capture))
        XCTAssertFalse(uplinkState.isBound(uplink))
    }

    private func alternatingFrame(amplitude: Float) -> [Float] {
        (0..<320).map { $0.isMultiple(of: 2) ? amplitude : -amplitude }
    }

    private func rms(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let meanSquare = samples.reduce(0.0) { partial, sample in
            partial + Double(sample * sample)
        } / Double(samples.count)
        return sqrt(meanSquare)
    }
}
