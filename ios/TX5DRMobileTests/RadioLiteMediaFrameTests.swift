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
}
