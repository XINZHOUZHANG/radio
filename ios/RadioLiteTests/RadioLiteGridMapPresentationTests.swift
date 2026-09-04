import CoreLocation
import Foundation
import MapKit
import XCTest
@testable import RadioLite

final class RadioLiteGridMapPresentationTests: XCTestCase {
    func testLargePresentationDoesNotDiscardSourceGrids() {
        let grids = (0..<916).map { index in
            summary(
                grid: locator(index),
                latitude: Double(index % 90) - 45,
                longitude: Double(index % 180) - 90,
                qsoCount: 1
            )
        }
        let presentation = RadioLiteGridMapPresentation(grids: grids)

        XCTAssertEqual(presentation.totalGridCount, 916)
        XCTAssertEqual(presentation.sourceCells.count, 916)
        XCTAssertEqual(Set(presentation.fieldCells.flatMap(\.memberGridIDs)).count, 916)
        XCTAssertLessThanOrEqual(presentation.fieldCells.count, 324)
    }

    func testPresentationKeepsEverySourceGridAndAggregatesOverviewWithoutLosingCounts() throws {
        let grids = [
            summary(
                grid: "PM95",
                latitude: 35.5,
                longitude: 139,
                qsoCount: 2,
                lastQsoAtMs: 20,
                bands: ["20m": 2],
                modes: ["FT8": 2]
            ),
            summary(
                grid: "PM96",
                latitude: 36.5,
                longitude: 139,
                qsoCount: 3,
                lastQsoAtMs: 30,
                bands: ["40m": 3],
                modes: ["SSB": 3]
            ),
            summary(
                grid: "QN00",
                latitude: 40.5,
                longitude: 141,
                qsoCount: 4,
                lastQsoAtMs: 10
            ),
        ]

        let presentation = RadioLiteGridMapPresentation(grids: grids)
        let overview = presentation.initialRenderSet
        let pm = try XCTUnwrap(presentation.fieldCells.first(where: { $0.summary.grid == "PM" }))

        XCTAssertEqual(presentation.totalGridCount, 3)
        XCTAssertEqual(presentation.sourceCells.count, 3)
        XCTAssertEqual(presentation.fieldCells.count, 2)
        XCTAssertEqual(Set(presentation.fieldCells.flatMap(\.memberGridIDs)), Set(grids.map(\.id)))
        XCTAssertEqual(overview.level, .field)
        XCTAssertEqual(overview.cells.map(\.summary.qsoCount).reduce(0, +), 9)
        XCTAssertEqual(pm.id, "field:PM")
        XCTAssertEqual(pm.summary.latitude, 35)
        XCTAssertEqual(pm.summary.longitude, 130)
        XCTAssertEqual(pm.summary.latitudeSpan, 10)
        XCTAssertEqual(pm.summary.longitudeSpan, 20)
        XCTAssertEqual(pm.summary.qsoCount, 5)
        XCTAssertEqual(pm.summary.lastQsoAtMs, 30)
        XCTAssertEqual(pm.summary.bands, ["20m": 2, "40m": 3])
        XCTAssertEqual(pm.summary.modes, ["FT8": 2, "SSB": 3])
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
        let cell = RadioLiteGridMapCell(summary: expected)

        XCTAssertEqual(cell.coordinates.count, 4)
        XCTAssertEqual(cell.coordinates[0].latitude, 35)
        XCTAssertEqual(cell.coordinates[0].longitude, 138)
        XCTAssertEqual(cell.coordinates[2].latitude, 36)
        XCTAssertEqual(cell.coordinates[2].longitude, 140)
        XCTAssertTrue(cell.contains(.init(latitude: 35.5, longitude: 139)))
        XCTAssertFalse(cell.contains(.init(latitude: 34, longitude: 139)))
    }

    func testDetailViewShowsEveryVisibleGridWhenWithinBudget() throws {
        let grids = (0..<130).map { index in
            summary(
                grid: locator(index),
                latitude: 0,
                longitude: Double(index) * 0.1 - 6.5,
                latitudeSpan: 0.05,
                longitudeSpan: 0.05,
                qsoCount: 130 - index
            )
        }
        let presentation = RadioLiteGridMapPresentation(grids: grids)
        let renderSet = presentation.render(
            in: region(latitude: 0, longitude: 0, latitudeDelta: 10, longitudeDelta: 20),
            previousLevel: .field
        )
        let unlabeledCell = try XCTUnwrap(
            renderSet.cells.dropFirst(RadioLiteGridMapPresentation.maximumDetailLabels).first
        )

        XCTAssertEqual(renderSet.level, .grid)
        XCTAssertEqual(renderSet.cells.count, 130)
        XCTAssertEqual(renderSet.labeledCells.count, RadioLiteGridMapPresentation.maximumDetailLabels)
        XCTAssertEqual(renderSet.omittedVisibleCount, 0)
        XCTAssertFalse(renderSet.labeledCells.contains(where: { $0.id == unlabeledCell.id }))
        XCTAssertEqual(
            renderSet.summary(
                at: .init(
                    latitude: unlabeledCell.summary.latitude,
                    longitude: unlabeledCell.summary.longitude
                )
            ),
            unlabeledCell.summary
        )
    }

