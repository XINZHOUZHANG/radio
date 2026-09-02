import XCTest
@testable import RadioLite

final class RadioLiteSpectrumAGCTests: XCTestCase {
    func testPercentileWindowMapsNoiseFloorAndStrongSignalsToFullContrast() throws {
        var agc = RadioLiteSpectrumAGC(smoothingFactor: 0.25)
        let bins = (0..<100).map(UInt8.init)

        let normalized = agc.normalize(bins)
        let floor = try XCTUnwrap(agc.floor)
        let ceiling = try XCTUnwrap(agc.ceiling)

        XCTAssertEqual(floor, 19, accuracy: 0.000_001)
        XCTAssertEqual(ceiling, 97, accuracy: 0.000_001)
        XCTAssertEqual(normalized[19], 0)
        XCTAssertGreaterThanOrEqual(normalized[97], 254)
        XCTAssertEqual(normalized[99], 255)
    }

    func testRangeMovesGraduallyAcrossAbruptLevelChanges() throws {
        var agc = RadioLiteSpectrumAGC(smoothingFactor: 0.25)
        _ = agc.normalize((0..<100).map(UInt8.init))

        _ = agc.normalize((100..<200).map(UInt8.init))
        let floor = try XCTUnwrap(agc.floor)
        let ceiling = try XCTUnwrap(agc.ceiling)

        XCTAssertEqual(floor, 44, accuracy: 0.000_001)
        XCTAssertEqual(ceiling, 122, accuracy: 0.000_001)
    }

    func testFlatAndEmptyFramesStaySafeAndResetClearsHistory() {
        var agc = RadioLiteSpectrumAGC(smoothingFactor: 0.25)

        XCTAssertEqual(agc.normalize([]), [])
        XCTAssertEqual(agc.normalize([42, 42, 42]), [0, 0, 0])
        XCTAssertNotNil(agc.floor)
        XCTAssertNotNil(agc.ceiling)

        agc.reset()

        XCTAssertNil(agc.floor)
        XCTAssertNil(agc.ceiling)
    }

    func testWeakSignalsRemainVisibleWithoutClippingToStrongSignals() {
        var agc = RadioLiteSpectrumAGC(smoothingFactor: 0.25)
        let bins = [UInt8](repeating: 80, count: 96) + [96, 96, 180, 180]

        let normalized = agc.normalize(bins)
        let noise = normalized[0]
        let weak = normalized[96]
        let strong = normalized[98]

        XCTAssertLessThanOrEqual(noise, 8)
        XCTAssertGreaterThan(weak, noise + 40)
        XCTAssertLessThan(weak, strong)
        XCTAssertGreaterThanOrEqual(strong, 250)
    }

    func testSpectrumAxisPlacesFiveTicksAtQuarterIntervals() {
        let axis = RadioLiteSpectrumAxis(spanHz: 3_000)

        XCTAssertEqual(axis.ticks.map(\.frequencyHz), [0, 750, 1_500, 2_250, 3_000])
        XCTAssertEqual(axis.ticks.map(\.normalizedPosition), [0, 0.25, 0.5, 0.75, 1])
    }

    func testSpectrumAxisOnlyReturnsMarkerPositionsInsideTheDisplayedSpan() {
        let axis = RadioLiteSpectrumAxis(spanHz: 3_000)

        XCTAssertEqual(axis.marker(for: 1_500), .visible(frequencyHz: 1_500, normalizedPosition: 0.5))
        XCTAssertEqual(axis.marker(for: -20), .belowRange(frequencyHz: -20))
        XCTAssertEqual(axis.marker(for: 3_100), .aboveRange(frequencyHz: 3_100))
        XCTAssertEqual(axis.marker(for: nil), .none)
        XCTAssertNil(axis.marker(for: 3_100).normalizedPosition)
        XCTAssertEqual(axis.marker(for: 3_100).outOfRangeFrequencyHz, 3_100)
    }
}
