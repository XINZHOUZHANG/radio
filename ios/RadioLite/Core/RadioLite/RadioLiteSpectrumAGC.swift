import Foundation

struct RadioLiteSpectrumAGC: Equatable, Sendable {
    let smoothingFactor: Double
    private(set) var floor: Double?
    private(set) var ceiling: Double?

    init(smoothingFactor: Double = 0.25) {
        self.smoothingFactor = min(1, max(0, smoothingFactor))
    }

    mutating func normalize(_ bins: [UInt8]) -> [UInt8] {
        guard !bins.isEmpty else { return [] }
        let sorted = bins.sorted()
        let measuredFloor = percentile(0.20, in: sorted)
        let measuredCeiling = percentile(0.98, in: sorted)

        if let floor, let ceiling {
            self.floor = floor + (measuredFloor - floor) * smoothingFactor
            self.ceiling = ceiling + (measuredCeiling - ceiling) * smoothingFactor
        } else {
            floor = measuredFloor
            ceiling = measuredCeiling
        }

        let activeFloor = floor ?? measuredFloor
        let activeCeiling = max(activeFloor + 1, ceiling ?? measuredCeiling)
        return bins.map { value in
            let normalized = min(1, max(0, (Double(value) - activeFloor) / (activeCeiling - activeFloor)))
            return UInt8((normalized * 255).rounded())
        }
    }

    mutating func reset() {
        floor = nil
        ceiling = nil
    }

    private func percentile(_ fraction: Double, in sorted: [UInt8]) -> Double {
        let index = Int((Double(sorted.count - 1) * fraction).rounded(.down))
        return Double(sorted[index])
    }
}
