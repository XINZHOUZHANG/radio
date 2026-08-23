import XCTest
@testable import TX5DRMobile

final class NativeFeatureModelsTests: XCTestCase {
    func testProfileListDecodesStandardTX5DRShape() throws {
        let data = Data(#"""
        {
          "profiles": [{
            "id": "home",
            "name": "IC-705",
            "description": "WiFi",
            "radio": {"type":"icom-wlan","icomWlan":{"ip":"192.0.2.7","port":50001}},
            "audio": {"inputDeviceName":"ICOM WLAN","outputDeviceName":"ICOM WLAN"},
            "audioLockedToRadio": true,
            "createdAt": 1,
            "updatedAt": 2
          }],
          "activeProfileId": "home"
        }
        """#.utf8)

        let response = try JSONDecoder().decode(ProfileListResponse.self, from: data)

        XCTAssertEqual(response.activeProfileId, "home")
        XCTAssertEqual(response.profiles.first?.radioType, "icom-wlan")
        XCTAssertEqual(response.profiles.first?.endpointSummary, "ICOM WLAN 192.0.2.7")
    }

    func testAssistedQueueDecodesFromOperatorRuntimeJSON() throws {
        let value = try JSONValue.parse(#"""
        {
          "version": 4,
          "activeEntryId": "q1",
          "rows": [{
            "entryId": "q1",
            "callsign": "BG2TEST",
            "order": 0,
            "draggable": false,
            "displayState": "TX2",
            "tone": "active",
            "icon": "radio",
            "lastSnr": -8
          }]
        }
        """#)
        let queue: AssistedQueueSnapshot? = value.decoded()

        XCTAssertEqual(queue?.version, 4)
        XCTAssertEqual(queue?.activeEntryId, "q1")
        XCTAssertEqual(queue?.rows.first?.callsign, "BG2TEST")
    }

    func testRadioPowerSupportDecodesSupportedStates() throws {
        let data = Data(#"""
        {
          "profileId":"home",
          "canPowerOn":true,
          "canPowerOff":true,
          "supportedStates":["operate","standby","off"],
          "rigInfo":{"mfgName":"ICOM","modelName":"IC-705"}
        }
        """#.utf8)
        let support = try JSONDecoder().decode(RadioPowerSupportInfo.self, from: data)

        XCTAssertTrue(support.canPowerOn)
        XCTAssertEqual(support.supportedStates, [.operate, .standby, .off])
        XCTAssertEqual(support.rigInfo?.modelName, "IC-705")
    }

    func testVoiceKeyerPanelDecodesStandardTX5DRShape() throws {
        let data = Data(#"""
        {
          "success": true,
          "panel": {
            "callsign": "BG2TEST",
            "slotCount": 3,
            "maxSlotCount": 12,
            "slots": [{
              "id": "voice-1",
              "index": 1,
              "label": "CQ",
              "hasAudio": true,
              "durationMs": 2450,
              "updatedAt": 1720000000000,
              "repeatEnabled": true,
              "repeatIntervalSec": 8
            }]
          }
        }
        """#.utf8)

        let response = try JSONDecoder().decode(VoiceKeyerPanelResponse.self, from: data)

        XCTAssertEqual(response.panel.callsign, "BG2TEST")
        XCTAssertEqual(response.panel.slots.first?.durationMs, 2450)
        XCTAssertEqual(response.panel.slots.first?.repeatIntervalSec, 8)
        XCTAssertTrue(response.panel.slots.first?.hasAudio == true)
    }

    func testCWKeyerConfigAndMessagePanelDecodeStandardTX5DRShapes() throws {
        let configData = Data(#"""
        {
          "success": true,
          "config": {
            "backend": "cat",
            "keyPort": "",
            "keyMethod": "dtr",
            "keyActiveLevel": "high",
            "wpm": 24
          }
        }
        """#.utf8)
        let panelData = Data(#"""
        {
          "success": true,
          "panel": {
            "callsign": "BG2TEST",
            "slotCount": 3,
            "maxSlotCount": 12,
            "slots": [{
              "id": "cw-1",
              "index": 1,
              "label": "CQ",
              "text": "CQ CQ DE {MYCALL}",
              "repeatEnabled": false,
              "repeatIntervalSec": 10
            }]
          }
        }
        """#.utf8)

        let config = try JSONDecoder().decode(CWKeyerConfigResponse.self, from: configData)
        let panel = try JSONDecoder().decode(CWMessagePanelResponse.self, from: panelData)

        XCTAssertEqual(config.config.backend, .cat)
        XCTAssertEqual(config.config.wpm, 24)
        XCTAssertEqual(panel.panel.slots.first?.text, "CQ CQ DE {MYCALL}")
    }
}
