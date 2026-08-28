import XCTest
@testable import RadioLite

final class RadioLiteModelsTests: XCTestCase {
    func testDataModesUseFriendlyLabelsAndCanonicalHamlibWireValues() {
        XCTAssertEqual(RadioLiteRigMode.dataUpper.rawValue, "DATA-U")
        XCTAssertEqual(RadioLiteRigMode.dataUpper.hamlibMode, "PKTUSB")
        XCTAssertTrue(RadioLiteRigMode.dataUpper.matches(readback: "PKTUSB"))
        XCTAssertTrue(RadioLiteRigMode.dataUpper.matches(readback: "DIGU"))
        XCTAssertFalse(RadioLiteRigMode.dataUpper.matches(readback: "PKTLSB"))
        XCTAssertEqual(RadioLiteRigMode.dataLower.rawValue, "DATA-L")
        XCTAssertEqual(RadioLiteRigMode.dataLower.hamlibMode, "PKTLSB")
        XCTAssertTrue(RadioLiteRigMode.dataLower.matches(readback: "PKTLSB"))
    }

    func testModeRejectionUsesANonModalLocalizedExplanation() {
        XCTAssertEqual(
            RadioLiteRigMode.failureNotice(
                code: "rig_mode_rejected",
                requested: .dataUpper
            ),
            "当前电台不支持 DATA-U；已保留原模式。FT8 通常使用 DATA-U（Hamlib PKTUSB）。"
        )
        XCTAssertNotNil(RadioLiteRigMode.failureNotice(code: "hamlib_report", requested: .usb))
        XCTAssertNil(RadioLiteRigMode.failureNotice(code: "invalid_control_lease", requested: .usb))
    }

    func testDeviceAndBrowserCredentialsRoundTripWithoutLosingSecrets() throws {
        let credentials: [RadioLiteCredential] = [
            .device(.init(
                deviceId: "device-1",
                accessToken: "access-token",
                accessExpiresAtMs: 1_000,
                refreshToken: "refresh-token",
                refreshExpiresAtMs: 2_000
            )),
            .browser(.init(sessionToken: "session-token", csrfToken: "csrf-token", createdAtMs: 3_000)),
        ]

        for credential in credentials {
            let data = try JSONEncoder().encode(credential)
            XCTAssertEqual(try JSONDecoder().decode(RadioLiteCredential.self, from: data), credential)
        }
    }

    func testDecodesAuthenticationWelcomeAndRadioProfile() throws {
        let payload = Data(#"""
        {
          "t":"auth.ok",
          "protocolVersion":1,
          "channel":"control",
          "principal":{"userId":"user-1","deviceId":"device-1","role":"operator","canTransmit":true},
          "radios":[{
            "id":"main","name":"FT-710","hamlibModelId":1049,
            "connection":{"kind":"network-rigctld","host":"127.0.0.1","port":4532},
            "audioInput":{"backend":"alsa","id":"hw:1,0"},
            "audioOutput":{"backend":"alsa","id":"hw:1,0"},
            "station":{"callsign":"BI1ABC","grid":"OM89"},
            "hardwareTxEnabled":true
          }]
        }
        """#.utf8)

        let welcome = try JSONDecoder().decode(RadioLiteAuthWelcome.self, from: payload)
        XCTAssertEqual(welcome.channel, "control")
        XCTAssertEqual(welcome.principal.role, .operator)
        XCTAssertEqual(welcome.radios.first?.connection.port, 4532)
        XCTAssertEqual(welcome.radios.first?.station.callsign, "BI1ABC")
    }

    func testDecodesStableDigitalSnapshotWithNullableQSO() throws {
        let payload = Data(#"""
        {
          "t":"digital.snapshot","radioId":"main",
          "decodes":{"radioId":"main","revision":1,"batches":[{
            "radioId":"main","mode":"FT8","slotStartMs":1000,"slotEndMs":16000,
            "receivedAtMs":16100,"revision":1,"decodes":[{
              "id":"decode-1","message":"CQ JA1ABC PM95","snrDb":-12,
              "deltaTimeSeconds":0.2,"audioFrequencyHz":1300,"confidence":0.95
            }]
          }]},
          "queue":{"radioId":"main","revision":0,"activeId":null,"entries":[]},
          "qso":null
        }
        """#.utf8)

        let snapshot = try JSONDecoder().decode(RadioLiteDigitalSnapshot.self, from: payload)
        XCTAssertNil(snapshot.qso)
        XCTAssertEqual(snapshot.decodes.batches.first?.decodes.first?.id, "decode-1")
    }

    func testRigStateDecodesInternalTunerCapabilityAndRemainsCompatibleWithOldServers() throws {
        let capable = try JSONDecoder().decode(
            RadioLiteRigState.self,
            from: Data(#"{"frequencyHz":14074000,"mode":"PKTUSB","passbandHz":3000,"ptt":false,"supportsInternalTuner":true}"#.utf8)
        )
        let legacy = try JSONDecoder().decode(
            RadioLiteRigState.self,
            from: Data(#"{"frequencyHz":14074000,"mode":"PKTUSB","passbandHz":3000,"ptt":false}"#.utf8)
        )

        XCTAssertEqual(capable.supportsInternalTuner, true)
        XCTAssertNil(legacy.supportsInternalTuner)
    }
}
