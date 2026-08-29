import XCTest
@testable import TX5DRMobile

final class FT8OperatorContextTests: XCTestCase {
    func testDraftPrefersRuntimeContextAndBuildsNormalizedCommand() throws {
        let status = try JSONValue.parse(#"""
        {
          "context": {
            "targetCall": "OLD1CALL",
            "targetGrid": "pm01",
            "frequency": 1450,
            "reportSent": -12,
            "reportReceived": -9
          },
          "runtime": {
            "context": {
              "targetCallsign": "bg2test",
              "targetGrid": "pn35aa",
              "reportSent": -7,
              "reportReceived": -5,
              "actualFrequency": 1500
            }
          }
        }
        """#)
        var draft = FT8OperatorContextDraft(status: status)

        XCTAssertEqual(draft.targetCallsign, "bg2test")
        XCTAssertEqual(draft.targetGrid, "pn35aa")
        XCTAssertEqual(draft.audioFrequencyHz, "1450")
        XCTAssertEqual(draft.reportSent, "-7")
        XCTAssertEqual(draft.reportReceived, "-5")

        draft.targetCallsign = "  bh6ajs/p "
        draft.targetGrid = " om89aa "
        let command = try draft.commandContext()

        XCTAssertEqual(command["targetCallsign"], .string("BH6AJS/P"))
        XCTAssertEqual(command["targetGrid"], .string("OM89AA"))
        XCTAssertEqual(command["frequency"], .number(1_450))
        XCTAssertEqual(command["reportSent"], .number(-7))
        XCTAssertEqual(command["reportReceived"], .number(-5))
    }

    func testDraftRejectsOutOfRangeAudioFrequency() {
        var draft = FT8OperatorContextDraft()
        draft.audioFrequencyHz = "3001"

        XCTAssertEqual(draft.validationMessage, FT8OperatorContextError.invalidFrequency.localizedDescription)
        XCTAssertThrowsError(try draft.commandContext()) { error in
            XCTAssertEqual(error as? FT8OperatorContextError, .invalidFrequency)
        }
    }

    func testDraftRejectsNonIntegerReports() {
        var draft = FT8OperatorContextDraft()
        draft.reportSent = "-10.5"

        XCTAssertThrowsError(try draft.commandContext()) { error in
            XCTAssertEqual(error as? FT8OperatorContextError, .invalidSentReport)
        }

        draft.reportSent = "-10"
        draft.reportReceived = "RR73"
        XCTAssertThrowsError(try draft.commandContext()) { error in
            XCTAssertEqual(error as? FT8OperatorContextError, .invalidReceivedReport)
        }
    }

    func testEmptyTargetAndGridAreValidForResetToCQ() throws {
        var draft = FT8OperatorContextDraft()
        draft.targetCallsign = " "
        draft.targetGrid = " "
        draft.reportSent = "0"
        draft.reportReceived = "0"

        let command = try draft.commandContext()

        XCTAssertEqual(command["targetCallsign"], .string(""))
        XCTAssertEqual(command["targetGrid"], .string(""))
        XCTAssertNil(draft.validationMessage)
    }
}
