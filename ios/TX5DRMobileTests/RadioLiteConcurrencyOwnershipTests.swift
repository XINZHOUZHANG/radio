import Foundation
import XCTest
@testable import TX5DRMobile

final class RadioLiteConcurrencyOwnershipTests: XCTestCase {
    func testInvalidatedOperationCannotOwnAReplacement() {
        var epoch = RadioLiteOperationEpoch()
        let old = epoch.begin()
        epoch.invalidate()
        let replacement = epoch.begin()

        XCTAssertFalse(epoch.owns(old))
        XCTAssertTrue(epoch.owns(replacement))
    }

    func testStoppedPendingReceiveAudioCannotRestartPlayback() {
        var transition = RadioLiteOperationEpoch()
        let pendingStart = transition.begin()

        transition.invalidate()
        XCTAssertFalse(
            transition.owns(pendingStart),
            "a subscription completing after Stop must not start monitoring"
        )

        let replacementStart = transition.begin()
        XCTAssertFalse(transition.owns(pendingStart))
        XCTAssertTrue(transition.owns(replacementStart))
    }

    func testStoppedPendingUplinkCannotRebindOrClearItsReplacement() {
        var state = RadioLiteUplinkOwnershipState()
        let old = state.begin(transmitToken: "old-token")
        XCTAssertTrue(state.stop(transmitToken: old.transmitToken, epoch: old.epoch))

        let replacement = state.begin(transmitToken: "new-token")
        XCTAssertFalse(state.complete(old), "a late bind response must stay cancelled")
        XCTAssertTrue(state.complete(replacement))
        XCTAssertFalse(state.stop(transmitToken: old.transmitToken, epoch: old.epoch))
        XCTAssertTrue(state.isBound(replacement), "old cleanup must not clear the replacement")
    }

    func testOldMediaSubscriptionCompletionCannotPublishOverItsReplacement() {
        var state = RadioLiteMediaSubscriptionOwnershipState()
        let main = state.begin(radioId: "main")
        let backup = state.begin(radioId: "backup")

        XCTAssertFalse(
            state.complete(main),
            "a delayed subscription response must be surfaced as cancellation, not success"
        )
        XCTAssertTrue(state.complete(backup))
        XCTAssertFalse(state.isCurrent(main))
        XCTAssertTrue(state.isCurrent(backup))
    }

    func testOldReconnectOwnerCannotClearItsReplacement() {
        var state = RadioLiteReconnectOwnershipState()
        let old = state.begin()
        let replacement = state.begin()

        XCTAssertFalse(state.complete(old), "a cancelled request finishing late must not clear reconnectTask")
        XCTAssertTrue(state.isCurrent(replacement))
        XCTAssertTrue(state.complete(replacement))
        XCTAssertFalse(state.isCurrent(replacement))
    }

    func testReconnectFailurePolicyTreatsSupersessionAsBenign() {
        XCTAssertEqual(
            RadioLiteReconnectFailurePolicy.disposition(
                for: CancellationError(),
                stage: .channelReconnect
            ),
            .benign
        )
        XCTAssertEqual(
            RadioLiteReconnectFailurePolicy.disposition(
                for: URLError(.timedOut),
                stage: .channelReconnect
            ),
            .retry
        )
        XCTAssertEqual(
            RadioLiteReconnectFailurePolicy.disposition(
                for: URLError(.timedOut),
                stage: .credentialRefresh
            ),
            .retry
        )
        XCTAssertEqual(
            RadioLiteReconnectFailurePolicy.disposition(
                for: RadioLiteHTTPError.http(
                    status: 401,
                    code: "refresh_expired",
                    message: "expired"
                ),
                stage: .credentialRefresh
            ),
            .signOut
        )
    }

