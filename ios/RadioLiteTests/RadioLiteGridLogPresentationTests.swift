import XCTest
@testable import RadioLite

final class RadioLiteGridLogPresentationTests: XCTestCase {
    func testAppliesPagesInOrderAndPreservesEveryQSO() {
        var presentation = RadioLiteGridLogPresentation(grid: "pm95", expectedTotal: 3)

        XCTAssertTrue(
            presentation.apply(
                page(records: [qso(id: "3"), qso(id: "2")], total: 3, limit: 2, offset: 0),
                requestedGrid: "PM95"
            )
        )
        XCTAssertEqual(presentation.records.map(\.id), ["3", "2"])
        XCTAssertEqual(presentation.nextOffset, 2)
        XCTAssertTrue(presentation.hasMore)

        XCTAssertTrue(
            presentation.apply(
                page(records: [qso(id: "1")], total: 3, limit: 2, offset: 2),
                requestedGrid: "PM95"
            )
        )
        XCTAssertEqual(presentation.records.map(\.id), ["3", "2", "1"])
        XCTAssertEqual(presentation.nextOffset, 3)
        XCTAssertFalse(presentation.hasMore)
    }

    func testRejectsLateResponseForAnotherGridAndOutOfOrderPage() {
        var presentation = RadioLiteGridLogPresentation(grid: "PM95", expectedTotal: 2)
        let response = page(records: [qso(id: "1")], total: 2, limit: 1, offset: 0)

        XCTAssertFalse(presentation.apply(response, requestedGrid: "FN31"))
        XCTAssertTrue(presentation.records.isEmpty)
        XCTAssertFalse(
            presentation.apply(
                page(records: [qso(id: "2")], total: 2, limit: 1, offset: 1),
                requestedGrid: "PM95"
            )
        )
        XCTAssertTrue(presentation.records.isEmpty)
    }

    func testReloadingFirstPageResetsExistingRecordsAndDeduplicatesIDs() {
        var presentation = RadioLiteGridLogPresentation(grid: "PM95", expectedTotal: 3)
        _ = presentation.apply(
            page(records: [qso(id: "3"), qso(id: "2")], total: 3, limit: 2, offset: 0),
            requestedGrid: "PM95"
        )
        _ = presentation.apply(
            page(records: [qso(id: "2"), qso(id: "1")], total: 3, limit: 3, offset: 0),
            requestedGrid: "PM95"
        )

        XCTAssertEqual(presentation.records.map(\.id), ["2", "1"])
        XCTAssertEqual(presentation.nextOffset, 2)
        XCTAssertTrue(presentation.hasMore)
    }

    func testServerTotalReplacesMapEstimateAndShortFirstPageIsTerminal() {
        var presentation = RadioLiteGridLogPresentation(grid: "PM95", expectedTotal: 99)

        XCTAssertTrue(
            presentation.apply(
                page(records: [qso(id: "2"), qso(id: "1")], total: 2, limit: 50, offset: 0),
                requestedGrid: "pm95"
            )
        )

        XCTAssertEqual(presentation.total, 2)
        XCTAssertEqual(presentation.nextOffset, 2)
        XCTAssertEqual(presentation.records.map(\.id), ["2", "1"])
        XCTAssertFalse(presentation.hasMore)
    }

    private func page(
        records: [RadioLiteQSORecord],
        total: Int,
        limit: Int,
        offset: Int
    ) -> RadioLiteLogPage {
        RadioLiteLogPage(records: records, total: total, limit: limit, offset: offset)
    }

    private func qso(id: String) -> RadioLiteQSORecord {
        RadioLiteQSORecord(
            id: id,
            radioId: nil,
            source: "IMPORT",
            call: "JA1ABC",
            startedAtMs: 1,
            endedAtMs: nil,
            frequencyHz: 14_074_000,
            band: "20M",
            mode: "FT8",
            submode: nil,
            rstSent: "-10",
            rstReceived: "-08",
            grid: "PM95",
            myCall: "BH6AJS",
            myGrid: nil,
            fields: [:]
        )
    }
}
