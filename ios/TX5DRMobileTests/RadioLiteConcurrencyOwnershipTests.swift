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
