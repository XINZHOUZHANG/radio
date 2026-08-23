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
}
