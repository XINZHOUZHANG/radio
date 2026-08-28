import Foundation
import XCTest
@testable import RadioLite

final class RadioLiteManualQSOValidationTests: XCTestCase {
    func testValidFormNormalizesPayloadKeepsEmptyCommentNilAndAcceptsSixHundredWatts() throws {
        let request = try makeForm(
            call: " ja1abc ",
            grid: " pm95 ",
            frequencyMHz: "14,250000",
            powerWatts: "600",
            comment: ""
        ).makeRequest()

        XCTAssertEqual(request.radioId, "main")
        XCTAssertEqual(request.call, "JA1ABC")
        XCTAssertEqual(request.grid, "PM95")
        XCTAssertEqual(request.frequencyHz, 14_250_000)
        XCTAssertEqual(request.txPowerWatts, 600)
        XCTAssertNil(request.comment)
    }

    func testChineseCommentIsRejectedWithAChineseExplanation() {
        XCTAssertThrowsError(try makeForm(comment: "信号很好").makeRequest()) { error in
            XCTAssertEqual(error as? RadioLiteManualQSOValidationError, .invalidComment)
            XCTAssertEqual(
                error.localizedDescription,
                "备注只能使用 1–256 个可打印 ASCII 字符，不能包含中文、换行或表情"
            )
        }
    }

    func testCommentAcceptsExactlyTwoHundredFiftySixPrintableASCIICharacters() throws {
        let comment = String(repeating: "~", count: 256)

        XCTAssertEqual(try makeForm(comment: comment).makeRequest().comment, comment)
        assertError(.invalidComment, form: makeForm(comment: comment + "~"))
        assertError(.invalidComment, form: makeForm(comment: "line one\nline two"))
    }

    func testCallsignUsesTheServerShapeAfterTrimmingAndUppercasing() {
        XCTAssertNoThrow(try makeForm(call: String(repeating: "A", count: 32)).makeRequest())
        assertError(.invalidCall, form: makeForm(call: "A"))
        assertError(.invalidCall, form: makeForm(call: "JA 1ABC"))
        assertError(.invalidCall, form: makeForm(call: "呼号JA1"))
        assertError(.invalidCall, form: makeForm(call: "\nJA1ABC\n"))
        assertError(
            .invalidCall,
            form: makeForm(call: String(repeating: "A", count: 32) + " ")
        )
    }

    func testOptionalGridMustBeAValidMaidenheadLocator() throws {
        XCTAssertNil(try makeForm(grid: "   ").makeRequest().grid)
        XCTAssertEqual(try makeForm(grid: " fn31pr ").makeRequest().grid, "FN31PR")
        assertError(.invalidGrid, form: makeForm(grid: "PM9X"))
        assertError(.invalidGrid, form: makeForm(grid: "SS00"))
        assertError(.invalidGrid, form: makeForm(grid: "\nPM95\n"))
        assertError(.invalidGrid, form: makeForm(grid: "   PM95  "))
    }

    func testFrequencyMustParseAndFallInsideTheServerBandTable() {
        assertError(.invalidFrequency, form: makeForm(frequencyMHz: "not a number"))
        assertError(.invalidFrequency, form: makeForm(frequencyMHz: "0"))
        assertError(.invalidFrequency, form: makeForm(frequencyMHz: "14.500"))
        assertError(.invalidFrequency, form: makeForm(frequencyMHz: "9223372036854.775807"))
    }

    func testEndTimeCannotPrecedeStartTime() {
        assertError(
            .endBeforeStart,
            form: makeForm(
                startedAt: Date(timeIntervalSince1970: 1_060),
                endedAt: Date(timeIntervalSince1970: 1_000)
            )
        )
    }

    func testStartTimeMustBeANonNegativeServerTimestamp() {
        assertError(
            .invalidStartTime,
            form: makeForm(
                startedAt: Date(timeIntervalSince1970: -1),
                endedAt: nil
            )
        )
    }

    func testEndTimeReportsItsOwnInvalidTimestamp() {
        assertError(
            .invalidEndTime,
            form: makeForm(
                startedAt: Date(timeIntervalSince1970: 1),
                endedAt: Date(timeIntervalSince1970: -1)
            )
        )
    }

    func testPowerAcceptsServerBoundsIncludingSixHundredWatts() throws {
        XCTAssertNil(try makeForm(powerWatts: "   ").makeRequest().txPowerWatts)
        XCTAssertEqual(try makeForm(powerWatts: "0").makeRequest().txPowerWatts, 0)
        XCTAssertEqual(try makeForm(powerWatts: "600").makeRequest().txPowerWatts, 600)
        XCTAssertEqual(try makeForm(powerWatts: "100000").makeRequest().txPowerWatts, 100_000)
        assertError(.invalidPower, form: makeForm(powerWatts: "-0.1"))
        assertError(.invalidPower, form: makeForm(powerWatts: "100000.1"))
        assertError(.invalidPower, form: makeForm(powerWatts: "nan"))
    }

    func testMissingSelectedRadioIsAVisibleValidationError() {
        assertError(.radioUnavailable, form: makeForm(radioId: nil))
    }

    func testOptionalSignalReportsUsePrintableASCIIAndServerLength() throws {
        XCTAssertNil(try makeForm(rstSent: "", rstReceived: "").makeRequest().rstSent)
        assertError(.invalidSentReport, form: makeForm(rstSent: "五九"))
        assertError(
            .invalidReceivedReport,
            form: makeForm(rstReceived: String(repeating: "5", count: 17))
        )
    }

    private func makeForm(
        radioId: String? = "main",
        call: String = "JA1ABC",
        grid: String = "PM95",
        frequencyMHz: String = "14.250",
        rstSent: String = "59",
        rstReceived: String = "57",
        powerWatts: String = "100",
        comment: String = "Good signal",
        startedAt: Date = Date(timeIntervalSince1970: 1_000),
        endedAt: Date? = Date(timeIntervalSince1970: 1_060)
    ) -> RadioLiteManualQSOForm {
        RadioLiteManualQSOForm(
            radioId: radioId,
            call: call,
            grid: grid,
            frequencyMHz: frequencyMHz,
            mode: "SSB",
            submode: "USB",
            rstSent: rstSent,
            rstReceived: rstReceived,
            powerWatts: powerWatts,
            comment: comment,
            startedAt: startedAt,
            endedAt: endedAt
        )
    }

    private func assertError(
        _ expected: RadioLiteManualQSOValidationError,
        form: RadioLiteManualQSOForm,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try form.makeRequest(), file: file, line: line) { error in
            XCTAssertEqual(
                error as? RadioLiteManualQSOValidationError,
                expected,
                file: file,
                line: line
            )
        }
    }
}
