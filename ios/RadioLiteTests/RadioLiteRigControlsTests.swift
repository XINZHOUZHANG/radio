import Foundation
import XCTest
@testable import RadioLite

final class RadioLiteRigControlsTests: XCTestCase {
    func testDecodesWireControlsAndBuildsTransmitAwareDisplayState() throws {
        let response = try JSONDecoder().decode(
            RadioLiteRigControlsResponse.self,
            from: controlsPayload
        )

        XCTAssertEqual(response.t, "rig.controls")
        XCTAssertEqual(response.radioId, "main")
        XCTAssertEqual(response.commandId, "controls-1")
        XCTAssertEqual(response.controls.map(\.id), [
            "level:RFPOWER",
            "function:NB",
            "function:TUNER",
            "passband:CURRENT",
            "level:FUTUREGAIN",
        ])

        let power = try XCTUnwrap(response.controls.first { $0.id == "level:RFPOWER" })
        let availablePower = power.displayState(isTransmitting: false)
        XCTAssertEqual(availablePower.kind, .level)
        XCTAssertEqual(availablePower.label, "发射功率")
        XCTAssertEqual(availablePower.value, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(availablePower.minimum, 0.0, accuracy: 0.000_001)
        XCTAssertEqual(availablePower.maximum, 1.0, accuracy: 0.000_001)
        XCTAssertEqual(availablePower.step, 0.01, accuracy: 0.000_001)
        XCTAssertEqual(availablePower.options, [])
        XCTAssertTrue(availablePower.writable)
        XCTAssertNil(availablePower.lockedReason)

        let lockedPower = power.displayState(isTransmitting: true)
        XCTAssertFalse(lockedPower.writable)
        XCTAssertEqual(lockedPower.lockedReason, "发射期间不可调整")

        let noiseBlanker = try XCTUnwrap(response.controls.first { $0.id == "function:NB" })
        let noiseBlankerDisplay = noiseBlanker.displayState(isTransmitting: true)
        XCTAssertEqual(noiseBlankerDisplay.kind, .function)
        XCTAssertEqual(noiseBlankerDisplay.label, "脉冲噪声抑制")
        XCTAssertEqual(noiseBlankerDisplay.options.map(\.value), [0.0, 1.0])
        XCTAssertEqual(noiseBlankerDisplay.options.map(\.label), ["关闭", "开启"])
        XCTAssertTrue(noiseBlankerDisplay.writable)
        XCTAssertNil(noiseBlankerDisplay.lockedReason)

        let tuner = try XCTUnwrap(response.controls.first { $0.id == "function:TUNER" })
        let tunerDisplay = tuner.displayState(isTransmitting: false)
        XCTAssertEqual(tunerDisplay.label, "机内天调接入")
        XCTAssertTrue(tunerDisplay.writable)
        XCTAssertFalse(tuner.displayState(isTransmitting: true).writable)

        let filter = try XCTUnwrap(response.controls.first { $0.id == "passband:CURRENT" })
        let filterDisplay = filter.displayState(isTransmitting: false)
        XCTAssertEqual(filterDisplay.kind, .filter)
        XCTAssertEqual(filterDisplay.label, "滤波器带宽")
        XCTAssertEqual(filterDisplay.value, 3_000.0, accuracy: 0.000_001)
        XCTAssertEqual(filterDisplay.minimum, 100.0, accuracy: 0.000_001)
        XCTAssertEqual(filterDisplay.maximum, 12_000.0, accuracy: 0.000_001)
        XCTAssertEqual(filterDisplay.step, 50.0, accuracy: 0.000_001)
        XCTAssertEqual(filterDisplay.options, [])
        XCTAssertTrue(filterDisplay.writable)

        let futureControl = try XCTUnwrap(response.controls.first { $0.id == "level:FUTUREGAIN" })
        XCTAssertEqual(futureControl.kind, .level)
        XCTAssertEqual(
            futureControl.displayState(isTransmitting: false).label,
            "FUTUREGAIN",
            "an unknown Hamlib token must remain usable with a safe fallback label"
        )
    }

    func testSetRequestContainsExactlyTheCorrelatedControlFields() {
        let request = RadioLiteRigControlProtocol.setRequest(
            radioId: "main",
            controlToken: "lease-token",
            controlId: "level:RFPOWER",
            value: 0.35,
            commandId: "control-power-1"
        )

        XCTAssertEqual(request, .object([
            "t": .string("rig.control.set"),
            "radioId": .string("main"),
            "controlToken": .string("lease-token"),
            "controlId": .string("level:RFPOWER"),
            "value": .number(0.35),
            "commandId": .string("control-power-1"),
        ]))
    }

    func testConfirmedReadbackReplacesTheMatchingControlWithoutReordering() throws {
        let response = try JSONDecoder().decode(
            RadioLiteRigControlsResponse.self,
            from: controlsPayload
        )
        let confirmation = try JSONDecoder().decode(
            RadioLiteRigControlConfirmation.self,
            from: Data(#"""
            {
              "t":"rig.control.confirmed",
              "radioId":"main",
              "commandId":"control-power-1",
              "control":{
                "id":"level:RFPOWER",
                "kind":"level",
                "token":"RFPOWER",
                "value":0.35,
                "minimum":0.10,
                "maximum":0.90,
                "step":0.05,
                "unit":"ratio",
                "transmitLocked":true,
                "futureReadbackQuality":"confirmed"
              },
              "futureServerTimestamp":123456
            }
            """#.utf8)
        )

        let updated = RadioLiteRigControlProtocol.applying(
            confirmation,
            to: response.controls
        )

        XCTAssertEqual(updated.map(\.id), response.controls.map(\.id))
        XCTAssertEqual(updated[0].value, 0.35, accuracy: 0.000_001)
        XCTAssertEqual(updated[0].minimum, 0.10, accuracy: 0.000_001)
        XCTAssertEqual(updated[0].maximum, 0.90, accuracy: 0.000_001)
        XCTAssertEqual(updated[0].step, 0.05, accuracy: 0.000_001)
        XCTAssertEqual(Array(updated.dropFirst()), Array(response.controls.dropFirst()))
    }

    func testCatalogueInvalidationClearsControlsAndRejectsPreDisconnectResponse() throws {
        let response = try JSONDecoder().decode(
            RadioLiteRigControlsResponse.self,
            from: controlsPayload
        )
        var catalogue = RadioLiteRigControlCatalogue()
        let requestGeneration = catalogue.beginDiscovery()
        XCTAssertTrue(catalogue.publish(response.controls, generation: requestGeneration))
        XCTAssertEqual(catalogue.controls.map(\.id), response.controls.map(\.id))

        catalogue.invalidate()

        XCTAssertTrue(catalogue.controls.isEmpty, "disconnect must immediately remove writable controls")
        XCTAssertFalse(
            catalogue.publish(response.controls, generation: requestGeneration),
            "an in-flight response from before disconnect must not repopulate the catalogue"
        )
        XCTAssertTrue(catalogue.controls.isEmpty)
    }

    func testNewDiscoveryClearsOldControlsAndOnlyPublishesCurrentGeneration() throws {
        let response = try JSONDecoder().decode(
            RadioLiteRigControlsResponse.self,
            from: controlsPayload
        )
        var catalogue = RadioLiteRigControlCatalogue()
        let oldGeneration = catalogue.beginDiscovery()
        XCTAssertTrue(catalogue.publish(response.controls, generation: oldGeneration))

        let currentGeneration = catalogue.beginDiscovery()

        XCTAssertTrue(catalogue.controls.isEmpty, "a refresh failure must leave no stale controls writable")
        XCTAssertFalse(catalogue.publish(response.controls, generation: oldGeneration))
        XCTAssertTrue(catalogue.controls.isEmpty)
        XCTAssertTrue(catalogue.publish(response.controls, generation: currentGeneration))
        XCTAssertEqual(catalogue.controls.map(\.id), response.controls.map(\.id))
    }

    func testControlOperationOwnershipRejectsErrorsFromOldRadioOrCatalogueGeneration() {
        let ownership = RadioLiteRigControlOperationOwnership(
            radioId: "main",
            catalogueGeneration: 7
        )

        XCTAssertTrue(ownership.isCurrent(selectedRadioId: "main", catalogueGeneration: 7))
        XCTAssertFalse(
            ownership.isCurrent(selectedRadioId: "backup", catalogueGeneration: 7),
            "an error from the previous radio must not replace the current radio's UI state"
        )
        XCTAssertFalse(
            ownership.isCurrent(selectedRadioId: "main", catalogueGeneration: 8),
            "an error from an invalidated controls catalogue must be ignored"
        )
    }

    func testTunerStartActionNeverBecomesAStopToggle() {
        XCTAssertEqual(
            RadioLiteTunerInteractionPolicy.startAction(
                isTuning: false,
                isPending: false,
                tuneSupported: true
            ),
            .start
        )
        XCTAssertEqual(
            RadioLiteTunerInteractionPolicy.startAction(
                isTuning: true,
                isPending: false,
                tuneSupported: true
            ),
            .unavailable
        )
        XCTAssertEqual(
            RadioLiteTunerInteractionPolicy.startAction(
                isTuning: false,
                isPending: true,
                tuneSupported: true
            ),
            .unavailable
        )
        XCTAssertEqual(
            RadioLiteTunerInteractionPolicy.startAction(
                isTuning: false,
                isPending: false,
                tuneSupported: false
            ),
            .unavailable
        )
        XCTAssertTrue(RadioLiteTunerInteractionPolicy.canEmergencyStop(isTuning: true))
        XCTAssertFalse(RadioLiteTunerInteractionPolicy.canEmergencyStop(isTuning: false))
    }

    func testDecodesACompletedTuningLeaseEvent() throws {
        let completion = try JSONDecoder().decode(
            RadioLiteActionCompletion.self,
            from: Data(#"""
            {
              "t":"rig.action.completed",
              "radioId":"main",
              "id":"action:TUNER",
              "transmitToken":"tuning-lease-token",
              "reason":"ptt_off"
            }
            """#.utf8)
        )

        XCTAssertEqual(completion.t, "rig.action.completed")
        XCTAssertEqual(completion.radioId, "main")
        XCTAssertEqual(completion.id, "action:TUNER")
        XCTAssertEqual(completion.transmitToken, "tuning-lease-token")
        XCTAssertEqual(completion.reason, "ptt_off")
    }

    func testSuccessfulTuneStartReflectsThePersistentTunerSwitchWithoutAnotherCATWrite() throws {
        let response = try JSONDecoder().decode(
            RadioLiteRigControlsResponse.self,
            from: controlsPayload
        )

        let updated = RadioLiteTunerInteractionPolicy.reflectingSuccessfulTuneStart(
            in: response.controls
        )

        XCTAssertEqual(updated.map(\.id), response.controls.map(\.id))
        XCTAssertEqual(updated.first { $0.id == "function:TUNER" }?.value, 1)
        XCTAssertEqual(
            updated.first { $0.id == "level:RFPOWER" }?.value,
            response.controls.first { $0.id == "level:RFPOWER" }?.value
        )
    }

    func testTunerSwitchPresentationUsesTheDiscoveredPersistentHamlibControl() throws {
        let response = try JSONDecoder().decode(
            RadioLiteRigControlsResponse.self,
            from: controlsPayload
        )

        let tuner = try XCTUnwrap(
            RadioLiteTunerInteractionPolicy.tunerSwitch(in: response.controls)
        )

        XCTAssertEqual(tuner.id, "function:TUNER")
        XCTAssertEqual(tuner.value, 0)
        XCTAssertFalse(
            RadioLiteTunerInteractionPolicy.generalControls(in: response.controls)
                .contains { $0.id == "function:TUNER" }
        )
        XCTAssertNil(
            RadioLiteTunerInteractionPolicy.tunerSwitch(
                in: response.controls.filter { $0.id != "function:TUNER" }
            )
        )
    }

    private var controlsPayload: Data {
        Data(#"""
        {
          "t":"rig.controls",
          "radioId":"main",
          "commandId":"controls-1",
          "controls":[
            {
              "id":"level:RFPOWER",
              "kind":"level",
              "token":"RFPOWER",
              "value":0.25,
              "minimum":0,
              "maximum":1,
              "step":0.01,
              "unit":"ratio",
              "transmitLocked":true,
              "futureMetadata":{"scale":"logarithmic"}
            },
            {
              "id":"function:NB",
              "kind":"function",
              "token":"NB",
              "value":1,
              "minimum":0,
              "maximum":1,
              "step":1,
              "unit":"boolean",
              "transmitLocked":false,
              "futureBooleanStyle":"toggle"
            },
            {
              "id":"function:TUNER",
              "kind":"function",
              "token":"TUNER",
              "value":0,
              "minimum":0,
              "maximum":1,
              "step":1,
              "unit":"boolean",
              "transmitLocked":true
            },
            {
              "id":"passband:CURRENT",
              "kind":"passband",
              "token":"CURRENT",
              "value":3000,
              "minimum":100,
              "maximum":12000,
              "step":50,
              "unit":"hertz",
              "transmitLocked":false,
              "futureDisplayGroup":"filter"
            },
            {
              "id":"level:FUTUREGAIN",
              "kind":"level",
              "token":"FUTUREGAIN",
              "value":6,
              "minimum":0,
              "maximum":20,
              "step":1,
              "unit":"decibel",
              "transmitLocked":false,
              "futureField":"must be ignored"
            }
          ],
          "futureProtocolRevision":2
        }
        """#.utf8)
    }
}