    func testCrowdedDetailViewUsesABoundedRenderSetAndOmittedGridReturnsAfterZooming() throws {
        let grids = (0..<300).map { index in
            summary(
                grid: locator(index),
                latitude: 0,
                longitude: Double(index) * 0.02 - 3,
                latitudeSpan: 0.005,
                longitudeSpan: 0.005,
                qsoCount: 300 - index
            )
        }
        let presentation = RadioLiteGridMapPresentation(grids: grids)
        let crowded = presentation.render(
            in: region(latitude: 0, longitude: 0, latitudeDelta: 10, longitudeDelta: 20),
            previousLevel: .field
        )
        let omitted = grids[299]
        let zoomed = presentation.render(
            in: region(
                latitude: omitted.latitude,
                longitude: omitted.longitude,
                latitudeDelta: 0.01,
                longitudeDelta: 0.01
            ),
            previousLevel: .grid
        )

        XCTAssertEqual(crowded.cells.count, RadioLiteGridMapPresentation.maximumDetailedCells)
        XCTAssertEqual(crowded.labeledCells.count, RadioLiteGridMapPresentation.maximumDetailLabels)
        XCTAssertEqual(crowded.visibleSourceCount, 300)
        XCTAssertEqual(crowded.omittedVisibleCount, 60)
        XCTAssertTrue(zoomed.cells.contains(where: { $0.summary.id == omitted.id }))
    }

    func testViewportAcrossDateLineIncludesBothSidesButNotGreenwich() {
        let grids = [
            summary(grid: "RR90", latitude: 0, longitude: 179, longitudeSpan: 1, qsoCount: 3),
            summary(grid: "AA00", latitude: 0, longitude: -179, longitudeSpan: 1, qsoCount: 2),
            summary(grid: "JJ00", latitude: 0, longitude: 0, longitudeSpan: 1, qsoCount: 1),
        ]
        let presentation = RadioLiteGridMapPresentation(grids: grids)
        let renderSet = presentation.render(
            in: region(latitude: 0, longitude: 179, latitudeDelta: 10, longitudeDelta: 6),
            previousLevel: .field
        )
        let ids = Set(renderSet.cells.map(\.summary.id))

        XCTAssertEqual(ids, Set(["RR90", "AA00"]))
    }

    func testZoomThresholdUsesHysteresis() {
        let presentation = RadioLiteGridMapPresentation(
            grids: [summary(grid: "PM95", latitude: 35.5, longitude: 139, qsoCount: 1)]
        )

        let entered = presentation.render(
            in: region(latitude: 35.5, longitude: 139, latitudeDelta: 10, longitudeDelta: 28),
            previousLevel: .field
        )
        let retained = presentation.render(
            in: region(latitude: 35.5, longitude: 139, latitudeDelta: 10, longitudeDelta: 30),
            previousLevel: entered.level
        )
        let exited = presentation.render(
            in: region(latitude: 35.5, longitude: 139, latitudeDelta: 10, longitudeDelta: 34),
            previousLevel: retained.level
        )

        XCTAssertEqual(entered.level, .grid)
        XCTAssertEqual(retained.level, .grid)
        XCTAssertEqual(exited.level, .field)
    }

    func testRepeatedViewportProducesEquivalentRenderContent() {
        let presentation = RadioLiteGridMapPresentation(
            grids: [summary(grid: "PM95", latitude: 35.5, longitude: 139, qsoCount: 1)]
        )
        let viewport = region(
            latitude: 35.5,
            longitude: 139,
            latitudeDelta: 10,
            longitudeDelta: 20
        )
        let first = presentation.render(in: viewport, previousLevel: .field)
        let repeated = presentation.render(in: viewport, previousLevel: first.level)
        let elsewhere = presentation.render(
            in: region(latitude: 0, longitude: 0, latitudeDelta: 10, longitudeDelta: 20),
            previousLevel: first.level
        )

        XCTAssertTrue(first.hasSameContent(as: repeated))
        XCTAssertFalse(first.hasSameContent(as: elsewhere))
    }

    private func summary(
        grid: String,
        latitude: Double,
        longitude: Double,
        latitudeSpan: Double = 1,
        longitudeSpan: Double = 2,
        qsoCount: Int,
        lastQsoAtMs: Int64 = 1,
        bands: [String: Int]? = nil,
        modes: [String: Int]? = nil
    ) -> RadioLiteGridSummary {
        RadioLiteGridSummary(
            grid: grid,
            latitude: latitude,
            longitude: longitude,
            latitudeSpan: latitudeSpan,
            longitudeSpan: longitudeSpan,
            qsoCount: qsoCount,
            lastQsoAtMs: lastQsoAtMs,
            bands: bands ?? ["20m": qsoCount],
            modes: modes ?? ["FT8": qsoCount]
        )
    }

    private func locator(_ index: Int) -> String {
        let letters = Array("ABCDEFGHIJKLMNOPQR")
        let field = index / 100
        let square = index % 100
        return "\(letters[field % letters.count])\(letters[(field / letters.count) % letters.count])\(square / 10)\(square % 10)"
    }

    private func region(
        latitude: Double,
        longitude: Double,
        latitudeDelta: Double,
        longitudeDelta: Double
    ) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: .init(latitude: latitude, longitude: longitude),
            span: .init(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
        )
    }
}
