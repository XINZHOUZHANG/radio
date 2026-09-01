import Foundation
import XCTest
@testable import RadioLite

final class RadioLiteControlDashboardTests: XCTestCase {
    func testDashboardHidesMetersPairsNoiseControlsAndAddsTuner() throws {
        let controls = try decodeFixture()
        let dashboard = RadioLiteControlDashboard(controls: controls, isTuning: false)

        XCTAssertEqual(
            dashboard.sections.map(\.id),
            [.rf, .noiseReduction, .filter, .tuner, .systemAndOther]
        )

        let visibleControlIDs = dashboard.sections
            .flatMap(\.items)
            .flatMap(\.members)
            .map(\.control.id)
        XCTAssertFalse(visibleControlIDs.contains("level:SWR"))
        XCTAssertFalse(visibleControlIDs.contains("level:RFPOWER_METER_WATTS"))

        let noise = try XCTUnwrap(dashboard.section(for: .noiseReduction))
        XCTAssertEqual(noise.items.count, 1)
        XCTAssertEqual(noise.items[0].title, "脉冲噪声抑制")
        XCTAssertEqual(noise.items[0].members.map(\.control.id), ["function:NB", "level:NB"])
        XCTAssertEqual(noise.items[0].members.map(\.label), ["启用", "强度"])
        XCTAssertEqual(noise.items[0].summary, "开启 · 25%")

        XCTAssertEqual(dashboard.section(for: .rf)?.summary, "功率 80%")
        let tuner = try XCTUnwrap(dashboard.section(for: .tuner))
        XCTAssertEqual(
            Set(tuner.items.flatMap(\.members).map(\.control.id)),
            Set(["function:TUNER", "action:TUNER"])
        )
        XCTAssertEqual(tuner.summary, "旁路")

        let engaged = controls.map { control in
            control.id == "function:TUNER"
                ? control.replacingValue(.boolean(true))
                : control
        }
        XCTAssertEqual(
            RadioLiteControlDashboard(controls: engaged, isTuning: false)
                .section(for: .tuner)?.summary,
            "已接入"
        )
        XCTAssertEqual(
            RadioLiteControlDashboard(controls: engaged, isTuning: true)
                .section(for: .tuner)?.summary,
            "调谐中"
        )
    }

    func testDashboardLabelsDistinguishSettingsFromActualMeters() throws {
        let controls = try decodeFixture()
        let powerSetting = try XCTUnwrap(controls.first { $0.id == "level:RFPOWER" })
        let actualPower = try XCTUnwrap(controls.first { $0.id == "level:RFPOWER_METER_WATTS" })
        let swr = try XCTUnwrap(controls.first { $0.id == "level:SWR" })

        XCTAssertEqual(powerSetting.dashboardLabel, "发射功率设置")
        XCTAssertEqual(actualPower.dashboardLabel, "实时输出功率")
        XCTAssertEqual(swr.dashboardLabel, "驻波比")
        XCTAssertEqual(swr.dashboardFormattedValue, "1.00:1")
    }

    func testAntennaWireGroupFallsBackToSystemAndOtherInsteadOfCreatingAntennaButton() throws {
        let dashboard = RadioLiteControlDashboard(controls: try decodeFixture(), isTuning: false)
        let system = try XCTUnwrap(dashboard.section(for: .systemAndOther))

        XCTAssertEqual(system.id.label, "系统与其他")
        XCTAssertTrue(system.items.flatMap(\.members).contains { $0.control.id == "function:ANTENNA" })
    }

    private func decodeFixture() throws -> [RadioLiteCapabilityControl] {
        try JSONDecoder().decode(
            RadioLiteCapabilitiesResponse.self,
            from: Data(Self.capabilitiesJSON.utf8)
        ).controls
    }

    private static let capabilitiesJSON = #"""
    {
      "t":"rig.capabilities",
      "radioId":"main",
      "commandId":"capabilities-dashboard",
      "controls":[
        {"id":"level:RFPOWER","token":"RFPOWER","group":"rf","access":"read-write","presentation":"slider","value":0.8,"minimum":0,"maximum":1,"step":0.01,"unit":"ratio","transmitLocked":true},
        {"id":"function:NB","token":"NB","group":"rf","access":"read-write","presentation":"toggle","value":true,"minimum":0,"maximum":1,"step":1,"unit":"boolean","transmitLocked":false},
        {"id":"level:NB","token":"NB","group":"rf","access":"read-write","presentation":"slider","value":0.25,"minimum":0,"maximum":1,"step":0.01,"unit":"ratio","transmitLocked":false},
        {"id":"passband:CURRENT","token":"PASSBAND","group":"mode","access":"read-write","presentation":"discrete","value":2400,"minimum":100,"maximum":12000,"step":50,"unit":"hertz","transmitLocked":true},
        {"id":"function:TUNER","token":"TUNER","group":"rf","access":"read-write","presentation":"toggle","value":false,"minimum":0,"maximum":1,"step":1,"unit":"boolean","transmitLocked":true},
        {"id":"action:TUNER","token":"TUNER","group":"rf","access":"action","presentation":"button","value":null,"transmitLocked":true},
        {"id":"level:SWR","token":"SWR","group":"rf","access":"read-only","presentation":"meter","value":1.0,"unit":"ratio","transmitLocked":false},
        {"id":"level:RFPOWER_METER_WATTS","token":"RFPOWER_METER_WATTS","group":"rf","access":"read-only","presentation":"meter","value":5.0,"unit":"watts","transmitLocked":false},
        {"id":"function:ANTENNA","token":"ANTENNA","group":"antenna","access":"read-write","presentation":"toggle","value":true,"minimum":0,"maximum":1,"step":1,"unit":"boolean","transmitLocked":false}
      ]
    }
    """#
}
