import MapKit

enum RadioLiteGridMapLevel: Equatable {
    case field
    case grid
}

struct RadioLiteGridMapLongitudeInterval: Equatable {
    let lowerBound: Double
    let upperBound: Double

    func intersects(_ other: Self) -> Bool {
        upperBound >= other.lowerBound && other.upperBound >= lowerBound
    }

    func contains(_ longitude: Double) -> Bool {
        longitude >= lowerBound && longitude <= upperBound
    }
}

struct RadioLiteGridMapBounds: Equatable {
    let south: Double
    let north: Double
    let longitudeIntervals: [RadioLiteGridMapLongitudeInterval]

    init(
        center: CLLocationCoordinate2D,
        latitudeSpan: Double,
        longitudeSpan: Double
    ) {
        let latitudeRadius = min(180, abs(latitudeSpan)) / 2
        south = max(-90, center.latitude - latitudeRadius)
        north = min(90, center.latitude + latitudeRadius)
        longitudeIntervals = Self.longitudeIntervals(
            center: center.longitude,
            span: longitudeSpan
        )
    }

    init(region: MKCoordinateRegion, padding: Double = 0.1) {
        let paddingMultiplier = 1 + max(0, padding) * 2
        self.init(
            center: region.center,
            latitudeSpan: min(180, abs(region.span.latitudeDelta) * paddingMultiplier),
            longitudeSpan: min(360, abs(region.span.longitudeDelta) * paddingMultiplier)
        )
    }

    func intersects(_ other: Self) -> Bool {
        guard north >= other.south, other.north >= south else {
            return false
        }
        return longitudeIntervals.contains { interval in
            other.longitudeIntervals.contains(where: { interval.intersects($0) })
        }
    }

    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        guard coordinate.latitude >= south, coordinate.latitude <= north else {
            return false
        }
        let longitude = Self.normalizedLongitude(coordinate.longitude)
        return longitudeIntervals.contains(where: { $0.contains(longitude) })
    }

    private static func longitudeIntervals(
        center: Double,
        span: Double
    ) -> [RadioLiteGridMapLongitudeInterval] {
        let clampedSpan = min(360, abs(span))
        guard clampedSpan < 360 else {
            return [.init(lowerBound: -180, upperBound: 180)]
        }

        let radius = clampedSpan / 2
        let west = normalizedLongitude(center - radius)
        let east = normalizedLongitude(center + radius)
        if west <= east {
            return [.init(lowerBound: west, upperBound: east)]
        }
        return [
            .init(lowerBound: west, upperBound: 180),
            .init(lowerBound: -180, upperBound: east),
        ]
    }

    private static func normalizedLongitude(_ longitude: Double) -> Double {
        var result = longitude.truncatingRemainder(dividingBy: 360)
        if result >= 180 {
            result -= 360
        } else if result < -180 {
            result += 360
        }
        return result
    }
}

struct RadioLiteGridMapCell: Identifiable {
    let id: String
    let summary: RadioLiteGridSummary
    let memberGridIDs: [String]
    let coordinates: [CLLocationCoordinate2D]
    let bounds: RadioLiteGridMapBounds
    let fillOpacity: Double

    init(summary: RadioLiteGridSummary, idPrefix: String = "grid", memberGridIDs: [String]? = nil) {
        id = "\(idPrefix):\(summary.id)"
        self.summary = summary
        self.memberGridIDs = memberGridIDs ?? [summary.id]
        let halfLatitude = summary.latitudeSpan / 2
        let halfLongitude = summary.longitudeSpan / 2
        let minimumLatitude = summary.latitude - halfLatitude
        let maximumLatitude = summary.latitude + halfLatitude
        let minimumLongitude = summary.longitude - halfLongitude
        let maximumLongitude = summary.longitude + halfLongitude
        coordinates = [
            .init(latitude: minimumLatitude, longitude: minimumLongitude),
            .init(latitude: minimumLatitude, longitude: maximumLongitude),
            .init(latitude: maximumLatitude, longitude: maximumLongitude),
            .init(latitude: maximumLatitude, longitude: minimumLongitude),
        ]
        bounds = RadioLiteGridMapBounds(
            center: .init(latitude: summary.latitude, longitude: summary.longitude),
            latitudeSpan: summary.latitudeSpan,
            longitudeSpan: summary.longitudeSpan
        )
        fillOpacity = min(0.28, 0.06 + log10(Double(max(1, summary.qsoCount))) * 0.055)
    }

    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        bounds.contains(coordinate)
    }
}

struct RadioLiteGridMapRenderSet {
    let level: RadioLiteGridMapLevel
    let cells: [RadioLiteGridMapCell]
    let labeledCells: ArraySlice<RadioLiteGridMapCell>
    let visibleSourceCount: Int
    let omittedVisibleCount: Int

    func summary(at coordinate: CLLocationCoordinate2D) -> RadioLiteGridSummary? {
        cells.first(where: { $0.contains(coordinate) })?.summary
    }

    func hasSameContent(as other: Self) -> Bool {
        level == other.level
            && visibleSourceCount == other.visibleSourceCount
            && omittedVisibleCount == other.omittedVisibleCount
            && cells.map(\.id) == other.cells.map(\.id)
    }
}

