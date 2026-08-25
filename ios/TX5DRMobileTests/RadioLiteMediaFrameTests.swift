import XCTest
@testable import TX5DRMobile

final class RadioLiteMediaFrameTests: XCTestCase {
    func testAudioFrameMatchesRadioLiteNetworkByteOrder() throws {
        let value = RadioLiteMediaFrame(
            kind: .audioUplink,
            flags: 3,
            radioSlot: 7,
            sequence: 0x0102_0304,
            timestampMicroseconds: 0x1112_1314_1516_1718,
            payload: Data([0xF8, 0xFF, 0xFE])
        )

        let encoded = try RadioLiteMediaFrameCodec.encode(value)
        XCTAssertEqual(Array(encoded.prefix(16)), [
            1, 2, 3, 7,
            1, 2, 3, 4,
            0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
        ])
        XCTAssertEqual(try RadioLiteMediaFrameCodec.decode(encoded), value)
    }

    func testDecodesCompactSpectrumPayload() throws {
        var payload = Data([
            0, 0, 0, 0, 0, 0, 0x36, 0xFA,
            0, 0, 0x0B, 0xB8,
            0xFC, 0x18,
            0, 16,
        ])
        let bins = (0..<16).map(UInt8.init)
        payload.append(contentsOf: bins)

        let spectrum = try RadioLiteMediaFrameCodec.decodeSpectrum(payload)
        XCTAssertEqual(spectrum.centerFrequencyHz, 14_074)
        XCTAssertEqual(spectrum.spanHz, 3_000)
        XCTAssertEqual(spectrum.noiseFloorTenthsDBm, -1_000)
        XCTAssertEqual(spectrum.bins, bins)
    }

    func testRejectsTruncatedAndMismatchedFrames() {
        XCTAssertThrowsError(try RadioLiteMediaFrameCodec.decode(Data(repeating: 0, count: 15)))

        var payload = Data(repeating: 0, count: 16 + 16)
        payload[14] = 0
        payload[15] = 17
        XCTAssertThrowsError(try RadioLiteMediaFrameCodec.decodeSpectrum(payload))
    }

    func testDecodesSpectrumSourceCapability() throws {
        let data = Data(#"{
          "available": true,
          "source": "audio-fft",
          "simulated": false,
          "supportsWaterfall": true,
          "maxBins": 512,
          "maxFps": 5,
          "spanHz": 8000
        }"#.utf8)

        let capability = try JSONDecoder().decode(RadioLiteSpectrumCapability.self, from: data)

        XCTAssertTrue(capability.available)
        XCTAssertEqual(capability.source, "audio-fft")
        XCTAssertFalse(capability.simulated)
        XCTAssertTrue(capability.supportsWaterfall)
        XCTAssertEqual(capability.maxBins, 512)
        XCTAssertEqual(capability.spanHz, 8_000)
    }

    func testSpectrumHistoryIsBoundedAndResetsWhenFrequencyAxisChanges() {
        var history = RadioLiteSpectrumHistory(maxRows: 2)
        let first = RadioLiteSpectrumFrame(
            centerFrequencyHz: 14_074_000,
            spanHz: 8_000,
            noiseFloorTenthsDBm: -1_000,
            bins: [1, 2, 3]
        )
        history.append(first)
        history.append(RadioLiteSpectrumFrame(
            centerFrequencyHz: first.centerFrequencyHz,
            spanHz: first.spanHz,
            noiseFloorTenthsDBm: -990,
            bins: [4, 5, 6]
        ))
        history.append(RadioLiteSpectrumFrame(
            centerFrequencyHz: first.centerFrequencyHz,
            spanHz: first.spanHz,
            noiseFloorTenthsDBm: -980,
            bins: [7, 8, 9]
        ))
        XCTAssertEqual(history.rows, [[4, 5, 6], [7, 8, 9]])

        history.append(RadioLiteSpectrumFrame(
            centerFrequencyHz: 7_074_000,
            spanHz: first.spanHz,
            noiseFloorTenthsDBm: -970,
            bins: [10, 11, 12]
        ))
        XCTAssertEqual(history.rows, [[10, 11, 12]])
    }

    func testUnavailableSpectrumCapabilityDoesNotClaimARealSource() {
        let capability = RadioLiteSpectrumCapability.unavailable(reason: "media_worker_failed")

        XCTAssertFalse(capability.available)
        XCTAssertEqual(capability.source, "none")
        XCTAssertFalse(capability.simulated)
        XCTAssertFalse(capability.supportsWaterfall)
        XCTAssertEqual(capability.maxBins, 0)
        XCTAssertEqual(capability.maxFps, 0)
        XCTAssertEqual(capability.reason, "media_worker_failed")
    }

    func testSpectrumHistoryDownsamplesEachWaterfallRowWithPeakPreservation() {
        var history = RadioLiteSpectrumHistory(maxRows: 4, maxColumns: 2)
        history.append(RadioLiteSpectrumFrame(
            centerFrequencyHz: 14_074_000,
            spanHz: 8_000,
            noiseFloorTenthsDBm: -1_000,
            bins: [1, 9, 3, 7]
        ))

        XCTAssertEqual(history.rows, [[9, 7]])
    }
}
