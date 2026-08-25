import XCTest
@testable import TX5DRMobile

final class RadioLiteSpectrumAGCTests: XCTestCase {
    func testPercentileWindowMapsNoiseFloorAndStrongSignalsToFullContrast() {
        var agc = RadioLiteSpectrumAGC(smoothingFactor: 0.25)
        let bins = (0..<100).map(UInt8.init)

        let normalized = agc.normalize(bins)

        XCTAssertEqual(agc.floor, 19, accuracy: 0.000_001)
        XCTAssertEqual(agc.ceiling, 97, accuracy: 0.000_001)
        XCTAssertEqual(normalized[19], 0)
        XCTAssertGreaterThanOrEqual(normalized[97], 254)
        XCTAssertEqual(normalized[99], 255)
    }

    func testRangeMovesGraduallyAcrossAbruptLevelChanges() {
        var agc = RadioLiteSpectrumAGC(smoothingFactor: 0.25)
        _ = agc.normalize((0..<100).map(UInt8.init))

        _ = agc.normalize((100..<200).map(UInt8.init))

        XCTAssertEqual(agc.floor, 44, accuracy: 0.000_001)
        XCTAssertEqual(agc.ceiling, 122, accuracy: 0.000_001)
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
}
