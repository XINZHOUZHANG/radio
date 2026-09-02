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
