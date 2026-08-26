import XCTest
@testable import TX5DRMobile

final class RadioLiteDecodeFeedStateTests: XCTestCase {
    func testIncomingBatchReplacesLiveFeedButKeepsSelectedBatchFrozenUntilResume() {
        let first = batch(
            mode: "FT8",
            slotStartMs: 15_000,
            decodes: [decode(id: "first-cq", message: "CQ JA1ABC PM95")]
        )
        let second = batch(
            mode: "FT8",
            slotStartMs: 30_000,
            decodes: [decode(id: "second-cq", message: "CQ BG2TEST PN35")]
        )
        var feed = RadioLiteDecodeFeedState(mode: "FT8")

        feed.receive(first)
        XCTAssertEqual(feed.displayedBatch, first)

        feed.select(decodeId: "first-cq")
        feed.receive(second)

        XCTAssertEqual(feed.displayedBatch, first)
        XCTAssertEqual(feed.selectedDecode?.id, "first-cq")

        feed.resume()

        XCTAssertNil(feed.selectedDecodeId)
        XCTAssertEqual(feed.displayedBatch, second)
    }

    func testEnablingCQFilterClearsHiddenSelectionAndReturnsToLatestBatch() {
        let selectedBatch = batch(
            mode: "FT8",
            slotStartMs: 15_000,
            decodes: [
                decode(id: "directed", message: "JA1ABC BG2TEST -10"),
                decode(id: "old-cq", message: "CQ K1ABC FN42"),
            ]
        )
        let latestBatch = batch(
            mode: "FT8",
            slotStartMs: 30_000,
            decodes: [decode(id: "latest-cq", message: "CQ VK3ABC QF22")]
        )
        var feed = RadioLiteDecodeFeedState(mode: "FT8", cqOnly: false)

        feed.receive(selectedBatch)
        feed.select(decodeId: "directed")
        feed.receive(latestBatch)
        feed.setCQOnly(true)

        XCTAssertNil(feed.selectedDecodeId)
        XCTAssertNil(feed.selectedDecode)
        XCTAssertEqual(feed.displayedBatch, latestBatch)
        XCTAssertEqual(feed.filteredDecodes.map(\.id), ["latest-cq"])
    }

    func testEnablingCQFilterKeepsVisibleCQSelectionFrozen() {
        let first = batch(
            mode: "FT8",
            slotStartMs: 15_000,
            decodes: [decode(id: "selected-cq", message: "CQ JA1ABC PM95")]
        )
        let second = batch(
            mode: "FT8",
            slotStartMs: 30_000,
            decodes: [decode(id: "next-cq", message: "CQ BG2TEST PN35")]
        )
        var feed = RadioLiteDecodeFeedState(mode: "FT8", cqOnly: false)

        feed.receive(first)
        feed.select(decodeId: "selected-cq")
        feed.receive(second)
        feed.setCQOnly(true)

        XCTAssertEqual(feed.selectedDecode?.id, "selected-cq")
        XCTAssertEqual(feed.displayedBatch, first)
        XCTAssertEqual(feed.filteredDecodes.map(\.id), ["selected-cq"])
    }

    func testChangingModeClearsSelectionAndDisplaysThatModesLatestBatch() {
        let ft8 = batch(
            mode: "FT8",
            slotStartMs: 15_000,
            decodes: [decode(id: "ft8", message: "CQ JA1ABC PM95")]
        )
        let ft4 = batch(
            mode: "FT4",
            slotStartMs: 22_500,
            decodes: [decode(id: "ft4", message: "CQ BG2TEST PN35")]
        )
        var feed = RadioLiteDecodeFeedState(mode: "FT8")

        feed.receive(ft8)
        feed.select(decodeId: "ft8")
        feed.changeMode(to: "FT4", latestBatch: ft4)

        XCTAssertEqual(feed.mode, "FT4")
        XCTAssertNil(feed.selectedDecodeId)
        XCTAssertEqual(feed.displayedBatch, ft4)
        XCTAssertEqual(feed.filteredDecodes.map(\.id), ["ft4"])
    }

    private func decode(id: String, message: String) -> RadioLiteDigitalDecode {
        RadioLiteDigitalDecode(
            id: id,
            message: message,
            snrDb: -10,
            deltaTimeSeconds: 0.2,
            audioFrequencyHz: 1_300,
            confidence: 0.95
        )
    }

    private func batch(
        mode: String,
        slotStartMs: Int64,
        decodes: [RadioLiteDigitalDecode]
    ) -> RadioLiteDigitalDecodeBatch {
        RadioLiteDigitalDecodeBatch(
            radioId: "main",
            mode: mode,
            slotStartMs: slotStartMs,
            slotEndMs: slotStartMs + (mode == "FT4" ? 7_500 : 15_000),
            receivedAtMs: slotStartMs + 16_000,
            revision: 1,
            decodes: decodes
        )
    }
}
