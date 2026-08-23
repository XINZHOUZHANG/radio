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

    func testCWDecoderStatusDecodesStructuredTranscriptConfiguration() throws {
        let data = Data(#"""
        {
          "success": true,
          "config": {
            "enabled": true,
            "backend": "deepcw-onnx",
            "runtimeBackend": "cpu",
            "modelSize": "tiny",
            "language": "en",
            "mode": "streaming",
            "targetFreqHz": 800,
            "filterWidthHz": 500,
            "windowSeconds": 12,
            "decodeIntervalMs": 1000,
            "muteWhileTransmitting": true,
            "workerCount": 1,
            "minCommitChars": 1,
            "commitStability": 2,
            "maxPendingAgeMs": 4000
          },
          "status": {
            "enabled": true,
            "state": "listening",
            "config": {
              "enabled": true,
              "backend": "deepcw-onnx",
              "runtimeBackend": "cpu",
              "modelSize": "tiny",
              "language": "en",
              "mode": "streaming",
              "targetFreqHz": 800,
              "filterWidthHz": 500,
              "windowSeconds": 12,
              "decodeIntervalMs": 1000,
              "muteWhileTransmitting": true,
              "workerCount": 1,
              "minCommitChars": 1,
              "commitStability": 2,
              "maxPendingAgeMs": 4000
            },
            "muted": false,
            "active": true,
            "running": true,
            "updatedAt": 1720000000000
          }
        }
        """#.utf8)

        let response = try JSONDecoder().decode(CWDecoderConfigResponse.self, from: data)

        XCTAssertEqual(response.config.backend, .deepCWONNX)
        XCTAssertEqual(response.config.filterWidthHz, 500)
        XCTAssertEqual(response.status.state, .listening)
        XCTAssertTrue(response.status.isRunning)
    }

    func testSpectrumCapabilitiesAndSessionStateDecodeTX5DRContract() throws {
        let capabilitiesData = Data(#"""
        {
          "profileId": "home",
          "defaultKind": "openwebrx-sdr",
          "sources": [
            {
              "kind": "audio",
              "supported": true,
              "available": true,
              "defaultSelected": false,
              "sourceBinCount": 2048,
              "displayBinCount": 1024,
              "supportsWaterfall": true,
              "frequencyRangeMode": "baseband"
            },
            {
              "kind": "radio-sdr",
              "supported": true,
              "available": true,
              "defaultSelected": false,
              "sourceBinCount": null,
              "displayBinCount": 1024,
              "supportsWaterfall": true,
              "frequencyRangeMode": "absolute"
            },
            {
              "kind": "openwebrx-sdr",
              "supported": true,
              "available": true,
              "defaultSelected": true,
              "displayBinCount": 1024,
              "supportsWaterfall": true,
              "frequencyRangeMode": "absolute"
            }
          ]
        }
        """#.utf8)
        let sessionData = Data(#"""
        {
          "kind": "openwebrx-sdr",
          "sourceMode": "detail",
          "frequencyRangeMode": "absolute-windowed",
          "displayRange": {"min": 14073000, "max": 14077000},
          "centerFrequency": 14075000,
          "currentRadioFrequency": 14074000,
          "standardFrequencyHz": 14074000,
          "edgeLowHz": 14073000,
          "edgeHighHz": 14077000,
          "spanHz": 4000,
          "voice": {
            "radioMode": null,
            "bandwidthLabel": null,
            "occupiedBandwidthHz": null,
            "offsetModel": null
          },
          "interaction": {
            "showTxMarkers": true,
            "showRxMarkers": true,
            "canDragTx": true,
            "canRightClickSetFrequency": true,
            "canDoubleClickSetFrequency": true,
            "canDragFrequency": true,
            "frequencyGestureTarget": "radio-frequency",
            "frequencyStepHz": 10,
            "presetMarkers": [{
              "id": "ft8",
              "frequency": 14074000,
              "label": "FT8",
              "description": "20 m",
              "clickable": true
            }],
            "canDragVoiceOverlay": false,
            "showVoiceOverlay": false,
            "canLocalViewportZoom": true,
            "canLocalViewportPan": true,
            "supportsManualRange": true,
            "supportsAutoRange": false,
            "defaultRangeMode": "manual"
          },
          "controls": [
            {
              "id": "openwebrx-detail-toggle",
              "action": "toggle",
              "kind": "server",
              "visible": true,
              "enabled": true,
              "active": true,
              "pending": false
            },
            {
              "id": "viewport-zoom",
              "action": "in",
              "kind": "local",
              "visible": true,
              "enabled": true,
              "active": false,
              "pending": false
            }
          ]
        }
        """#.utf8)

        let capabilities = try JSONDecoder().decode(SpectrumCapabilities.self, from: capabilitiesData)
        let session = try JSONDecoder().decode(SpectrumSessionState.self, from: sessionData)

        XCTAssertEqual(capabilities.defaultKind, .openWebRXSDR)
        XCTAssertEqual(capabilities.sources.count, 3)
        XCTAssertEqual(capabilities.sources[1].frequencyRangeMode, .absolute)
        XCTAssertEqual(session.sourceMode, .detail)
        XCTAssertEqual(session.frequencyRangeMode, .absoluteWindowed)
        XCTAssertEqual(session.interaction.frequencyStepHz, 10)
        XCTAssertEqual(session.controls.first?.id, .openWebRXDetailToggle)
        XCTAssertEqual(session.controls.last?.kind, .local)
    }

    func testSpectrumFrameDecodesScaledLittleEndianBins() throws {
        let data = Data(#"""
        {
          "timestamp": 1720000000000,
          "kind": "audio",
          "frequencyRange": {"min": 0, "max": 3000},
          "binaryData": {
            "data": "GPwAAOgD",
            "format": {"type": "int16", "length": 3, "scale": 0.1, "offset": -20}
          },
          "meta": {
            "sourceBinCount": 3,
            "displayBinCount": 3,
            "spanHz": 3000,
            "profileId": "home"
          }
        }
        """#.utf8)

        let frame = try JSONDecoder().decode(SpectrumFrame.self, from: data)

        XCTAssertEqual(frame.kind, .audio)
        XCTAssertEqual(frame.meta?.displayBinCount, 3)
        XCTAssertEqual(frame.normalizedBins, [-120, -20, 80])
    }

    func testSpectrumSourceSelectionHonorsPreferenceThenPriority() throws {
        let data = Data(#"""
        {
          "profileId": "home",
          "defaultKind": "audio",
          "sources": [
            {"kind":"audio","supported":true,"available":true,"defaultSelected":true,"displayBinCount":1024,"supportsWaterfall":true,"frequencyRangeMode":"baseband"},
            {"kind":"radio-sdr","supported":true,"available":true,"defaultSelected":false,"displayBinCount":1024,"supportsWaterfall":true,"frequencyRangeMode":"absolute"},
            {"kind":"openwebrx-sdr","supported":true,"available":false,"defaultSelected":false,"reason":"openwebrx_disconnected","displayBinCount":1024,"supportsWaterfall":true,"frequencyRangeMode":"absolute"}
          ]
        }
        """#.utf8)
        let capabilities = try JSONDecoder().decode(SpectrumCapabilities.self, from: data)

        XCTAssertEqual(SpectrumSourceSelector.pick(capabilities: capabilities, preferred: .audio), .audio)
        XCTAssertEqual(SpectrumSourceSelector.pick(capabilities: capabilities, preferred: nil), .radioSDR)
        XCTAssertEqual(SpectrumSourceSelector.pick(capabilities: capabilities, preferred: .openWebRXSDR), .radioSDR)
    }

    func testSpectrumHistoryResetsForChangedStreamAndHonorsLimit() throws {
        func frame(timestamp: Double, kind: String = "audio", min: Double = 0) throws -> SpectrumFrame {
            let json = #"""
            {
              "timestamp": \#(timestamp),
              "kind": "\#(kind)",
              "frequencyRange": {"min": \#(min), "max": \#(min + 3000)},
              "binaryData": {"data":"AQACAAMA","format":{"type":"int16","length":3}},
              "meta": {"sourceBinCount":3,"displayBinCount":3}
            }
            """#
            return try JSONDecoder().decode(SpectrumFrame.self, from: Data(json.utf8))
        }

        var history = SpectrumHistoryBuffer(maxRows: 2)
        history.append(frame: try frame(timestamp: 1))
        history.append(frame: try frame(timestamp: 2))
        history.append(frame: try frame(timestamp: 3))

        XCTAssertEqual(history.rows.map(\.timestamp), [2, 3])
        XCTAssertEqual(history.latestBins, [1, 2, 3])

        history.append(frame: try frame(timestamp: 4, min: 100))
        XCTAssertEqual(history.rows.map(\.timestamp), [4])
        XCTAssertEqual(history.frequencyRange?.min, 100)

        history.append(frame: try frame(timestamp: 5, kind: "radio-sdr", min: 100))
        XCTAssertEqual(history.rows.map(\.timestamp), [5])
        XCTAssertEqual(history.kind, .radioSDR)
    }
}