    func testPTTSubscriptionTransfersMonitoringRestorationUntilRelease() {
        var intent = RadioLiteReceiveMonitoringIntent()
        intent.setDesired(true)
        let monitoring = RadioLiteReceiveMonitoringOwnership(
            radioId: "main",
            generation: intent.suspend()
        )
        var transfers = RadioLiteVoicePTTReceiveRestoreState()

        transfers.assign(monitoring, transmitGeneration: 11)
        XCTAssertFalse(intent.shouldMonitor, "PTT must not resume the speaker while transmit is held")

        let released = transfers.take(transmitGeneration: 11)
        XCTAssertEqual(released, monitoring)
        XCTAssertTrue(intent.resume(
            generation: released?.generation ?? 0,
            expectedRadioId: "main",
            selectedRadioId: "main",
            subscribedRadioId: "main"
        ))
        XCTAssertTrue(intent.shouldMonitor, "releasing PTT must restore the user's receive-audio choice")
    }

    func testOldPTTCleanupCannotConsumeReplacementMonitoringTransfer() {
        var transfers = RadioLiteVoicePTTReceiveRestoreState()
        let old = RadioLiteReceiveMonitoringOwnership(radioId: "main", generation: 3)
        let replacement = RadioLiteReceiveMonitoringOwnership(radioId: "main", generation: 4)
        transfers.assign(old, transmitGeneration: 20)
        transfers.assign(replacement, transmitGeneration: 21)

        XCTAssertNil(transfers.take(transmitGeneration: 20))
        XCTAssertEqual(transfers.take(transmitGeneration: 21), replacement)
    }

    func testPTTStopReasonRestoresReceiveExceptDuringConnectionLoss() {
        XCTAssertTrue(RadioLiteVoicePTTStopReason.userRelease.restoresReceiveMonitoring)
        XCTAssertTrue(RadioLiteVoicePTTStopReason.transmitFailure.restoresReceiveMonitoring)
        XCTAssertFalse(
            RadioLiteVoicePTTStopReason.connectionLoss.restoresReceiveMonitoring,
            "connection recovery owns a newer monitoring suspension"
        )
    }

    func testOldConfigurationReconnectCannotPublishControlForNewRadio() {
        var state = RadioLiteRadioConfigurationReconnectOwnershipState()
        let old = state.begin(radioId: "main")
        let replacement = state.begin(radioId: "backup")

        XCTAssertFalse(state.isCurrent(old, selectedRadioId: "backup"))
        XCTAssertTrue(state.isCurrent(replacement, selectedRadioId: "backup"))
        XCTAssertFalse(state.complete(old, selectedRadioId: "backup"))
        XCTAssertTrue(state.isCurrent(replacement, selectedRadioId: "backup"))
    }

    func testPermissionResultCannotActivateCaptureAfterStop() {
        var state = RadioLiteCaptureEpochState()
        let pending = state.begin()

        XCTAssertEqual(state.stop(epoch: pending.epoch), .invalidatedPending)
        XCTAssertFalse(state.activate(pending), "permission completion after release must not start capture")
        XCTAssertEqual(state.stop(epoch: pending.epoch), .notOwner, "repeat stop must be side-effect free")
    }

    func testOldCaptureStopCannotStopAReplacement() {
        var state = RadioLiteCaptureEpochState()
        let old = state.begin()
        XCTAssertTrue(state.activate(old))
        XCTAssertEqual(state.stop(epoch: old.epoch), .stoppedActive)

        let replacement = state.begin()
        XCTAssertTrue(state.activate(replacement))
        XCTAssertEqual(state.stop(epoch: old.epoch), .notOwner)
        XCTAssertFalse(state.isActive(old), "queued callbacks from the old tap must be discarded")
        XCTAssertTrue(state.isActive(replacement))
    }

    func testOneAsyncMediaFailureHasExactlyOnePresentationOwner() {
        XCTAssertEqual(
            RadioLiteMediaFailurePresentation.route(
                wasUplinkBound: true,
                reconnectRequired: true
            ),
            .reconnectBanner
        )
        XCTAssertEqual(
            RadioLiteMediaFailurePresentation.route(
                wasUplinkBound: true,
                reconnectRequired: false
            ),
            .uplinkBanner
        )
        XCTAssertEqual(
            RadioLiteMediaFailurePresentation.route(
                wasUplinkBound: false,
                reconnectRequired: false
            ),
            .none
        )
    }
}
