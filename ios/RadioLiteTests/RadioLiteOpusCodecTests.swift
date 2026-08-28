import Foundation
import XCTest
@testable import RadioLite

final class RadioLiteOpusCodecTests: XCTestCase {
    func testContinuousOpusPacketsDoNotEndTheReusableConverters() throws {
        let encoder = try RadioLiteOpusCodec(bitrate: 20_000)
        let decoder = try RadioLiteOpusCodec(bitrate: 20_000)
        var decodedFrames: [[Float]] = []

        for packetIndex in 0..<6 {
            let samples = (0..<RadioLiteOpusCodec.samplesPerFrame).map { sampleIndex in
                let position = Double(packetIndex * RadioLiteOpusCodec.samplesPerFrame + sampleIndex)
                return Float(sin(2 * .pi * 700 * position / RadioLiteOpusCodec.sampleRate) * 0.3)
            }
            let packet = try encoder.encode(samples)
            XCTAssertFalse(packet.isEmpty)
            decodedFrames.append(try decoder.decode(packet))
        }

        XCTAssertEqual(decodedFrames.count, 6)
        XCTAssertTrue(decodedFrames.allSatisfy { $0.count == RadioLiteOpusCodec.samplesPerFrame })
        let peak = decodedFrames.dropFirst().flatMap { $0 }.map { abs($0) }.max() ?? 0
        XCTAssertGreaterThan(peak, 0.01)
    }
}
