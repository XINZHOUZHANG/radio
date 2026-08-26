import AVFoundation
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
}
