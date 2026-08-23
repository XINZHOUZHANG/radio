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

    func testOpenWebRXStationAndListenStatusDecodeTX5DRContract() throws {
        let stationsData = Data(#"""
        {
          "stations": [{
            "id": "sdr-1",
            "name": "Public SDR",
            "url": "wss://sdr.example.test/ws/",
            "description": "20 metre receiver",
            "profileCoverages": [{
              "profileId": "rtl|20m",
              "profileName": "20 m",
              "centerFreq": 14100000,
              "sampRate": 2400000,
              "lastUpdated": 1720000000000
            }]
          }]
        }
        """#.utf8)
        let listenData = Data(#"""
        {
          "success": true,
          "status": {
            "previewSessionId": "preview-1",
            "stationId": "sdr-1",
            "connected": true,
            "serverVersion": "1.2.3",
            "profiles": [{"id":"rtl|20m","name":"20 m"}],
            "currentProfileId": "rtl|20m",
            "centerFreq": 14100000,
            "sampleRate": 2400000,
            "frequency": 14074000,
            "modulation": "usb",
            "smeterDb": -61.5,
            "isListening": true
          }
        }
        """#.utf8)

        let stations = try JSONDecoder().decode(OpenWebRXStationListResponse.self, from: stationsData)
        let listen = try JSONDecoder().decode(OpenWebRXListenStartResponse.self, from: listenData)

        XCTAssertEqual(stations.stations.first?.profileCoverages?.first?.sampRate, 2_400_000)
        XCTAssertEqual(listen.status.previewSessionId, "preview-1")
        XCTAssertEqual(listen.status.currentProfileId, "rtl|20m")
        XCTAssertEqual(listen.status.smeterDb, -61.5)
        XCTAssertTrue(listen.status.isListening)
    }

    func testOpenWebRXProfileSelectionEventsDecodeTX5DRContract() throws {
        let requestData = Data(#"""
        {
          "requestId": "request-1",
          "targetFrequency": 14074000,
          "profiles": [
            {"id":"rtl|20m","name":"20 m"},
            {"id":"rtl|40m","name":"40 m"}
          ],
          "currentProfileId": "rtl|40m"
        }
        """#.utf8)
        let resultData = Data(#"""
        {
          "requestId": "request-1",
          "success": false,
          "profileId": "rtl|40m",
          "profileName": "40 m",
          "centerFreq": 7100000,
          "sampRate": 2400000,
          "error": "target_out_of_range"
        }
        """#.utf8)

        let request = try JSONDecoder().decode(OpenWebRXProfileSelectRequest.self, from: requestData)
        let result = try JSONDecoder().decode(OpenWebRXProfileVerifyResult.self, from: resultData)

        XCTAssertEqual(request.id, "request-1")
        XCTAssertEqual(request.profiles.count, 2)
        XCTAssertEqual(result.profileName, "40 m")
        XCTAssertFalse(result.success)
    }

    func testPSKReporterConfigAndStatusDecodeTX5DRContract() throws {
        let configData = Data(#"""
        {
          "success": true,
          "data": {
            "enabled": true,
            "receiverCallsign": "BG2TEST",
            "receiverLocator": "PN35AA",
            "decodingSoftware": "TX-5DR",
            "antennaInformation": "EFHW",
            "reportIntervalSeconds": 30,
            "useTestServer": false,
            "stats": {
              "lastReportTime": 1720000000000,
              "todayReportCount": 12,
              "totalReportCount": 345,
              "lastError": null,
              "consecutiveFailures": 0
            }
          }
        }
        """#.utf8)
        let statusData = Data(#"""
        {
          "success": true,
          "data": {
            "enabled": true,
            "configValid": true,
            "activeCallsign": "BG2TEST",
            "activeLocator": "PN35AA",
            "pendingSpots": 4,
            "lastReportTime": 1720000000000,
            "nextReportIn": 18,
            "isReporting": false,
            "lastError": null
          }
        }
        """#.utf8)

        let config = try JSONDecoder().decode(DataResponse<PSKReporterConfig>.self, from: configData).data
        let status = try JSONDecoder().decode(DataResponse<PSKReporterStatus>.self, from: statusData).data

        XCTAssertEqual(config.stats.todayReportCount, 12)
        XCTAssertEqual(config.reportIntervalSeconds, 30)
        XCTAssertEqual(status.pendingSpots, 4)
        XCTAssertEqual(status.nextReportIn, 18)
        XCTAssertTrue(status.configValid)
    }

    func testPSKReporterUpdateSendsOnlyEditableContractFields() throws {
        let update = PSKReporterConfigUpdate(
            enabled: true,
            receiverCallsign: "BG2TEST",
            receiverLocator: "PN35AA",
            antennaInformation: "EFHW",
            reportIntervalSeconds: 15,
            useTestServer: true
        )
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(update)) as? [String: Any]

        XCTAssertEqual(object?["enabled"] as? Bool, true)
        XCTAssertEqual(object?["reportIntervalSeconds"] as? Int, 15)
        XCTAssertEqual(object?["useTestServer"] as? Bool, true)
        XCTAssertNil(object?["stats"])
        XCTAssertNil(object?["decodingSoftware"])
    }

    func testRigctldStatusDecodesListenerAndClients() throws {
        let data = Data(#"""
        {
          "config": {
            "enabled": true,
            "bindAddress": "0.0.0.0",
            "port": 4532,
            "readOnly": true
          },
          "running": true,
          "address": {"host": "0.0.0.0", "port": 4532},
          "clients": [{
            "id": 7,
            "peer": "100.64.0.8:51822",
            "connectedAt": 1720000000000,
            "lastCommand": "\\get_freq",
            "lastCommandAt": 1720000005000
          }]
        }
        """#.utf8)

        let status = try JSONDecoder().decode(RigctldStatus.self, from: data)

        XCTAssertTrue(status.running)
        XCTAssertTrue(status.config.readOnly)
        XCTAssertEqual(status.address?.port, 4532)
        XCTAssertEqual(status.clients.first?.id, 7)
        XCTAssertEqual(status.clients.first?.lastCommand, "\\get_freq")
    }

    func testRigctldWriteControlConfigurationEncodesContractShape() throws {
        let config = RigctldBridgeConfig(
            enabled: true,
            bindAddress: "127.0.0.1",
            port: 4532,
            readOnly: false
        )
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any]

        XCTAssertEqual(object?["enabled"] as? Bool, true)
        XCTAssertEqual(object?["bindAddress"] as? String, "127.0.0.1")
        XCTAssertEqual(object?["port"] as? Int, 4532)
        XCTAssertEqual(object?["readOnly"] as? Bool, false)
    }

    func testTunerControlStateUsesCapabilityValueStatusAndSWR() {
        let tunerSwitch = capability(
            id: "tuner_switch",
            value: .bool(true),
            meta: ["status": .string("tuning"), "swr": .number(1.42)]
        )
        let tunerTune = capability(id: "tuner_tune", value: .null)
        let state = TunerControlState(
            switchState: tunerSwitch,
            tuneState: tunerTune,
            ptt: idlePTT,
            tuneTone: idleTuneTone,
            socketReady: true,
            nowMilliseconds: 10_000
        )

        XCTAssertTrue(state.builtInSupported)
        XCTAssertTrue(state.tunerEnabled)
        XCTAssertTrue(state.isTuning)
        XCTAssertEqual(state.swr, 1.42)
        XCTAssertEqual(state.swrQuality, .good)
        XCTAssertTrue(state.canToggleSwitch)
        XCTAssertFalse(state.canStartManualTune)
        XCTAssertEqual(state.builtInStatusText, "正在调谐")
    }

    func testTunerControlStateRequiresEnabledAvailableCapabilitiesForManualTune() {
        let tunerSwitch = capability(
            id: "tuner_switch",
            availability: "unavailable",
            lastError: "ATU not connected",
            value: .bool(false)
        )
        let tunerTune = capability(id: "tuner_tune", value: .null)
        let state = TunerControlState(
            switchState: tunerSwitch,
            tuneState: tunerTune,
            ptt: idlePTT,
            tuneTone: idleTuneTone,
            socketReady: true,
            nowMilliseconds: 10_000
        )

        XCTAssertFalse(state.canToggleSwitch)
        XCTAssertFalse(state.canStartManualTune)
        XCTAssertEqual(state.unavailableMessage, "天调未连接或当前不可用")
        XCTAssertEqual(state.lastError, "ATU not connected")
    }

    func testTunerControlStateInterlocksExternalToneWithOtherPTT() {
        let busyPTT = PTTStatus(
            isTransmitting: true,
            operatorIds: ["operator-1"],
            phase: "transmitting",
            frameId: nil,
            source: "ft8"
        )
        let state = TunerControlState(
            switchState: nil,
            tuneState: nil,
            ptt: busyPTT,
            tuneTone: idleTuneTone,
            socketReady: true,
            nowMilliseconds: 10_000
        )

        XCTAssertTrue(state.tuneToneBusy)
        XCTAssertFalse(state.canToggleTuneTone)
        XCTAssertFalse(state.builtInSupported)
        XCTAssertFalse(state.hasCapabilitySnapshot)
    }

    func testTunerControlStateAllowsStoppingActiveToneAndTracksTimeout() {
        let activeTone = TuneToneStatus(
            active: true,
            toneHz: 1_000,
            startedAt: 5_000,
            maxDurationMs: 30_000,
            error: nil
        )
        let transmitting = PTTStatus(
            isTransmitting: true,
            operatorIds: [],
            phase: "transmitting",
            frameId: nil,
            source: "tune-tone"
        )
        let state = TunerControlState(
            switchState: nil,
            tuneState: nil,
            ptt: transmitting,
            tuneTone: activeTone,
            socketReady: true,
            nowMilliseconds: 17_400
        )

        XCTAssertTrue(state.tuneToneActive)
        XCTAssertFalse(state.tuneToneBusy)
        XCTAssertTrue(state.canToggleTuneTone)
        XCTAssertEqual(state.tuneToneElapsedSeconds, 12)
        XCTAssertEqual(state.tuneToneRemainingSeconds, 18)
    }

    func testAudioGainParsesTX5DREventAndSystemStatusShapes() throws {
        let event = JSONValue.object([
            "gain": .number(0.316_227_766),
            "gainDb": .number(-10),
        ])
        let systemStatus = JSONValue.object([
            "volumeGain": .number(0.1),
        ])

        XCTAssertEqual(try XCTUnwrap(AudioGain.decibels(from: event)), -10, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(AudioGain.decibels(from: systemStatus)), -20, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(AudioGain.decibels(from: .number(1))), 0, accuracy: 0.001)
        XCTAssertNil(AudioGain.decibels(from: .number(-1)))
    }

    func testAudioMonitorGateFollowsVoicePTTAndSquelch() {
        let closedSquelch = SquelchStatus(
            supported: true,
            open: false,
            muted: true,
            source: "hamlib-dcd",
            updatedAt: 1
        )
        let squelchGate = AudioMonitorGateState(
            engineMode: "VOICE",
            ptt: idlePTT,
            localVoicePTTHeld: false,
            squelch: closedSquelch,
            voiceLock: nil
        )
        let transmitGate = AudioMonitorGateState(
            engineMode: "VOICE",
            ptt: idlePTT,
            localVoicePTTHeld: true,
            squelch: closedSquelch,
            voiceLock: nil
        )

        XCTAssertEqual(squelchGate.muteReason, .squelchClosed)
        XCTAssertTrue(squelchGate.shouldMute)
        XCTAssertEqual(transmitGate.muteReason, .transmitting)
    }

    func testAudioMonitorGateKeepsVoiceKeyerMonitorAndIgnoresDigitalSquelch() {
        let transmitting = PTTStatus(
            isTransmitting: true,
            operatorIds: [],
            phase: "transmitting",
            frameId: nil,
            source: "voice-keyer"
        )
        let closedSquelch = SquelchStatus(
            supported: true,
            open: false,
            muted: true,
            source: "hamlib-dcd",
            updatedAt: 1
        )
        let keyerLock = JSONValue.object([
            "locked": .bool(true),
            "lockedBy": .string("voice-keyer:BG2TEST"),
        ])
        let keyerGate = AudioMonitorGateState(
            engineMode: "VOICE",
            ptt: transmitting,
            localVoicePTTHeld: false,
            squelch: closedSquelch,
            voiceLock: keyerLock
        )
        let digitalGate = AudioMonitorGateState(
            engineMode: "FT8",
            ptt: idlePTT,
            localVoicePTTHeld: false,
            squelch: closedSquelch,
            voiceLock: nil
        )

        XCTAssertFalse(keyerGate.shouldMute)
        XCTAssertFalse(digitalGate.shouldMute)
    }

    func testSquelchAndTransmissionInterruptionDecodeTX5DRContract() throws {
        let squelchData = Data(#"""
        {"supported":true,"open":false,"muted":true,"source":"hamlib-dcd","updatedAt":1720000000000}
        """#.utf8)
        let interruptionData = Data(#"""
        {"reason":"serial_lost","message":"Radio disconnected","recommendation":"Check the CAT cable"}
        """#.utf8)

        let squelch = try JSONDecoder().decode(SquelchStatus.self, from: squelchData)
        let interruption = try JSONDecoder().decode(RadioTransmissionInterruption.self, from: interruptionData)

        XCTAssertFalse(squelch.open == true)
        XCTAssertTrue(squelch.muted)
        XCTAssertEqual(interruption.reason, "serial_lost")
        XCTAssertEqual(interruption.recommendation, "Check the CAT cable")
    }

    private var idlePTT: PTTStatus {
        PTTStatus(
            isTransmitting: false,
            operatorIds: [],
            phase: "idle",
            frameId: nil,
            source: nil
        )
    }

    private var idleTuneTone: TuneToneStatus {
        TuneToneStatus(
            active: false,
            toneHz: nil,
            startedAt: nil,
            maxDurationMs: 30_000,
            error: nil
        )
    }

    private func capability(
        id: String,
        supported: Bool = true,
        availability: String = "available",
        lastError: String? = nil,
        value: JSONValue,
        meta: [String: JSONValue]? = nil
    ) -> CapabilityState {
        CapabilityState(
            id: id,
            supported: supported,
            availability: availability,
            availabilityReason: nil,
            lastError: lastError,
            value: value,
            meta: meta,
            updatedAt: 1
        )
    }
}
