import XCTest
@testable import RadioLite

final class RadioLiteFT8DecodeTableTests: XCTestCase {
    func testDenseDecodeTablePresentsMessageBeforeFrequencySNRAndUTCDelta() {
        let decode = RadioLiteDigitalDecode(
            id: "decode-1",
            message: "CQ JA1ABC PM95",
            snrDb: -8,
            deltaTimeSeconds: 0.1,
            audioFrequencyHz: 612,
            confidence: 0.98
        )
        let row = RadioLiteFTDecodeRowPresentation(decode: decode)

        XCTAssertEqual(
            RadioLiteFTDecodeTableColumn.allCases,
            [.message, .frequencyHz, .snr, .utcDelta]
        )
        XCTAssertEqual(
            RadioLiteFTDecodeTableColumn.allCases.map { row.text(for: $0) },
            ["CQ JA1ABC 🇯🇵 PM95", "612", "-8", "+0.1"]
        )
    }

    func testCompactDecodeMetadataIsSelfDescribingAndKeepsColumnOrder() {
        let decode = RadioLiteDigitalDecode(
            id: "decode-compact",
            message: "CQ JA1ABC PM95",
            snrDb: 23,
            deltaTimeSeconds: 0.2,
            audioFrequencyHz: 395,
            confidence: 1
        )
        XCTAssertEqual(
            RadioLiteFTDecodeCompactMetadataFormatter.text(decode: decode),
            "395 Hz · SNR +23 · Δt +0.2 s"
        )
    }
}
