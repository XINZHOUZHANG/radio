import XCTest
@testable import TX5DRMobile

final class FT8DecodedFeedStateTests: XCTestCase {
    func testFrozenFeedKeepsSelectableSnapshotUntilLiveModeResumes() {
        let first = frame(message: "CQ BG2TEST PN35", frequency: 769)
        let replacement = frame(message: "CQ JA1ABC PM95", frequency: 1_842)
        var feed = FT8DecodedFeedState()

        XCTAssertEqual(feed.displayedFrames(live: [first]), [first])

        feed.freeze(live: [first])
        XCTAssertTrue(feed.isFrozen)
        XCTAssertEqual(feed.displayedFrames(live: [replacement]), [first])

        feed.resume()
        XCTAssertFalse(feed.isFrozen)
        XCTAssertEqual(feed.displayedFrames(live: [replacement]), [replacement])
    }

    func testClearEmptiesFrozenSnapshotWithoutResumingUpdates() {
        let first = frame(message: "CQ BG2TEST PN35", frequency: 769)
        let replacement = frame(message: "CQ JA1ABC PM95", frequency: 1_842)
        var feed = FT8DecodedFeedState()

        feed.freeze(live: [first])
        feed.clear()

        XCTAssertTrue(feed.isFrozen)
        XCTAssertEqual(feed.displayedFrames(live: [replacement]), [])
    }

    private func frame(message: String, frequency: Double) -> FrameMessage {
        FrameMessage(
            snr: -10,
            freq: frequency,
            dt: 0.1,
            message: message,
            confidence: 0.95,
            operatorId: "operator-1"
        )
    }
}