struct RadioLiteGridMapPresentation {
    static let detailEnterLongitudeDelta = 28.0
    static let detailExitLongitudeDelta = 34.0
    static let maximumDetailedCells = 240
    static let maximumDetailLabels = 80
    static let maximumOverviewLabels = 40

    let totalGridCount: Int
    let sourceCells: [RadioLiteGridMapCell]
    let fieldCells: [RadioLiteGridMapCell]

    init(grids: [RadioLiteGridSummary]) {
        totalGridCount = grids.count
        sourceCells = grids
            .map { RadioLiteGridMapCell(summary: $0) }
            .sorted(by: Self.cellSort)
        fieldCells = Self.aggregateFields(grids)
    }

    var initialRenderSet: RadioLiteGridMapRenderSet {
        overviewRenderSet(visibleSourceCount: totalGridCount)
    }

    func render(
        in region: MKCoordinateRegion,
        previousLevel: RadioLiteGridMapLevel
    ) -> RadioLiteGridMapRenderSet {
        let longitudeDelta = abs(region.span.longitudeDelta)
        let level: RadioLiteGridMapLevel
        switch previousLevel {
        case .field:
            level = longitudeDelta <= Self.detailEnterLongitudeDelta ? .grid : .field
        case .grid:
            level = longitudeDelta >= Self.detailExitLongitudeDelta ? .field : .grid
        }

        guard level == .grid else {
            return overviewRenderSet(visibleSourceCount: totalGridCount)
        }

        let viewport = RadioLiteGridMapBounds(region: region)
        let visibleCells = sourceCells.filter { $0.bounds.intersects(viewport) }
        let displayedCells = Array(visibleCells.prefix(Self.maximumDetailedCells))
        return RadioLiteGridMapRenderSet(
            level: .grid,
            cells: displayedCells,
            labeledCells: displayedCells.prefix(Self.maximumDetailLabels),
            visibleSourceCount: visibleCells.count,
            omittedVisibleCount: max(0, visibleCells.count - displayedCells.count)
        )
    }

    private func overviewRenderSet(visibleSourceCount: Int) -> RadioLiteGridMapRenderSet {
        RadioLiteGridMapRenderSet(
            level: .field,
            cells: fieldCells,
            labeledCells: fieldCells.prefix(Self.maximumOverviewLabels),
            visibleSourceCount: visibleSourceCount,
            omittedVisibleCount: 0
        )
    }

    private static func aggregateFields(_ grids: [RadioLiteGridSummary]) -> [RadioLiteGridMapCell] {
        var accumulators: [String: FieldAccumulator] = [:]
        for summary in grids {
            let field = String(summary.grid.prefix(2)).uppercased()
            guard field.count == 2 else { continue }
            var accumulator = accumulators[field] ?? FieldAccumulator()
            accumulator.qsoCount += summary.qsoCount
            accumulator.lastQsoAtMs = max(accumulator.lastQsoAtMs, summary.lastQsoAtMs)
            accumulator.memberGridIDs.append(summary.id)
            for (band, count) in summary.bands {
                accumulator.bands[band, default: 0] += count
            }
            for (mode, count) in summary.modes {
                accumulator.modes[mode, default: 0] += count
            }
            accumulators[field] = accumulator
        }

        return accumulators.compactMap { field, accumulator in
            guard let geometry = fieldGeometry(field) else { return nil }
            let summary = RadioLiteGridSummary(
                grid: field,
                latitude: geometry.latitude,
                longitude: geometry.longitude,
                latitudeSpan: 10,
                longitudeSpan: 20,
                qsoCount: accumulator.qsoCount,
                lastQsoAtMs: accumulator.lastQsoAtMs,
                bands: accumulator.bands,
                modes: accumulator.modes
            )
            return RadioLiteGridMapCell(
                summary: summary,
                idPrefix: "field",
                memberGridIDs: accumulator.memberGridIDs.sorted()
            )
        }
        .sorted(by: cellSort)
    }

    private static func fieldGeometry(_ field: String) -> CLLocationCoordinate2D? {
        let bytes = Array(field.utf8)
        guard bytes.count == 2 else { return nil }
        let longitudeIndex = Int(bytes[0]) - 65
        let latitudeIndex = Int(bytes[1]) - 65
        guard (0..<18).contains(longitudeIndex), (0..<18).contains(latitudeIndex) else {
            return nil
        }
        return CLLocationCoordinate2D(
            latitude: -90 + Double(latitudeIndex) * 10 + 5,
            longitude: -180 + Double(longitudeIndex) * 20 + 10
        )
    }

    private static func cellSort(_ left: RadioLiteGridMapCell, _ right: RadioLiteGridMapCell) -> Bool {
        if left.summary.qsoCount != right.summary.qsoCount {
            return left.summary.qsoCount > right.summary.qsoCount
        }
        if left.summary.lastQsoAtMs != right.summary.lastQsoAtMs {
            return left.summary.lastQsoAtMs > right.summary.lastQsoAtMs
        }
        return left.summary.grid < right.summary.grid
    }

    private struct FieldAccumulator {
        var qsoCount = 0
        var lastQsoAtMs: Int64 = 0
        var bands: [String: Int] = [:]
        var modes: [String: Int] = [:]
        var memberGridIDs: [String] = []
    }
}
