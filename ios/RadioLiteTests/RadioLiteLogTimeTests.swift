import XCTest
@testable import RadioLite

final class RadioLiteLogTimeTests: XCTestCase {
    @MainActor
    func testUTCLogLabelConvertsOffsetDateAndShowsUTCMarker() throws {
        let localDate = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-09-04T22:15:00+08:00")
        )

        XCTAssertEqual(
            RadioLiteLogTime.utc(Int64(localDate.timeIntervalSince1970 * 1_000)),
            "09-04 14:15z"
        )
    }

    @MainActor
    func testUTCLogLabelUsesUTCDayAcrossLocalMidnight() throws {
        let localDate = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-09-05T00:05:00+08:00")
        )

        XCTAssertEqual(
            RadioLiteLogTime.utc(Int64(localDate.timeIntervalSince1970 * 1_000)),
            "09-04 16:05z"
        )
    }
}
