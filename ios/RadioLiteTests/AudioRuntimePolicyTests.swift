import AVFoundation
import Foundation
import SwiftUI
import XCTest
@testable import RadioLite

final class AudioRuntimePolicyTests: XCTestCase {
    func testInactiveSceneDoesNotRunBackgroundRadioCleanup() {
        XCTAssertEqual(RadioLiteScenePhasePolicy.action(for: .inactive), .none)
        XCTAssertEqual(RadioLiteScenePhasePolicy.action(for: .active), .becameActive)
        XCTAssertEqual(RadioLiteScenePhasePolicy.action(for: .background), .enteredBackground)
    }

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

    func testBackgroundKeepsReceiveAudioWhenTheOperatorIsListening() {
        let decision = AudioRuntimePolicy.backgroundDecision(receiveAudioDesired: true)

        XCTAssertTrue(decision.keepsReceiving)
        XCTAssertFalse(decision.suspendsReceiveAudio)
        XCTAssertFalse(decision.cancelsReceiveRecovery)
    }

    func testBackgroundSuspendsReceiveAudioWhenTheOperatorIsNotListening() {
        let decision = AudioRuntimePolicy.backgroundDecision(receiveAudioDesired: false)

        XCTAssertFalse(decision.keepsReceiving)
        XCTAssertTrue(decision.suspendsReceiveAudio)
        XCTAssertTrue(decision.cancelsReceiveRecovery)
    }

    func testBackgroundPTTReleaseMayRecoverReceiveAudio() {
        XCTAssertTrue(
            AudioRuntimePolicy.allowsReceiveRecovery(
                isAppActive: false,
                keepsReceivingInBackground: true
            )
        )
        XCTAssertFalse(
            AudioRuntimePolicy.allowsReceiveRecovery(
                isAppActive: false,
                keepsReceivingInBackground: false
            )
        )
    }

