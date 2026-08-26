import AVFoundation
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

    func testAudioInterruptionBeginningStopsCaptureAndTransmit() {
        let notification = Notification(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue,
            ]
        )

        XCTAssertEqual(
            RadioLiteAudioInterruptionPolicy.action(for: notification),
            .stopCaptureAndTransmit
        )
    }

    func testAudioInterruptionEndingNeverRestartsTransmit() {
        let notification = Notification(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
            ]
        )

        XCTAssertEqual(RadioLiteAudioInterruptionPolicy.action(for: notification), .ignore)
    }

    func testMediaServicesResetStopsCaptureAndTransmit() {
        XCTAssertEqual(
            RadioLiteAudioInterruptionPolicy.action(for: Notification(
                name: AVAudioSession.mediaServicesWereResetNotification,
                object: nil
            )),
            .stopCaptureAndTransmit
        )
    }

    func testMediaServicesLostStopsCaptureAndTransmitImmediately() {
        XCTAssertEqual(
            RadioLiteAudioInterruptionPolicy.action(for: Notification(
                name: AVAudioSession.mediaServicesWereLostNotification,
                object: nil
            )),
            .stopCaptureAndTransmit
        )
    }

    func testUnrelatedAudioNotificationIsIgnored() {
        XCTAssertEqual(
            RadioLiteAudioInterruptionPolicy.action(for: Notification(
                name: AVAudioSession.routeChangeNotification,
                object: nil
            )),
            .ignore
        )
    }

    @MainActor
    func testAudioInterruptionObserverDeduplicatesRearmsAndDetachesOnDeinit() {
        let center = NotificationCenter()
        var stopCount = 0
        var resetCount = 0
        var observer: RadioLiteAudioInterruptionObserver? = RadioLiteAudioInterruptionObserver(
            notificationCenter: center
        ) {
            stopCount += 1
        } onMediaServicesReset: {
            resetCount += 1
        }
        weak var weakObserver = observer

        let began = Notification(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue,
            ]
        )
        center.post(name: AVAudioSession.mediaServicesWereLostNotification, object: nil)
        center.post(began)
        center.post(began)
        center.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        center.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        XCTAssertEqual(stopCount, 1, "one interruption episode must request one fail-safe stop")
        XCTAssertEqual(
            resetCount,
            2,
            "every reset must rebuild even when no ended or rearm notification occurs between them"
        )

        center.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
            ]
        )
        XCTAssertEqual(stopCount, 1, "interruption ended must never restart or stop PTT again")

        center.post(began)
        XCTAssertEqual(stopCount, 2, "a later interruption episode must still be handled")

        observer?.rearm()
        center.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        XCTAssertEqual(stopCount, 3, "a new PTT attempt must rearm reset handling")
        XCTAssertEqual(resetCount, 3)

        observer = nil
        XCTAssertNil(weakObserver, "NotificationCenter must not retain the observer owner")
        center.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
            ]
        )
        center.post(began)
        XCTAssertEqual(stopCount, 3, "deinitialized observers must stop receiving notifications")
        XCTAssertEqual(resetCount, 3, "deinitialized observers must not rebuild audio resources")
    }
}
