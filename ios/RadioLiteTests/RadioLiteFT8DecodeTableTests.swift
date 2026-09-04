import XCTest
@testable import RadioLite

final class RadioLiteFT8DecodeTableTests: XCTestCase {
    // Synthetic display fixtures exercise the requested UI rules, not radio capabilities.
    func testCallsignMatchingAcceptsExactPortableAndBracketedTokens() {
        for token in ["BG4XYZ", "bg4xyz", "BG4XYZ/P", "EA8/BG4XYZ", "<BG4XYZ>", "<BG4XYZ/P>"] {
            XCTAssertTrue(
                RadioLiteDenseDecodeSemantics.matchesCallsign(token, "BG4XYZ"),
                "Expected an exact base callsign match for \(token)"
            )
        }
        XCTAssertTrue(RadioLiteDenseDecodeSemantics.matchesCallsign("BG4XYZ", "<BG4XYZ/P>"))
    }

    func testCallsignMatchingRejectsPrefixesAndMissingStationCallsign() {
        for token in ["BG4XYZZ", "BG4XY", "XBG4XYZ", "BG4XYZZ/P"] {
            XCTAssertFalse(RadioLiteDenseDecodeSemantics.matchesCallsign(token, "BG4XYZ"))
        }
        XCTAssertFalse(RadioLiteDenseDecodeSemantics.matchesCallsign("BG4XYZ", nil))
        XCTAssertFalse(RadioLiteDenseDecodeSemantics.matchesCallsign("BG4XYZ", "  "))
    }

    func testMessageAddressedToStationTakesPriorityOverWorkedSender() {
        let row = presentation("<BG4XYZ/P> JA1ABC -06", worked: ["JA1ABC"])

        XCTAssertTrue(row.kind == .toMe)
        XCTAssertEqual(row.segments.filter(\.isStation).map(\.text), ["<BG4XYZ/P>"])
        XCTAssertFalse(row.kind.strikethrough)
    }

    func testPrefixCallsignDoesNotHighlightAnUnrelatedReceivedMessage() {
        let row = presentation("BG4XYZZ JA1ABC -06")

        XCTAssertTrue(row.kind == .plain)
        XCTAssertTrue(row.segments.allSatisfy { !$0.isStation })
    }

    func testWorkedCQIsDimmedAndStruckThroughInsteadOfCQHighlight() {
        let row = presentation("CQ JA1ABC/P PM95", worked: ["JA1ABC"])

        XCTAssertTrue(row.kind == .worked)
        XCTAssertTrue(row.kind.strikethrough)
        XCTAssertNil(row.kind.rail)
    }

    func testCQDXPrefixAndGridArePresentedWithoutLosingMessageContent() {
        let row = presentation("CQ DX JA1ABC PM95")

        XCTAssertTrue(row.kind == .cq)
        XCTAssertEqual(row.segments.filter(\.isCQPrefix).map(\.text), ["CQ", " DX"])
        XCTAssertEqual(row.segments.map(\.text).joined(), "CQ DX JA1ABC")
        XCTAssertEqual(row.tail, "🇯🇵 PM95")
        XCTAssertNil(row.kind.rail)
    }

    func testRR73RemainsExchangeTextInsteadOfMovingToGridTail() {
        let row = presentation("BG4XYZ JA1ABC RR73")

        XCTAssertEqual(row.segments.map(\.text).joined(), "BG4XYZ JA1ABC RR73")
        XCTAssertEqual(row.tail, "🇯🇵")
        XCTAssertFalse(row.tail.contains("RR73"))
    }

    func testTransmitPresentationRequiresConfirmedLocalTransmitEvidence() {
        let received = presentation("BG4XYZ JA1ABC -06")
        let transmitted = presentation("BG4XYZ JA1ABC -06", confirmedTX: true)

        XCTAssertFalse(received.kind == .myTx)
        XCTAssertEqual(received.snr, "-06")
        XCTAssertTrue(transmitted.kind == .myTx)
        XCTAssertEqual(transmitted.snr, "TX")
    }

    func testDenseRowPresentsUTCMinuteSecondSignedSNRAndAudioFrequency() throws {
        let instant = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-09-04T20:03:45+05:30")
        )
        let row = RadioLiteDenseDecodePresentation(
            decode: decode(message: "CQ JA1ABC PM95", snr: 6),
            slotStartMs: Int64(instant.timeIntervalSince1970 * 1_000),
            stationCallsign: "BG4XYZ",
            workedCallsigns: []
        )

