import CoreLocation
import Foundation
import XCTest
@testable import RadioLite

final class RadioLiteGridMapPresentationTests: XCTestCase {
    func testPresentationKeepsMapContentWithinBudgets() {
        let grids = (0..<700).map { index in
            summary(
                grid: String(format: "G%03d", index),
                latitude: 0,
                longitude: 0,
                qsoCount: 700 - index
            )
        }

        let presentation = RadioLiteGridMapPresentation(grids: grids)

        XCTAssertEqual(presentation.totalGridCount, 700)
        XCTAssertEqual(presentation.cells.count, RadioLiteGridMapPresentation.maximumCells)
        XCTAssertEqual(presentation.labeledCells.count, RadioLiteGridMapPresentation.maximumLabels)
        XCTAssertEqual(presentation.cells.first?.id, "G000")
        XCTAssertEqual(presentation.cells.last?.id, "G599")
    }

    func testCellGeometryIsPrecomputedAndCanBeHitTested() throws {
        let expected = summary(
            grid: "PM95",
            latitude: 35.5,
            longitude: 139,
            latitudeSpan: 1,
            longitudeSpan: 2,
            qsoCount: 25
        )
        let presentation = RadioLiteGridMapPresentation(grids: [expected])
        let cell = try XCTUnwrap(presentation.cells.first)

        XCTAssertEqual(cell.coordinates.count, 4)
        XCTAssertEqual(cell.coordinates[0].latitude, 35)
        XCTAssertEqual(cell.coordinates[0].longitude, 138)
        XCTAssertEqual(cell.coordinates[2].latitude, 36)
        XCTAssertEqual(cell.coordinates[2].longitude, 140)
        XCTAssertEqual(
            presentation.summary(at: .init(latitude: 35.5, longitude: 139)),
            expected
        )
        XCTAssertNil(presentation.summary(at: .init(latitude: 34, longitude: 139)))
    }

    func testUnlabeledCellRemainsAvailableToMapHitTesting() throws {
        let grids = (0..<82).map { index in
            summary(
                grid: String(format: "G%03d", index),
                latitude: 0,
                longitude: Double(index),
                longitudeSpan: 0.5,
                qsoCount: 82 - index
            )
        }
        let presentation = RadioLiteGridMapPresentation(grids: grids)
        let unlabeledCell = try XCTUnwrap(presentation.cells.dropFirst(80).first)

        XCTAssertFalse(presentation.labeledCells.contains(where: { $0.id == unlabeledCell.id }))
        XCTAssertEqual(
            presentation.summary(
                at: .init(
                    latitude: unlabeledCell.summary.latitude,
                    longitude: unlabeledCell.summary.longitude
                )
            ),
            unlabeledCell.summary
        )
    }

    private func summary(
        grid: String,
        latitude: Double,
        longitude: Double,
        latitudeSpan: Double = 1,
        longitudeSpan: Double = 2,
        qsoCount: Int
    ) -> RadioLiteGridSummary {
        RadioLiteGridSummary(
            grid: grid,
            latitude: latitude,
            longitude: longitude,
            latitudeSpan: latitudeSpan,
            longitudeSpan: longitudeSpan,
            qsoCount: qsoCount,
            lastQsoAtMs: 1,
            bands: ["20m": qsoCount],
            modes: ["FT8": qsoCount]
        )
    }
}
