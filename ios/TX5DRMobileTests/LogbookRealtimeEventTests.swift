import XCTest
@testable import TX5DRMobile

final class LogbookRealtimeEventTests: XCTestCase {
    func testDecodesChangeNotice() throws {
        let envelope = try JSONDecoder().decode(
            WSInboundEnvelope.self,
            from: Data(#"{"type":"logbookChangeNotice","data":{"logBookId":"main","operatorId":"op-1"}}"#.utf8)
        )

        let event = try XCTUnwrap(LogbookRealtimeEvent(envelope: envelope))

        XCTAssertEqual(event.kind, .changeNotice)
        XCTAssertEqual(event.logBookId, "main")
        XCTAssertEqual(event.operatorId, "op-1")
    }

    func testDecodesDetailedWriteFailure() throws {
        let envelope = try JSONDecoder().decode(
            WSInboundEnvelope.self,
            from: Data(#"{"type":"logbookWriteFailed","data":{"logBookId":"main","unsavedCount":2,"error":{"code":"LOGBOOK_WRITE_FAILED","message":"disk full","occurredAt":1234}}}"#.utf8)
        )

        let event = try XCTUnwrap(LogbookRealtimeEvent(envelope: envelope))

        XCTAssertEqual(event.kind, .writeFailed)
        XCTAssertEqual(event.logBookId, "main")
        XCTAssertEqual(event.writeFailureMessage, "disk full")
        XCTAssertEqual(event.unsavedCount, 2)
    }

    func testRejectsUnrelatedControlEvent() throws {
        let envelope = try JSONDecoder().decode(
            WSInboundEnvelope.self,
            from: Data(#"{"type":"meterData","data":{"power":{"percent":50}}}"#.utf8)
        )

        XCTAssertNil(LogbookRealtimeEvent(envelope: envelope))
    }

    func testRefreshPolicyRejectsAnotherLogbookAndOperator() throws {
        let envelope = try JSONDecoder().decode(
            WSInboundEnvelope.self,
            from: Data(#"{"type":"qsoRecordAdded","data":{"logBookId":"other","operatorId":"op-2","qsoRecord":{}}}"#.utf8)
        )
        let event = try XCTUnwrap(LogbookRealtimeEvent(envelope: envelope))

        XCTAssertNil(
            LogbookRealtimeRefreshPolicy.logBookId(
                for: event,
                selectedLogBookId: "main",
                selectedOperatorId: "op-1"
            )
        )
    }

    func testRefreshPolicyAcceptsSelectedOperatorAndUsesEventLogbook() throws {
        let envelope = try JSONDecoder().decode(
            WSInboundEnvelope.self,
            from: Data(#"{"type":"qsoRecordUpdated","data":{"logBookId":"field","operatorId":"op-1","qsoRecord":{}}}"#.utf8)
        )
        let event = try XCTUnwrap(LogbookRealtimeEvent(envelope: envelope))

        XCTAssertEqual(
            LogbookRealtimeRefreshPolicy.logBookId(
                for: event,
                selectedLogBookId: "main",
                selectedOperatorId: "op-1"
            ),
            "field"
        )
    }
}
