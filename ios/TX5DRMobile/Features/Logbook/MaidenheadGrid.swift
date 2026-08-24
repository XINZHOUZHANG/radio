import Foundation

struct MaidenheadGridBounds: Equatable, Sendable {
    let minimumLatitude: Double
    let maximumLatitude: Double
    let minimumLongitude: Double
    let maximumLongitude: Double

    var centerLatitude: Double { (minimumLatitude + maximumLatitude) / 2 }
    var centerLongitude: Double { (minimumLongitude + maximumLongitude) / 2 }
}

enum MaidenheadGrid {
    static func bounds(for rawValue: String) -> MaidenheadGridBounds? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard [2, 4, 6, 8].contains(value.count) else { return nil }
        let characters = Array(value)

        guard
            let longitudeField = letterIndex(characters[0], upperBound: 17),
            let latitudeField = letterIndex(characters[1], upperBound: 17)
        else { return nil }

        var minimumLongitude = -180 + Double(longitudeField) * 20
        var minimumLatitude = -90 + Double(latitudeField) * 10
        var longitudeSize = 20.0
        var latitudeSize = 10.0

        if characters.count >= 4 {
            guard
                let longitudeSquare = digitValue(characters[2]),
                let latitudeSquare = digitValue(characters[3])
            else { return nil }
            longitudeSize /= 10
            latitudeSize /= 10
            minimumLongitude += Double(longitudeSquare) * longitudeSize
            minimumLatitude += Double(latitudeSquare) * latitudeSize
        }

        if characters.count >= 6 {
            guard
                let longitudeSubsquare = letterIndex(characters[4], upperBound: 23),
                let latitudeSubsquare = letterIndex(characters[5], upperBound: 23)
            else { return nil }
            longitudeSize /= 24
            latitudeSize /= 24
            minimumLongitude += Double(longitudeSubsquare) * longitudeSize
            minimumLatitude += Double(latitudeSubsquare) * latitudeSize
        }

        if characters.count == 8 {
            guard
                let longitudeExtendedSquare = digitValue(characters[6]),
                let latitudeExtendedSquare = digitValue(characters[7])
            else { return nil }
            longitudeSize /= 10
            latitudeSize /= 10
            minimumLongitude += Double(longitudeExtendedSquare) * longitudeSize
            minimumLatitude += Double(latitudeExtendedSquare) * latitudeSize
        }

        return MaidenheadGridBounds(
            minimumLatitude: minimumLatitude,
            maximumLatitude: minimumLatitude + latitudeSize,
            minimumLongitude: minimumLongitude,
            maximumLongitude: minimumLongitude + longitudeSize
        )
    }

    private static func letterIndex(_ character: Character, upperBound: Int) -> Int? {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return nil }
        let index = Int(scalar.value) - 65
        return (0...upperBound).contains(index) ? index : nil
    }

    private static func digitValue(_ character: Character) -> Int? {
        guard let value = character.wholeNumberValue, (0...9).contains(value) else { return nil }
        return value
    }
}
