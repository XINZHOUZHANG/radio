import Foundation
import XCTest
@testable import RadioLite

final class RadioLiteCapabilityControlsTests: XCTestCase {
    func testGroupsControlsInStableProductOrder() throws {
        let controls = try decodeCapabilitiesFixture()

        XCTAssertEqual(
            RadioLiteCapabilityGroups(controls).groups.map(\.id),
            [.rf, .audio, .cw]
        )
        XCTAssertEqual(
            RadioLiteCapabilityGroups(controls).groups.flatMap(\.controls).map(\.id),
            ["level:RFPOWER", "function:NB", "level:AF", "parameter:CWPITCH"]
        )
    }

    func testTransmitLockedControlIsDisabledDuringTransmit() throws {
        let control = try XCTUnwrap(
            decodeCapabilitiesFixture().first { $0.id == "level:RFPOWER" }
        )

        XCTAssertFalse(
            control.displayState(isTransmitting: true, hasControl: true).isEnabled
        )
        XCTAssertTrue(
            control.displayState(isTransmitting: false, hasControl: true).isEnabled
        )
        XCTAssertFalse(
            control.displayState(isTransmitting: false, hasControl: false).isEnabled
        )
    }

    func testTypedControlValuesAndOptionsDecodeWithoutCoercion() throws {
        let controls = try decodeCapabilitiesFixture()
        let noiseBlanker = try XCTUnwrap(controls.first { $0.id == "function:NB" })
        let cwPitch = try XCTUnwrap(controls.first { $0.id == "parameter:CWPITCH" })

        XCTAssertEqual(noiseBlanker.value, .boolean(true))
        XCTAssertEqual(cwPitch.value, .number(700))
        XCTAssertEqual(cwPitch.options?.map(\.value), [.number(600), .number(700), .number(800)])
    }

    func testUnsupportedPresentationAndTunerActionAreAbsentFromGroupedList() throws {
        let controls = try decodeCapabilitiesFixture()
        let groups = RadioLiteCapabilityGroups(controls)

        XCTAssertFalse(groups.groups.flatMap(\.controls).contains { $0.id == "future:RAW" })
        XCTAssertFalse(groups.groups.flatMap(\.controls).contains { $0.id == "action:TUNER" })
        XCTAssertEqual(
            controls.first(where: { $0.id == "action:TUNER" })?.presentation,
            .button
        )
    }

    func testCapabilityRequestsPreserveTypedValuesAndActionIdentity() {
        XCTAssertEqual(
            RadioLiteCapabilityProtocol.getRequest(radioId: "main", commandId: "capabilities-1"),
            .object([
                "t": .string("rig.capabilities.get"),
                "radioId": .string("main"),
                "commandId": .string("capabilities-1"),
            ])
        )
        XCTAssertEqual(
            RadioLiteCapabilityProtocol.setRequest(
                radioId: "main",
                controlToken: "lease-token",
                controlId: "function:NB",
                value: .boolean(false),
                commandId: "control-nb-1"
            ),
            .object([
                "t": .string("rig.control.set"),
                "radioId": .string("main"),
                "controlToken": .string("lease-token"),
                "controlId": .string("function:NB"),
                "value": .bool(false),
                "commandId": .string("control-nb-1"),
            ])
        )
        XCTAssertEqual(
            RadioLiteCapabilityProtocol.actionRequest(
                radioId: "main",
                controlToken: "lease-token",
                id: "action:TUNER",
                commandId: "tuner-1"
            ),
            .object([
                "t": .string("rig.action.invoke"),
                "radioId": .string("main"),
                "controlToken": .string("lease-token"),
                "id": .string("action:TUNER"),
                "commandId": .string("tuner-1"),
            ])
        )
    }

    private func decodeCapabilitiesFixture() throws -> [RadioLiteCapabilityControl] {
        try JSONDecoder().decode(
            RadioLiteCapabilitiesResponse.self,
            from: Data(Self.capabilitiesJSON.utf8)
        ).controls
    }

    private static let capabilitiesJSON = #"""
    {
      "t":"rig.capabilities",
      "radioId":"main",
      "commandId":"capabilities-1",
      "controls":[
        {"id":"parameter:CWPITCH","token":"CWPITCH","group":"cw","access":"read-write","presentation":"discrete","value":700,"minimum":300,"maximum":1000,"step":50,"unit":"hertz","options":[{"value":600,"label":"600 Hz"},{"value":700,"label":"700 Hz"},{"value":800,"label":"800 Hz"}],"transmitLocked":false},
        {"id":"level:AF","token":"AF","group":"audio","access":"read-write","presentation":"slider","value":0.42,"minimum":0,"maximum":1,"step":0.01,"unit":"ratio","transmitLocked":false},
        {"id":"level:RFPOWER","token":"RFPOWER","group":"rf","access":"read-write","presentation":"slider","value":0.25,"minimum":0,"maximum":1,"step":0.01,"unit":"ratio","transmitLocked":true},
        {"id":"function:NB","token":"NB","group":"rf","access":"read-write","presentation":"toggle","value":true,"minimum":0,"maximum":1,"step":1,"unit":"boolean","transmitLocked":false},
        {"id":"action:TUNER","token":"TUNER","group":"rf","access":"action","presentation":"button","value":null,"transmitLocked":true},
        {"id":"future:RAW","token":"RAW","group":"system","access":"read-only","presentation":"future-widget","value":"opaque","transmitLocked":false}
      ]
    }
    """#
}
