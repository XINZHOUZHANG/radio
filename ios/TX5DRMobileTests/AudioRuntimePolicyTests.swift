import Foundation
import XCTest
@testable import TX5DRMobile

final class AudioRuntimePolicyTests: XCTestCase {
    func testMediaSubscriptionDoesNotStartSpeakerPlaybackAutomatically() {
        XCTAssertFalse(AudioRuntimePolicy.startsMonitoringOnMediaSubscription)
    }

    func testStoppingPTTReleasesRecordingWhilePreservingOptionalPlayback() {
        XCTAssertEqual(
            AudioRuntimePolicy.intent(isCapturingMicrophone: true, isListening: true),
            .playAndRecord
        )
        XCTAssertEqual(
            AudioRuntimePolicy.intent(isCapturingMicrophone: false, isListening: true),
            .playback
        )
        XCTAssertEqual(
            AudioRuntimePolicy.intent(isCapturingMicrophone: false, isListening: false),
            .inactive
        )
    }

    func testTelemetryLimiterDoesNotRefreshSwiftUIForEveryAudioFrame() {
        var limiter = AudioTelemetryLimiter(minimumInterval: 0.1)

        XCTAssertTrue(limiter.shouldPublish(at: 10))
        XCTAssertFalse(limiter.shouldPublish(at: 10.02))
        XCTAssertFalse(limiter.shouldPublish(at: 10.099))
        XCTAssertTrue(limiter.shouldPublish(at: 10.1))
    }

    func testCannotStartRecordingHasActionableDiagnostic() {
        let error = NSError(domain: NSOSStatusErrorDomain, code: 561_145_187)
        let diagnostic = RadioLiteAudioEngine.diagnostic(error)

        XCTAssertTrue(diagnostic.contains("录音通道"))
        XCTAssertTrue(diagnostic.contains("麦克风权限"))
    }
}
