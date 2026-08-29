import XCTest
@testable import TX5DRMobile

final class SystemFeatureModelsTests: XCTestCase {
    func testClockAndNTPModelsDecodeCurrentTX5DRContract() throws {
        let clockData = Data(#"""
        {
          "appliedOffsetMs": 12.75,
          "indicatorState": "warn",
          "measuredOffsetMs": 14.25,
          "lastSyncTime": 1787540400000,
          "syncState": "synced",
          "serverUsed": "time.cloudflare.com",
          "errorMessage": null,
          "autoApplyOffset": true
        }
        """#.utf8)
        let settingsData = Data(#"""
        {
          "servers": ["time.cloudflare.com", "pool.ntp.org"],
          "defaultServers": ["pool.ntp.org"]
        }
        """#.utf8)

        let clock = try JSONDecoder().decode(ClockStatusDetail.self, from: clockData)
        let settings = try JSONDecoder().decode(NTPServerListSettings.self, from: settingsData)

        XCTAssertEqual(clock.syncState, .synced)
        XCTAssertEqual(clock.indicatorState, .warn)
        XCTAssertEqual(clock.appliedOffsetMs, 12.75)
        XCTAssertTrue(clock.autoApplyOffset)
        XCTAssertEqual(settings.servers.first, "time.cloudflare.com")
        XCTAssertEqual(settings.defaultServers, ["pool.ntp.org"])
    }

    func testCPUProfileStatusDecodesGuidedCaptureAndEnvironmentStates() throws {
        let runningData = Data(#"""
        {
          "state": "running",
          "source": "guided",
          "distribution": "linux-service",
          "outputDir": "/var/lib/tx5dr/profiles",
          "hostOutputDirHint": "/opt/tx5dr/profiles",
          "captureId": "capture-1",
          "requestedAt": 1787540400000,
          "startedAt": 1787540460000,
          "completedAt": null,
          "profilePath": null,
          "hostProfilePathHint": null,
          "recommendedStartAction": "sudo systemctl restart tx5dr",
          "recommendedFinishAction": "sudo systemctl restart tx5dr"
        }
        """#.utf8)
        let overrideData = Data(#"""
        {
          "state": "env-override",
          "source": "environment",
          "distribution": "docker",
          "outputDir": "/profiles",
          "hostOutputDirHint": null,
          "captureId": null,
          "requestedAt": null,
          "startedAt": null,
          "completedAt": null,
          "profilePath": null,
          "hostProfilePathHint": null,
          "recommendedStartAction": "docker restart tx5dr",
          "recommendedFinishAction": "docker restart tx5dr"
        }
        """#.utf8)

        let running = try JSONDecoder().decode(ServerCPUProfileStatus.self, from: runningData)
        let override = try JSONDecoder().decode(ServerCPUProfileStatus.self, from: overrideData)

        XCTAssertEqual(running.state, .running)
        XCTAssertEqual(running.distribution, "linux-service")
        XCTAssertEqual(running.captureId, "capture-1")
        XCTAssertEqual(override.state, .environmentOverride)
    }

    func testDiagnosticSourcesReceiptAndUploadRequestUseServerFieldNames() throws {
        let sourcesData = Data(#"""
        {
          "sources": [{
            "id": "server",
            "fileName": "tx5dr.log",
            "availableFromMs": 1787536800000,
            "availableToMs": 1787540400000,
            "fileCount": 3,
            "totalBytes": 4096
          }],
          "limits": {"maxRangeMs": 604800000}
        }
        """#.utf8)
        let receiptData = Data(#"""
        {
          "uploadId": "3ac3944d-f99e-47cb-a014-d70245639afc",
          "lineCount": 142,
          "retainedUntil": "2026-09-01T00:00:00.000Z"
        }
        """#.utf8)

        let sources = try JSONDecoder().decode(DiagnosticLogSourcesResponse.self, from: sourcesData)
        let receipt = try JSONDecoder().decode(DiagnosticUploadReceipt.self, from: receiptData)
        let request = DiagnosticUploadRequest(
            sourceId: "server",
            fromMs: 1_787_536_800_000,
            toMs: 1_787_540_400_000,
            feedback: nil
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )

        XCTAssertEqual(sources.sources.first?.fileName, "tx5dr.log")
        XCTAssertEqual(sources.sources.first?.totalBytes, 4096)
        XCTAssertEqual(receipt.lineCount, 142)
        XCTAssertEqual(receipt.retainedUntil.stringValue, "2026-09-01T00:00:00.000Z")
        XCTAssertEqual(object["sourceId"] as? String, "server")
        XCTAssertNotNil(object["fromMs"])
        XCTAssertNotNil(object["toMs"])
        XCTAssertNil(object["feedback"])
    }
}
