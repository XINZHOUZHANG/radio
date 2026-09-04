import MapKit

struct RadioLiteGridMapCell: Identifiable {
    let summary: RadioLiteGridSummary
    let coordinates: [CLLocationCoordinate2D]
    let fillOpacity: Double

    private let minimumLatitude: Double
    private let maximumLatitude: Double
    private let minimumLongitude: Double
    private let maximumLongitude: Double

    var id: String { summary.id }

    init(summary: RadioLiteGridSummary) {
        self.summary = summary
        let halfLatitude = summary.latitudeSpan / 2
        let halfLongitude = summary.longitudeSpan / 2
        minimumLatitude = summary.latitude - halfLatitude
        maximumLatitude = summary.latitude + halfLatitude
        minimumLongitude = summary.longitude - halfLongitude
        maximumLongitude = summary.longitude + halfLongitude
        coordinates = [
            .init(latitude: minimumLatitude, longitude: minimumLongitude),
            .init(latitude: minimumLatitude, longitude: maximumLongitude),
            .init(latitude: maximumLatitude, longitude: maximumLongitude),
            .init(latitude: maximumLatitude, longitude: minimumLongitude),
        ]
        fillOpacity = min(0.3, 0.07 + log10(Double(max(1, summary.qsoCount))) * 0.06)
    }

    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        coordinate.latitude >= minimumLatitude
            && coordinate.latitude <= maximumLatitude
            && coordinate.longitude >= minimumLongitude
            && coordinate.longitude <= maximumLongitude
    }
}

struct RadioLiteGridMapPresentation {
    static let maximumCells = 600
    static let maximumLabels = 80

    let totalGridCount: Int
    let cells: [RadioLiteGridMapCell]
    let labeledCells: ArraySlice<RadioLiteGridMapCell>

    init(grids: [RadioLiteGridSummary]) {
        totalGridCount = grids.count
        cells = grids.prefix(Self.maximumCells).map(RadioLiteGridMapCell.init)
        labeledCells = cells.prefix(Self.maximumLabels)
    }

    func summary(at coordinate: CLLocationCoordinate2D) -> RadioLiteGridSummary? {
        cells.first(where: { $0.contains(coordinate) })?.summary
    }
}
