import AVFoundation
import Foundation
import XCTest
@testable import TX5DRMobile

final class AudioInterruptionPolicyTests: XCTestCase {
    private func interruption(_ type: AVAudioSession.InterruptionType) -> Notification {
        Notification(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: type.rawValue]
        )
    }

    private func routeChange(_ reason: AVAudioSession.RouteChangeReason) -> Notification {
        Notification(
            name: AVAudioSession.routeChangeNotification,
            object: nil,
            userInfo: [AVAudioSessionRouteChangeReasonKey: reason.rawValue]
        )
    }

    func testInterruptionBeginningStopsCaptureAndTransmit() {
        XCTAssertEqual(
            TX5DRAudioInterruptionPolicy.action(for: interruption(.began)),
            .stopCaptureAndTransmit
        )
    }

    /// An interruption ending must never put the station back on the air.
    func testInterruptionEndingNeverResumesTransmit() {
        XCTAssertEqual(
            TX5DRAudioInterruptionPolicy.action(for: interruption(.ended)),
            .ignore
        )
    }

    func testMediaServicesLostOrResetStopsCaptureAndTransmit() {
        for name in [
            AVAudioSession.mediaServicesWereLostNotification,
            AVAudioSession.mediaServicesWereResetNotification,
        ] {
            XCTAssertEqual(
                TX5DRAudioInterruptionPolicy.action(for: Notification(name: name, object: nil)),
                .stopCaptureAndTransmit,
                "\(name.rawValue) leaves the capture path invalid"
            )
        }
    }

    /// Unplugging the headset or losing a Bluetooth link kills the microphone
    /// while the rig may still be keyed, which puts an unmodulated carrier on
    /// the air.
    func testLosingTheCaptureDeviceStopsCaptureAndTransmit() {
        XCTAssertEqual(
            TX5DRAudioInterruptionPolicy.action(for: routeChange(.oldDeviceUnavailable)),
            .stopCaptureAndTransmit
        )
    }

    /// Other route reasons do not invalidate the capture path, so they must not
    /// drop a transmission the operator is holding.
    func testOtherRouteChangesDoNotDropTransmission() {
        for reason: AVAudioSession.RouteChangeReason in [
            .newDeviceAvailable,
            .categoryChange,
            .override,
            .wakeFromSleep,
            .routeConfigurationChange,
        ] {
            XCTAssertEqual(
                TX5DRAudioInterruptionPolicy.action(for: routeChange(reason)),
                .ignore,
                "route reason \(reason.rawValue) should not stop a held PTT"
            )
        }
    }

    func testUnrelatedNotificationIsIgnored() {
        XCTAssertEqual(
            TX5DRAudioInterruptionPolicy.action(
                for: Notification(name: Notification.Name("unrelated"), object: nil)
            ),
            .ignore
        )
    }

    func testMalformedUserInfoIsIgnoredRatherThanCrashing() {
        XCTAssertEqual(
            TX5DRAudioInterruptionPolicy.action(for: Notification(
                name: AVAudioSession.interruptionNotification,
                object: nil,
                userInfo: [AVAudioSessionInterruptionTypeKey: "not a number"]
            )),
            .ignore
        )
        XCTAssertEqual(
            TX5DRAudioInterruptionPolicy.action(
                for: Notification(name: AVAudioSession.interruptionNotification, object: nil)
            ),
            .ignore
        )
    }

    @MainActor
    func testObserverDeliversOneStopPerEpisodeAndRearms() {
        let center = NotificationCenter()
        var stopCount = 0
        var observer: TX5DRAudioInterruptionObserver? = TX5DRAudioInterruptionObserver(
            notificationCenter: center
        ) {
            stopCount += 1
        }
        XCTAssertNotNil(observer)

        center.post(interruption(.began))
        center.post(interruption(.began))
        center.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        XCTAssertEqual(stopCount, 1, "one interruption episode must not release PTT repeatedly")

        observer?.rearm()
        center.post(interruption(.began))
        XCTAssertEqual(stopCount, 2, "a new transmission must be protected again")

        observer = nil
        center.post(interruption(.began))
        XCTAssertEqual(stopCount, 2, "a released observer must not keep receiving")
    }
}
