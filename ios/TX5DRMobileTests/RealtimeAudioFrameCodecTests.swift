import XCTest
@testable import TX5DRMobile

final class RealtimeAudioFrameCodecTests: XCTestCase {
    func testVersionOnePCMFrameMatchesTX5DRWireFormat() throws {
        let frame = RealtimePCMFrame(
            sequence: 0x0102_0304,
            timestampMilliseconds: 0x1112_1314,
            serverSentAtMilliseconds: nil,
            sampleRate: 48_000,
            channels: 1,
            samplesPerChannel: 4,
            samples: [.min, -1, 0, .max]
        )

        let encoded = try RealtimeAudioFrameCodec.encode(frame)
        XCTAssertEqual(Array(encoded.prefix(20)), [
            0x54, 0x58, 0x35, 0x44,
            0x01, 0x01, 0x00, 0x04,
            0x01, 0x02, 0x03, 0x04,
            0x11, 0x12, 0x13, 0x14,
            0x00, 0x00, 0xBB, 0x80,
        ])
        XCTAssertEqual(Array(encoded.suffix(8)), [0x00, 0x80, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0x7F])
        XCTAssertEqual(try RealtimeAudioFrameCodec.decode(encoded), frame)
    }

    func testVersionTwoDiagnosticsFrameRoundTrips() throws {
        let frame = RealtimePCMFrame(
            sequence: 7,
            timestampMilliseconds: 8,
            serverSentAtMilliseconds: 9,
            sampleRate: 12_000,
            channels: 2,
            samplesPerChannel: 2,
            samples: [1, 2, 3, 4]
        )

        let encoded = try RealtimeAudioFrameCodec.encode(frame)
        XCTAssertEqual(encoded[4], 2)
        XCTAssertEqual(encoded.count, 24 + 8)
        XCTAssertEqual(try RealtimeAudioFrameCodec.decode(encoded), frame)
    }

    func testRejectsBadMagicAndMismatchedPayload() throws {
        let frame = RealtimePCMFrame(
            sequence: 1,
            timestampMilliseconds: 2,
            serverSentAtMilliseconds: nil,
            sampleRate: 8_000,
            channels: 1,
            samplesPerChannel: 1,
            samples: [3]
        )
        var badMagic = try RealtimeAudioFrameCodec.encode(frame)
        badMagic[0] = 0
        XCTAssertThrowsError(try RealtimeAudioFrameCodec.decode(badMagic)) { error in
            XCTAssertEqual(error as? RealtimeAudioFrameCodecError, .invalidMagic)
        }

        var shortPayload = try RealtimeAudioFrameCodec.encode(frame)
        shortPayload.removeLast()
        XCTAssertThrowsError(try RealtimeAudioFrameCodec.decode(shortPayload)) { error in
            XCTAssertEqual(error as? RealtimeAudioFrameCodecError, .invalidPayloadLength)
        }
    }
}
