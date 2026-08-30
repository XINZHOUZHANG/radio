import XCTest
@testable import RadioLite

final class RadioLiteDeviceConfigurationTests: XCTestCase {
    func testHardwarePreflightResponseDecodesOrderedReadOnlyChecks() throws {
        let data = Data(#"""
        {
          "profileId":"main",
          "testedAtMs":1787700000000,
          "readOnly":true,
          "overallStatus":"warning",
          "checks":[
            {"id":"cat","status":"passed","message":"CAT 读取成功","details":{"frequencyHz":"14074000","mode":"PKTUSB"}},
            {"id":"capabilities","status":"passed","message":"能力读取成功","details":{"pttReadback":"true"}},
            {"id":"audioInput","status":"warning","message":"未发现输入端点","details":{"backend":"alsa","id":"hw:1,0"}},
            {"id":"audioOutput","status":"passed","message":"输出端点可用","details":{"backend":"alsa","id":"hw:2,0"}}
          ]
        }
        """#.utf8)

        let result = try JSONDecoder().decode(RadioLiteHardwarePreflightResult.self, from: data)

        XCTAssertTrue(result.readOnly)
        XCTAssertEqual(result.overallStatus, .warning)
        XCTAssertEqual(result.checks.map(\.id), [.cat, .capabilities, .audioInput, .audioOutput])
        XCTAssertEqual(result.checks[0].details["frequencyHz"], "14074000")
        XCTAssertEqual(result.checks[2].status, .warning)
    }

    func testHardwarePreflightOwnershipRejectsResultAfterDraftChanges() throws {
        let original = RadioLiteRadioProfile(
            id: "main",
            name: "IC-7300",
            hamlibModelId: 3_073,
            connection: .init(
                kind: "managed-serial",
                devicePath: "/dev/ttyUSB0",
                baudRate: 115_200,
                host: nil,
                port: nil
            ),
            ptt: .init(method: .rig),
            audioInput: .init(backend: "alsa", id: "hw:1,0", label: nil),
            audioOutput: .init(backend: "alsa", id: "hw:1,0", label: nil),
            station: .init(callsign: "BI1ABC", grid: "OM89"),
            hardwareTxEnabled: false
        )
        var draft = RadioLiteRadioConfigurationDraft(profile: original)
        let ownership = RadioLiteHardwarePreflightOwnership(
            draft: draft,
            serverAddress: "http://100.64.0.10:8080",
            userId: "admin-1"
        )

        XCTAssertTrue(ownership.isCurrent(
            draft,
            serverAddress: "http://100.64.0.10:8080",
            userId: "admin-1"
        ))
        XCTAssertEqual(try ownership.makeProfile(), try draft.makeProfile())

        draft.audioInput = .init(backend: "alsa", id: "hw:9,0", label: nil)

        XCTAssertFalse(ownership.isCurrent(
            draft,
            serverAddress: "http://100.64.0.10:8080",
            userId: "admin-1"
        ))
    }

    func testHardwarePreflightOwnershipRejectsResultAfterServerOrAccountChanges() {
        let profile = RadioLiteRadioProfile(
            id: "dummy",
            name: "Dummy",
            hamlibModelId: 1,
            connection: .init(kind: "hamlib-dummy", devicePath: nil, baudRate: nil, host: nil, port: nil),
            ptt: .init(method: .none),
            audioInput: .init(backend: "alsa", id: "synthetic-rx", label: nil),
            audioOutput: .init(backend: "alsa", id: "synthetic-tx", label: nil),
            station: .init(callsign: "N0CALL", grid: "AA00"),
            hardwareTxEnabled: false
        )
        let draft = RadioLiteRadioConfigurationDraft(profile: profile)
        let ownership = RadioLiteHardwarePreflightOwnership(
            draft: draft,
            serverAddress: "http://100.64.0.10:8080",
            userId: "admin-1"
        )

        XCTAssertFalse(ownership.isCurrent(
            draft,
            serverAddress: "http://100.64.0.11:8080",
            userId: "admin-1"
        ))
        XCTAssertFalse(ownership.isCurrent(
            draft,
            serverAddress: "http://100.64.0.10:8080",
            userId: "admin-2"
        ))
        XCTAssertFalse(ownership.isCurrent(
            draft,
            serverAddress: "http://100.64.0.10:8080",
            userId: nil
        ))
    }

    func testLegacyRadioProfileDefaultsToRigPTT() throws {
        let payload = Data(#"""
        {
          "id":"main","name":"IC-7300","hamlibModelId":3073,
          "connection":{"kind":"managed-serial","devicePath":"/dev/ttyUSB0","baudRate":115200},
          "audioInput":{"backend":"alsa","id":"hw:1,0","label":"USB Audio RX"},
          "audioOutput":{"backend":"alsa","id":"hw:1,0","label":"USB Audio TX"},
          "station":{"callsign":"BI1ABC","grid":"OM89"},
          "hardwareTxEnabled":true
        }
        """#.utf8)

        let profile = try JSONDecoder().decode(RadioLiteRadioProfile.self, from: payload)

        XCTAssertEqual(profile.ptt, .init(method: .rig))
    }

    func testLegacyDummyProfileDefaultsToDisabledPTT() throws {
        let payload = Data(#"""
        {
          "id":"dummy","name":"Hamlib Dummy","hamlibModelId":1,
          "connection":{"kind":"hamlib-dummy"},
          "audioInput":{"backend":"alsa","id":"synthetic-rx"},
          "audioOutput":{"backend":"alsa","id":"synthetic-tx"},
          "station":{"callsign":"N0CALL","grid":"AA00"},
          "hardwareTxEnabled":false
        }
        """#.utf8)

        let profile = try JSONDecoder().decode(RadioLiteRadioProfile.self, from: payload)

        XCTAssertEqual(profile.ptt, .init(method: .none))
    }

    func testHardwareDiscoveryDecodesAllDeviceCatalogs() throws {
        let payload = Data(#"""
        {
          "hamlibModels":[
            {"modelId":3073,"manufacturer":"Icom","model":"IC-7300","backendVersion":"20250815.0","status":"Stable"},
            {"modelId":1049,"manufacturer":"Yaesu","model":"FT-710","backendVersion":"20250703.0","status":"Stable"}
          ],
          "curatedPresets":[
            {"slug":"icom-ic-7300","manufacturer":"Icom","model":"IC-7300","defaultBaudRate":115200,"hamlibModelId":3073,"available":true}
          ],
          "serialDevices":[
            {"id":"by-id:radio","path":"/dev/serial/by-id/radio","label":"Icom USB","stable":true}
          ],
          "audioInputs":[
            {"backend":"alsa","direction":"input","id":"hw:1,0","label":"USB Audio RX"}
          ],
          "audioOutputs":[
            {"backend":"pulse","direction":"output","id":"alsa_output.usb","label":"USB Audio TX"}
          ],
          "audioCards":[{
            "hardwareId":"usb:1234:5678:SN42","label":"USB Audio CODEC (SN42)",
            "transport":"usb","complete":true,
            "input":{"backend":"alsa","direction":"input","id":"hw:1,0","label":"USB Audio RX"},
            "output":{"backend":"pulse","direction":"output","id":"alsa_output.usb","label":"USB Audio TX"}
          }],
          "pttMethods":["RIG","DTR","RTS","Parallel","CM108","GPIO","GPION","None"],
          "baudRates":[9600,38400,115200],
          "warnings":[]
        }
        """#.utf8)

        let discovery = try JSONDecoder().decode(RadioLiteHardwareDiscovery.self, from: payload)

        XCTAssertEqual(discovery.hamlibModels.map(\.displayName), ["Icom IC-7300", "Yaesu FT-710"])
        XCTAssertEqual(discovery.serialDevices.first?.path, "/dev/serial/by-id/radio")
        XCTAssertEqual(discovery.audioInputs.first?.endpoint, .init(backend: "alsa", id: "hw:1,0", label: "USB Audio RX"))
        XCTAssertEqual(discovery.audioOutputs.first?.endpoint.backend, "pulse")
        XCTAssertEqual(discovery.audioCards.first?.hardwareId, "usb:1234:5678:SN42")
        XCTAssertTrue(discovery.audioCards.first?.isSelectableUSBCard == true)
        XCTAssertEqual(discovery.pttMethods, RadioLitePTTMethod.allCases)
        XCTAssertEqual(discovery.baudRates, [9_600, 38_400, 115_200])
    }

    func testLegacyHardwareDiscoveryDefaultsMissingAudioCardsToEmpty() throws {
        let payload = Data(#"""
        {
          "hamlibModels":[],"curatedPresets":[],"serialDevices":[],
          "audioInputs":[],"audioOutputs":[],"pttMethods":["RIG"],
          "baudRates":[115200],"warnings":[]
        }
        """#.utf8)

        let discovery = try JSONDecoder().decode(RadioLiteHardwareDiscovery.self, from: payload)

        XCTAssertEqual(discovery.audioCards, [])
    }

    func testAudioRouteRoundTripsAndLegacyProfileStillDecodes() throws {
        let routed = Data(#"""
        {
          "id":"main","name":"IC-7300","hamlibModelId":3073,
          "connection":{"kind":"managed-serial","devicePath":"/dev/ttyUSB0","baudRate":115200},
          "ptt":{"method":"RIG"},
          "audioInput":{"backend":"alsa","id":"hw:1,0"},
          "audioOutput":{"backend":"alsa","id":"hw:1,0"},
          "audioRoute":{"kind":"system-device","hardwareId":"usb:1234:5678:SN42","latency":"stable"},
          "station":{"callsign":"BI1ABC"},"hardwareTxEnabled":false
        }
        """#.utf8)
        let profile = try JSONDecoder().decode(RadioLiteRadioProfile.self, from: routed)

        XCTAssertEqual(
            profile.audioRoute,
            .systemDevice(hardwareId: "usb:1234:5678:SN42", latency: .stable)
        )
        let encoded = try JSONEncoder().encode(profile)
        XCTAssertEqual(try JSONDecoder().decode(RadioLiteRadioProfile.self, from: encoded), profile)

        let legacy = try JSONDecoder().decode(
            RadioLiteRadioProfile.self,
            from: Data(#"""
            {
              "id":"legacy","name":"Legacy","hamlibModelId":1,
              "connection":{"kind":"hamlib-dummy"},
              "audioInput":{"backend":"alsa","id":"synthetic-rx"},
              "audioOutput":{"backend":"alsa","id":"synthetic-tx"},
              "station":{"callsign":"N0CALL"},"hardwareTxEnabled":false
            }
            """#.utf8)
        )
        XCTAssertNil(legacy.audioRoute)
    }

    func testSelectingCompleteUSBCardUpdatesBothEndpointsAndStableRoute() throws {
        let profile = RadioLiteRadioProfile(
            id: "main", name: "IC-7300", hamlibModelId: 3_073,
            connection: .init(kind: "managed-serial", devicePath: "/dev/ttyUSB0", baudRate: 115_200, host: nil, port: nil),
            ptt: .init(method: .rig),
            audioInput: .init(backend: "alsa", id: "old-in", label: nil),
            audioOutput: .init(backend: "alsa", id: "old-out", label: nil),
            station: .init(callsign: "BI1ABC", grid: nil), hardwareTxEnabled: false
        )
        var draft = RadioLiteRadioConfigurationDraft(profile: profile)
        let card = RadioLiteAudioCard(
            hardwareId: "usb:1234:5678:SN42", label: "USB Audio CODEC", transport: "usb", complete: true,
            input: .init(backend: "alsa", direction: "input", id: "hw:3,0", label: "USB RX"),
            output: .init(backend: "alsa", direction: "output", id: "hw:3,0", label: "USB TX")
        )

        XCTAssertTrue(draft.selectAudioCard(card))
        draft.setAudioLatency(.low)
        let saved = try draft.makeProfile()

        XCTAssertEqual(saved.audioInput.id, "hw:3,0")
        XCTAssertEqual(saved.audioOutput.id, "hw:3,0")
        XCTAssertEqual(saved.audioRoute, .systemDevice(hardwareId: card.hardwareId, latency: .low))
    }

    func testPTTMethodsExposeOnlyApplicableAdvancedFields() {
        XCTAssertEqual(RadioLitePTTMethod.rig.label, "电台 CAT")
        XCTAssertFalse(RadioLitePTTMethod.rig.requiresDevicePath)
        XCTAssertFalse(RadioLitePTTMethod.rig.requiresBit)

        XCTAssertTrue(RadioLitePTTMethod.rts.requiresDevicePath)
        XCTAssertFalse(RadioLitePTTMethod.rts.requiresBit)

        XCTAssertTrue(RadioLitePTTMethod.gpio.requiresDevicePath)
        XCTAssertTrue(RadioLitePTTMethod.gpio.requiresBit)
        XCTAssertTrue(RadioLitePTTMethod.gpion.requiresBit)
    }

    func testDraftBuildsNormalizedManagedSerialProfile() throws {
        let original = try JSONDecoder().decode(
            RadioLiteRadioProfile.self,
            from: Data(#"""
            {
              "id":"main","name":"Old","hamlibModelId":1,
              "connection":{"kind":"hamlib-dummy"},
              "ptt":{"method":"None"},
              "audioInput":{"backend":"alsa","id":"synthetic-rx"},
              "audioOutput":{"backend":"alsa","id":"synthetic-tx"},
              "station":{"callsign":"N0CALL","grid":"AA00"},
              "hardwareTxEnabled":false
            }
            """#.utf8)
        )
        var draft = RadioLiteRadioConfigurationDraft(profile: original)
        draft.name = "  Shack Radio  "
        draft.hamlibModelId = 3_073
        draft.connectionKind = .managedSerial
        draft.catDevicePath = "/dev/serial/by-id/icom"
        draft.baudRate = 115_200
        draft.pttMethod = .gpio
        draft.pttDevicePath = "/dev/gpiochip0"
        draft.pttBit = 3
        draft.audioInput = .init(backend: "alsa", id: "hw:1,0", label: "USB RX")
        draft.audioOutput = .init(backend: "pulse", id: "usb-output", label: "USB TX")
        draft.callsign = " bi1abc "
        draft.grid = " om89 "
        draft.hardwareTxEnabled = true

        let profile = try draft.makeProfile()

        XCTAssertEqual(profile.name, "Shack Radio")
        XCTAssertEqual(profile.connection, .init(
            kind: "managed-serial",
            devicePath: "/dev/serial/by-id/icom",
            baudRate: 115_200,
            host: nil,
            port: nil
        ))
        XCTAssertEqual(profile.ptt, .init(method: .gpio, path: "/dev/gpiochip0", bit: 3))
        XCTAssertEqual(profile.station, .init(callsign: "BI1ABC", grid: "OM89"))
        XCTAssertTrue(profile.hardwareTxEnabled)
    }

    func testNetworkRigctldForcesRigManagedPTT() throws {
        let original = RadioLiteRadioProfile(
            id: "main",
            name: "Remote rigctld",
            hamlibModelId: 3_073,
            connection: .init(
                kind: "network-rigctld",
                devicePath: nil,
                baudRate: nil,
                host: "127.0.0.1",
                port: 4_532
            ),
            ptt: .init(method: .rig),
            audioInput: .init(backend: "alsa", id: "hw:1,0", label: nil),
            audioOutput: .init(backend: "alsa", id: "hw:1,0", label: nil),
            station: .init(callsign: "BI1ABC", grid: "OM89"),
            hardwareTxEnabled: true
        )
        var draft = RadioLiteRadioConfigurationDraft(profile: original)
        draft.pttMethod = .dtr
        draft.pttDevicePath = "/dev/ttyUSB9"

        let profile = try draft.makeProfile()

        XCTAssertEqual(profile.ptt, .init(method: .rig))
    }

    func testHardwareTransmitRejectsDisabledPTTBeforePosting() {
        let original = RadioLiteRadioProfile(
            id: "main",
            name: "IC-7300",
            hamlibModelId: 3_073,
            connection: .init(
                kind: "managed-serial",
                devicePath: "/dev/ttyUSB0",
                baudRate: 115_200,
                host: nil,
                port: nil
            ),
            ptt: .init(method: .rig),
            audioInput: .init(backend: "alsa", id: "hw:1,0", label: nil),
            audioOutput: .init(backend: "alsa", id: "hw:1,0", label: nil),
            station: .init(callsign: "BI1ABC", grid: nil),
            hardwareTxEnabled: false
        )
        var draft = RadioLiteRadioConfigurationDraft(profile: original)
        draft.pttMethod = .none
        draft.hardwareTxEnabled = true

        XCTAssertThrowsError(try draft.makeProfile()) { error in
            XCTAssertEqual(error.localizedDescription, "不控制 PTT 时不能启用真实硬件发射")
        }
    }

    func testUpsertRequestSendsExactHardwareConfirmationOnlyWhenEnabled() throws {
        let profile = RadioLiteRadioProfile(
            id: "main",
            name: "IC-7300",
            hamlibModelId: 3_073,
            connection: .init(
                kind: "managed-serial",
                devicePath: "/dev/ttyUSB0",
                baudRate: 115_200,
                host: nil,
                port: nil
            ),
            ptt: .init(method: .rig),
            audioInput: .init(backend: "alsa", id: "hw:1,0", label: nil),
            audioOutput: .init(backend: "alsa", id: "hw:1,0", label: nil),
            station: .init(callsign: "BI1ABC", grid: "OM89"),
            hardwareTxEnabled: true
        )

        let data = try JSONEncoder().encode(
            RadioLiteRadioUpsertRequest(profile: profile, confirmHardwareTransmission: true)
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["hardwareTxConfirmation"] as? String, "main")
        let encodedProfile = try XCTUnwrap(object["profile"] as? [String: Any])
        let encodedPTT = try XCTUnwrap(encodedProfile["ptt"] as? [String: Any])
        XCTAssertEqual(encodedPTT["method"] as? String, "RIG")
    }
}