        XCTAssertEqual(row.time, "3345")
        XCTAssertEqual(row.snr, "+06")
        XCTAssertEqual(row.frequency, "612")
        XCTAssertTrue(row.accessibilityLabel.contains("UTC 3345"))
        XCTAssertTrue(row.accessibilityLabel.contains("CQ JA1ABC PM95"))
    }

    func testDeltaMeanIncludesThirtySecondBoundaryButExcludesOlderAndFutureBatches() throws {
        let batches = [
            batch(receivedAtMs: 970_000, deltas: [0.2]),
            batch(receivedAtMs: 1_000_000, deltas: [0.4]),
            batch(receivedAtMs: 969_999, deltas: [100]),
            batch(receivedAtMs: 1_000_001, deltas: [200]),
        ]
        let mean = try XCTUnwrap(RadioLiteFT8TimingPresentation.meanDelta(
            batches: batches, mode: "FT8", at: Date(timeIntervalSince1970: 1_000)
        ))

        XCTAssertEqual(mean, 0.3, accuracy: 0.000_001)
    }

    func testDeltaMeanFiltersModeAndWeightsEachDecodeRatherThanEachBatch() throws {
        let batches = [
            batch(deltas: [0.2, 0.4]),
            batch(deltas: [0.9]),
            batch(mode: "FT4", deltas: [4]),
        ]
        let mean = try XCTUnwrap(RadioLiteFT8TimingPresentation.meanDelta(
            batches: batches, mode: "FT8", at: Date(timeIntervalSince1970: 1_000)
        ))

        XCTAssertEqual(mean, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(
            RadioLiteFT8TimingPresentation.meanDelta(
                batches: batches, mode: "FT4", at: Date(timeIntervalSince1970: 1_000)
            ),
            4
        )
    }

    func testDeltaMeanIgnoresNaNAndInfinityAndReturnsNilWithoutFiniteSamples() throws {
        let mean = try XCTUnwrap(RadioLiteFT8TimingPresentation.meanDelta(
            batches: [batch(deltas: [.nan, .infinity, -.infinity, -0.2, 0.6])],
            mode: "FT8",
            at: Date(timeIntervalSince1970: 1_000)
        ))

        XCTAssertEqual(mean, 0.2, accuracy: 0.000_001)
        XCTAssertNil(RadioLiteFT8TimingPresentation.meanDelta(
            batches: [batch(deltas: [.nan, .infinity])],
            mode: "FT8", at: Date(timeIntervalSince1970: 1_000)
        ))
        XCTAssertNil(RadioLiteFT8TimingPresentation.meanDelta(
            batches: [], mode: "FT8", at: Date(timeIntervalSince1970: 1_000)
        ))
    }

    func testNewDXRequiresKnownDifferentCountryAndUnworkedSender() {
        XCTAssertTrue(RadioLiteDenseDecodeSemantics.isNewDX(
            message: "CQ JA1ABC PM95", stationCallsign: "BG4XYZ", workedCallsigns: []
        ))
        XCTAssertFalse(RadioLiteDenseDecodeSemantics.isNewDX(
            message: "CQ BH6AJS OM81", stationCallsign: "BG4XYZ", workedCallsigns: []
        ))
        XCTAssertFalse(RadioLiteDenseDecodeSemantics.isNewDX(
            message: "CQ JA1ABC PM95", stationCallsign: "BG4XYZ", workedCallsigns: ["JA1ABC"]
        ))
        XCTAssertFalse(RadioLiteDenseDecodeSemantics.isNewDX(
            message: "CQ JA1ABC PM95", stationCallsign: nil, workedCallsigns: []
        ))
    }

    private func presentation(
        _ message: String,
        worked: Set<String> = [],
        confirmedTX: Bool = false
    ) -> RadioLiteDenseDecodePresentation {
        RadioLiteDenseDecodePresentation(
            decode: decode(message: message),
            slotStartMs: 0,
            stationCallsign: "BG4XYZ",
            workedCallsigns: worked,
            isConfirmedLocalTransmit: confirmedTX
        )
    }

    private func decode(
        message: String = "CQ JA1ABC PM95",
        snr: Double = -6,
        delta: Double = 0.1,
        id: String = "decode-1"
    ) -> RadioLiteDigitalDecode {
        RadioLiteDigitalDecode(
            id: id,
            message: message,
            snrDb: snr,
            deltaTimeSeconds: delta,
            audioFrequencyHz: 612,
            confidence: 0.98
        )
    }

    private func batch(
        receivedAtMs: Int64 = 1_000_000,
        mode: String = "FT8",
        deltas: [Double]
    ) -> RadioLiteDigitalDecodeBatch {
        RadioLiteDigitalDecodeBatch(
            radioId: "fixture-radio",
            mode: mode,
            slotStartMs: receivedAtMs - 15_000,
            slotEndMs: receivedAtMs,
            receivedAtMs: receivedAtMs,
            revision: 1,
            decodes: deltas.enumerated().map { index, value in
                decode(delta: value, id: "decode-\(index)")
            }
        )
    }
}
