import Foundation

struct RadioLiteMeterSample: Codable, Equatable, Sendable {
    let strengthDbRelativeS9: Double?
    let swr: Double?
    let alcRatio: Double?
    let rfPowerRatio: Double?
    let rfPowerWatts: Double?

    init(
        strengthDbRelativeS9: Double? = nil,
        swr: Double? = nil,
        alcRatio: Double? = nil,
        rfPowerRatio: Double? = nil,
        rfPowerWatts: Double? = nil
    ) {
        self.strengthDbRelativeS9 = strengthDbRelativeS9
        self.swr = swr
        self.alcRatio = alcRatio
        self.rfPowerRatio = rfPowerRatio
        self.rfPowerWatts = rfPowerWatts
    }
}

struct RadioLiteSMeterReading: Equatable, Sendable {
    static let minimumRelativeDb = -54.0
    static let maximumRelativeDb = 60.0

    let relativeDb: Double

    init?(relativeDb: Double) {
        guard relativeDb.isFinite else { return nil }
        self.relativeDb = relativeDb
    }

    var label: String {
        if relativeDb <= Self.minimumRelativeDb {
            return "S0"
        }
        if relativeDb < 0 {
            let sUnits = min(9, max(0, 9 + relativeDb / 6))
            return "S\(Self.formattedNumber(sUnits))"
        }
        if abs(relativeDb) < 0.000_001 {
            return "S9"
        }
        return "S9+\(Self.formattedNumber(relativeDb))"
    }

    var relativeDbLabel: String {
        let sign = relativeDb >= 0 ? "+" : ""
        return "\(sign)\(Self.formattedNumber(relativeDb)) dB rel. S9"
    }

    var normalizedValue: Double {
        let clamped = min(Self.maximumRelativeDb, max(Self.minimumRelativeDb, relativeDb))
        return (clamped - Self.minimumRelativeDb)
            / (Self.maximumRelativeDb - Self.minimumRelativeDb)
    }

    private static func formattedNumber(_ value: Double) -> String {
        let roundedTenth = (value * 10).rounded() / 10
        if abs(roundedTenth.rounded() - roundedTenth) < 0.000_001 {
            return String(format: "%.0f", roundedTenth)
        }
        return String(format: "%.1f", roundedTenth)
    }
}

struct RadioLiteTelemetry: Codable, Equatable, Sendable {
    let t: String
    let radioId: String
    let sampledAtMs: UInt64
    let state: RadioLiteRigState
    let meters: RadioLiteMeterSample
    let availableMeters: [String]

    var hasActualPowerMeter: Bool {
        availableMeters.contains("RFPOWER_METER_WATTS")
            || availableMeters.contains("RFPOWER_METER")
    }

    func supportsMeter(_ name: String) -> Bool {
        availableMeters.contains(name)
    }

    func isStale(nowMs: UInt64, periodMs: UInt64) -> Bool {
        guard nowMs > sampledAtMs else { return false }
        let (threshold, overflow) = periodMs.multipliedReportingOverflow(by: 3)
        return !overflow && nowMs - sampledAtMs > threshold
    }
}

struct RadioLiteTelemetrySubscriptionOwnership: Equatable, Sendable {
    let radioId: String

    func subscribeMessage(commandId: String) -> JSONValue {
        .object([
            "t": .string("rig.telemetry.subscribe"),
            "radioId": .string(radioId),
            "commandId": .string(commandId),
        ])
    }

    func unsubscribeMessage(commandId: String) -> JSONValue {
        .object([
            "t": .string("rig.telemetry.unsubscribe"),
            "radioId": .string(radioId),
            "commandId": .string(commandId),
        ])
    }

    func owns(_ sample: RadioLiteTelemetry) -> Bool {
        sample.t == "rig.telemetry" && sample.radioId == radioId
    }
}