    func testBackgroundAlwaysHidesSpectrum() {
        XCTAssertFalse(
            AudioRuntimePolicy.backgroundDecision(receiveAudioDesired: true).spectrumVisible
        )
        XCTAssertFalse(
            AudioRuntimePolicy.backgroundDecision(receiveAudioDesired: false).spectrumVisible
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

    func testAudioInterruptionEndingRequestsReceiveOnlyRecovery() {
        let notification = Notification(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
            ]
        )

        XCTAssertEqual(
            RadioLiteAudioInterruptionPolicy.action(for: notification),
            .resumeReceiveOnly
        )
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

    func testRelevantAudioRouteChangesRequestReconfiguration() {
        let cases: [(AVAudioSession.RouteChangeReason, RadioLiteAudioRouteChangeKind)] = [
            (.oldDeviceUnavailable, .oldDeviceUnavailable),
            (.newDeviceAvailable, .newDeviceAvailable),
            (.categoryChange, .categoryChange),
        ]
        for (reason, expected) in cases {
            XCTAssertEqual(
                RadioLiteAudioInterruptionPolicy.action(for: Notification(
                    name: AVAudioSession.routeChangeNotification,
                    object: nil,
                    userInfo: [AVAudioSessionRouteChangeReasonKey: reason.rawValue]
                )),
                .reconfigureAudio(.route(expected))
            )
        }
    }

    func testAudioEngineConfigurationChangeRequestsReconfiguration() {
        XCTAssertEqual(
            RadioLiteAudioInterruptionPolicy.action(for: Notification(
                name: .AVAudioEngineConfigurationChange,
                object: nil
            )),
            .reconfigureAudio(.engine)
        )
    }

    @MainActor
    func testAudioReconfigurationRearmMergesCompanionNotificationUntilCooldownExpires() {
        let center = NotificationCenter()
        var uptime: TimeInterval = 100
        var reconfigurationCount = 0
        let observer = RadioLiteAudioInterruptionObserver(
            notificationCenter: center,
            monotonicTime: { uptime }
        ) {
            XCTFail("Route and engine changes must not use the interruption stop callback")
        } onMediaServicesReset: {
            XCTFail("Route and engine changes must not reset media services")
        } onAudioReconfiguration: { _ in
            reconfigurationCount += 1
            return true
        } onReceiveMayResume: {
            XCTFail("The observer delegates receive recovery to audio reconfiguration handling")
        }

        center.post(
            name: AVAudioSession.routeChangeNotification,
            object: nil,
            userInfo: [
                AVAudioSessionRouteChangeReasonKey:
                    AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue,
            ]
        )
        XCTAssertEqual(reconfigurationCount, 1)

        observer.rearm()
        center.post(name: .AVAudioEngineConfigurationChange, object: nil)
        XCTAssertEqual(
            reconfigurationCount,
            1,
            "rearming receive monitoring must not split one physical audio-change episode"
        )

        uptime += 0.25
        center.post(name: .AVAudioEngineConfigurationChange, object: nil)
        XCTAssertEqual(
            reconfigurationCount,
            2,
            "a later audio change must be allowed after the short cooldown"
        )
    }

    func testUnrelatedAudioNotificationIsIgnored() {
        XCTAssertEqual(
            RadioLiteAudioInterruptionPolicy.action(for: Notification(
                name: Notification.Name("RadioLiteTests.unrelated-audio-notification"),
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
        var receiveResumeCount = 0
        var observer: RadioLiteAudioInterruptionObserver? = RadioLiteAudioInterruptionObserver(
            notificationCenter: center
        ) {
            stopCount += 1
        } onMediaServicesReset: {
            resetCount += 1
        } onAudioReconfiguration: {
            _ in true
        } onReceiveMayResume: {
            receiveResumeCount += 1
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
        XCTAssertEqual(
            receiveResumeCount,
            3,
            "every media-services reset and a later interruption end may resume receive only"
        )

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
        XCTAssertEqual(receiveResumeCount, 4, "deinitialized observers must not resume receive audio")
    }

    func testPlaybackQueueFlushRejectsCompletionsFromTheOldGeneration() throws {
        var queue = RadioLitePlaybackQueueState(targetBuffers: 3, maximumBuffers: 25)
        let oldGeneration = try XCTUnwrap(queue.enqueue())

        queue.flush()
        let replacementGeneration = try XCTUnwrap(queue.enqueue())
        queue.complete(generation: oldGeneration)

        XCTAssertEqual(queue.scheduledBuffers, 1)
        queue.complete(generation: replacementGeneration)
        XCTAssertEqual(queue.scheduledBuffers, 0)
    }

    func testFullStoppedPlaybackQueueRequestsRecoveryInsteadOfLatchingClosed() {
        var queue = RadioLitePlaybackQueueState(targetBuffers: 3, maximumBuffers: 25)
        for _ in 0..<25 {
            XCTAssertNotNil(queue.enqueue())
        }

        XCTAssertNil(queue.enqueue())
        XCTAssertTrue(queue.requiresRecovery(engineRunning: false, playerPlaying: false))

        queue.flush()
        XCTAssertNotNil(queue.enqueue(), "a recovered queue must accept the next live packet")
    }

    func testHealthyFullPlaybackQueueUsesBackpressureWithoutResettingPlayback() {
        var queue = RadioLitePlaybackQueueState(targetBuffers: 3, maximumBuffers: 25)
        for _ in 0..<25 { _ = queue.enqueue() }

        XCTAssertFalse(queue.requiresRecovery(engineRunning: true, playerPlaying: true))
        XCTAssertNil(queue.enqueue())
        XCTAssertEqual(queue.scheduledBuffers, 25)
    }

    func testLocalPTTReleaseResumesPlaybackWithoutWaitingForRemoteStopDispatch() {
        var gate = RadioLitePlaybackSuspensionState()

        gate.captureStarted()
        gate.captureStopped(resumeImmediately: false)
        XCTAssertTrue(gate.isSuspended)

        gate.resumeAfterLocalTransmitRelease()
        XCTAssertFalse(gate.isSuspended)
    }

    func testOrdinaryCaptureCleanupCanResumePlaybackImmediately() {
        var gate = RadioLitePlaybackSuspensionState()

        gate.captureStarted()
        gate.captureStopped(resumeImmediately: true)

        XCTAssertFalse(gate.isSuspended)
    }

    func testRestartingMonitoringClearsAStalePlaybackSuspension() {
        var gate = RadioLitePlaybackSuspensionState()

        gate.captureStarted()
        gate.captureStopped(resumeImmediately: false)
        gate.monitoringStarted()

        XCTAssertFalse(gate.isSuspended)
    }
}
