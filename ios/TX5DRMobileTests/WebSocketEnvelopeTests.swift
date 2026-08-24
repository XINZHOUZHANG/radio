import XCTest
@testable import TX5DRMobile

final class WebSocketEnvelopeTests: XCTestCase {
    func testOutboundEnvelopeMatchesTX5DRShape() throws {
        let envelope = WSOutboundEnvelope(
            type: "setClientSelectedOperator",
            timestamp: "2026-08-23T00:00:00Z",
            id: "request-1",
            data: .object(["selectedOperatorId": .string("operator-1")])
        )
        let encoded = try JSONEncoder().encode(envelope)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        XCTAssertEqual(json["type"] as? String, "setClientSelectedOperator")
        XCTAssertEqual(json["timestamp"] as? String, "2026-08-23T00:00:00Z")
        XCTAssertEqual(json["id"] as? String, "request-1")
        XCTAssertEqual((json["data"] as? [String: Any])?["selectedOperatorId"] as? String, "operator-1")
    }

    func testNilPayloadAndIDAreOmitted() throws {
        let envelope = WSOutboundEnvelope(type: "ping", timestamp: "now", id: nil, data: nil)
        let encoded = try JSONEncoder().encode(envelope)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        XCTAssertEqual(Set(json.keys), Set(["type", "timestamp"]))
    }

    func testInboundEnvelopeDecodesUnknownJSONPayload() throws {
        let data = Data(#"{"type":"meterData","timestamp":"now","data":{"power":{"percent":42.5}}}"#.utf8)
        let envelope = try JSONDecoder().decode(WSInboundEnvelope.self, from: data)

        XCTAssertEqual(envelope.type, "meterData")
        XCTAssertEqual(envelope.timestamp, "now")
        XCTAssertEqual(envelope.data?["power"]?["percent"]?.doubleValue, 42.5)
    }

    func testQueueCapabilityErrorIsLocalizedWithoutHidingUnknownServerErrors() {
        XCTAssertEqual(
            RadioServerNotice.localized("strategy_not_queue_capable"),
            "当前自动化策略不支持呼叫队列，请使用“呼叫”"
        )
        XCTAssertEqual(RadioServerNotice.localized("custom_server_error"), "custom_server_error")
    }
}
