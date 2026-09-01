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

    func testSMeterUsesHamlibIdealScale() throws {
        let cases: [(Double, String)] = [
            (-54, "S0"),
            (-48, "S1"),
            (-36, "S3"),
            (-12, "S7"),
            (-6, "S8"),
            (0, "S9"),
            (10, "S9+10"),
            (20, "S9+20"),
            (60, "S9+60"),
        ]

        for (relativeDb, expected) in cases {
            XCTAssertEqual(
                try XCTUnwrap(RadioLiteSMeterReading(relativeDb: relativeDb)).label,
                expected,
                "Unexpected S-meter label for \(relativeDb) dB relative to S9"
            )
        }
    }

    func testSMeterKeepsFractionalResolutionAndClampsOnlyTheVisualBar() throws {
        let fractional = try XCTUnwrap(RadioLiteSMeterReading(relativeDb: -9))
        XCTAssertEqual(fractional.label, "S7.5")
        XCTAssertEqual(fractional.relativeDbLabel, "-9 dB rel. S9")

        let belowFloor = try XCTUnwrap(RadioLiteSMeterReading(relativeDb: -73))
        XCTAssertEqual(belowFloor.label, "S0")
        XCTAssertEqual(belowFloor.normalizedValue, 0)
        XCTAssertEqual(belowFloor.relativeDbLabel, "-73 dB rel. S9")

        let aboveCeiling = try XCTUnwrap(RadioLiteSMeterReading(relativeDb: 75))
        XCTAssertEqual(aboveCeiling.label, "S9+75")
        XCTAssertEqual(aboveCeiling.normalizedValue, 1)

        XCTAssertNil(RadioLiteSMeterReading(relativeDb: .nan))
        XCTAssertNil(RadioLiteSMeterReading(relativeDb: .infinity))
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
