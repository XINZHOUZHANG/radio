import XCTest
@testable import RadioLite

final class RadioLiteTelemetryTests: XCTestCase {
    func testDecodesTransmitTelemetryWithoutTreatingRFPowerSettingAsMeter() throws {
        let fixture = Data(#"""
        {
          "t":"rig.telemetry",
          "radioId":"main",
          "sampledAtMs":1787700000000,
          "state":{"frequencyHz":14074000,"mode":"USB","passbandHz":3000,"ptt":true},
          "meters":{"rfPowerWatts":37.5,"swr":1.4,"alcRatio":0.32},
          "availableMeters":["SWR","ALC","RFPOWER","RFPOWER_METER_WATTS"]
        }
        """#.utf8)

        let value = try JSONDecoder().decode(RadioLiteTelemetry.self, from: fixture)

        XCTAssertEqual(value.meters.rfPowerWatts, 37.5)
        XCTAssertEqual(value.meters.swr, 1.4)
        XCTAssertTrue(value.hasActualPowerMeter)

        let settingOnly = try JSONDecoder().decode(
            RadioLiteTelemetry.self,
            from: Data(#"""
            {
              "t":"rig.telemetry","radioId":"main","sampledAtMs":1787700000000,
              "state":{"frequencyHz":14074000,"mode":"USB","passbandHz":3000,"ptt":true},
              "meters":{},"availableMeters":["RFPOWER"]
            }
            """#.utf8)
        )
        XCTAssertFalse(settingOnly.hasActualPowerMeter)
    }

    func testTelemetryBecomesStaleAfterThreeSamplePeriods() throws {
        let sample = try JSONDecoder().decode(
            RadioLiteTelemetry.self,
            from: Data(#"""
            {
              "t":"rig.telemetry","radioId":"main","sampledAtMs":10000,
              "state":{"frequencyHz":7074000,"mode":"DATA-U","passbandHz":3000,"ptt":false},
              "meters":{"strengthDbRelativeS9":-8},"availableMeters":["STRENGTH"]
            }
            """#.utf8)
        )

        XCTAssertFalse(sample.isStale(nowMs: sample.sampledAtMs + 6_000, periodMs: 2_000))
        XCTAssertTrue(sample.isStale(nowMs: sample.sampledAtMs + 6_001, periodMs: 2_000))
    }

    func testSubscriptionOwnershipBuildsExactMessagesAndRejectsAnotherRadio() throws {
        let ownership = RadioLiteTelemetrySubscriptionOwnership(radioId: "main")
        let other = try JSONDecoder().decode(
            RadioLiteTelemetry.self,
            from: Data(#"""
            {
              "t":"rig.telemetry","radioId":"backup","sampledAtMs":10000,
              "state":{"frequencyHz":7074000,"mode":"USB","passbandHz":2400,"ptt":false},
              "meters":{},"availableMeters":[]
            }
            """#.utf8)
        )

        XCTAssertEqual(ownership.subscribeMessage(commandId: "subscribe-1"), .object([
            "t": .string("rig.telemetry.subscribe"),
            "radioId": .string("main"),
            "commandId": .string("subscribe-1"),
        ]))
        XCTAssertEqual(ownership.unsubscribeMessage(commandId: "unsubscribe-1"), .object([
            "t": .string("rig.telemetry.unsubscribe"),
            "radioId": .string("main"),
            "commandId": .string("unsubscribe-1"),
        ]))
        XCTAssertFalse(ownership.owns(other))
    }
}
