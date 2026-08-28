import XCTest
@testable import RadioLite

final class RadioLiteMediaLivenessTests: XCTestCase {
    func testHalfOpenSubscribedChannelFailsAfterTwoMissedHeartbeats() {
        var liveness = RadioLiteMediaLivenessState(connectedAt: 100)
        liveness.subscriptionStarted(at: 100)

        XCTAssertNil(liveness.failure(at: 129.9, monitoringAudio: false))
        XCTAssertEqual(
            liveness.failure(at: 130, monitoringAudio: false),
            .channelStalled
        )
    }

    func testAnyInboundFrameKeepsTheChannelAlive() {
        var liveness = RadioLiteMediaLivenessState(connectedAt: 100)
        liveness.subscriptionStarted(at: 100)
        liveness.receivedInbound(at: 125)

        XCTAssertNil(liveness.failure(at: 150, monitoringAudio: false))
    }

    func testAudioStallIsDetectedEvenWhileSpectrumFramesContinue() {
        var liveness = RadioLiteMediaLivenessState(connectedAt: 100)
        liveness.subscriptionStarted(at: 100)
        liveness.receivedAudio(at: 101)
        liveness.receivedInbound(at: 108)

        XCTAssertEqual(
            liveness.failure(at: 109, monitoringAudio: true),
            .audioStalled
        )
    }

    func testAudioStallIsIgnoredWhenTheUserDisabledMonitoring() {
        var liveness = RadioLiteMediaLivenessState(connectedAt: 100)
        liveness.subscriptionStarted(at: 100)
        liveness.receivedInbound(at: 108)

        XCTAssertNil(liveness.failure(at: 109, monitoringAudio: false))
    }

    func testFreshAudioClearsBothAudioAndChannelStalls() {
        var liveness = RadioLiteMediaLivenessState(connectedAt: 100)
        liveness.subscriptionStarted(at: 100)
        liveness.receivedAudio(at: 128)

        XCTAssertNil(liveness.failure(at: 130, monitoringAudio: true))
    }

    func testRestartingMonitoringGetsAFreshAudioGracePeriod() {
        var liveness = RadioLiteMediaLivenessState(connectedAt: 100)
        liveness.subscriptionStarted(at: 100)
        liveness.receivedAudio(at: 101)

        liveness.receivedInbound(at: 200)
        liveness.monitoringStarted(at: 200)

        XCTAssertNil(liveness.failure(at: 207.9, monitoringAudio: true))
        XCTAssertEqual(liveness.failure(at: 208, monitoringAudio: true), .audioStalled)
    }
}
