import Foundation

struct RadioLiteRigControlsResponse: Codable, Equatable, Sendable {
    let t: String
    let radioId: String
    let commandId: String
    let controls: [RadioLiteRigControl]
}

struct RadioLiteRigControlConfirmation: Codable, Equatable, Sendable {
    let t: String
    let radioId: String
    let commandId: String
    let control: RadioLiteRigControl
}

struct RadioLiteRigControl: Codable, Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case level
        case function
        case filter
        case unknown(String)

        fileprivate init(wireValue: String) {
            switch wireValue.lowercased() {
            case "level": self = .level
            case "function": self = .function
            case "passband": self = .filter
            default: self = .unknown(wireValue)
            }
        }

        fileprivate var wireValue: String {
            switch self {
            case .level: "level"
            case .function: "function"
            case .filter: "passband"
            case .unknown(let value): value
            }
        }
    }

    enum Unit: Equatable, Sendable {
        case ratio
        case decibel
        case index
        case boolean
        case hertz
        case unknown(String)

        fileprivate init(wireValue: String) {
            switch wireValue.lowercased() {
            case "ratio": self = .ratio
            case "decibel": self = .decibel
            case "index": self = .index
            case "boolean": self = .boolean
            case "hertz": self = .hertz
            default: self = .unknown(wireValue)
            }
        }

        fileprivate var wireValue: String {
            switch self {
            case .ratio: "ratio"
            case .decibel: "decibel"
            case .index: "index"
            case .boolean: "boolean"
            case .hertz: "hertz"
            case .unknown(let value): value
            }
        }
    }

    let id: String
    let kind: Kind
    let token: String
    let value: Double
    let minimum: Double
    let maximum: Double
    let step: Double
    let unit: Unit
    let transmitLocked: Bool

    private enum CodingKeys: String, CodingKey {
        case id, kind, token, value, minimum, maximum, step, unit, transmitLocked
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = Kind(wireValue: try container.decode(String.self, forKey: .kind))
        token = try container.decode(String.self, forKey: .token)
        value = try container.decode(Double.self, forKey: .value)
        minimum = try container.decode(Double.self, forKey: .minimum)
        maximum = try container.decode(Double.self, forKey: .maximum)
        step = try container.decode(Double.self, forKey: .step)
        unit = Unit(wireValue: try container.decode(String.self, forKey: .unit))
        transmitLocked = try container.decode(Bool.self, forKey: .transmitLocked)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind.wireValue, forKey: .kind)
        try container.encode(token, forKey: .token)
        try container.encode(value, forKey: .value)
        try container.encode(minimum, forKey: .minimum)
        try container.encode(maximum, forKey: .maximum)
        try container.encode(step, forKey: .step)
        try container.encode(unit.wireValue, forKey: .unit)
        try container.encode(transmitLocked, forKey: .transmitLocked)
    }

    func displayState(isTransmitting: Bool) -> RadioLiteRigControlDisplayState {
        let unsupported: Bool
        if case .unknown = kind { unsupported = true } else { unsupported = false }
        let lockedForTransmit = transmitLocked && isTransmitting
        let lockedReason: String?
        if unsupported {
            lockedReason = "当前版本不支持此控件"
        } else if lockedForTransmit {
            lockedReason = "发射期间不可调整"
        } else {
            lockedReason = nil
        }
        return RadioLiteRigControlDisplayState(
            id: id,
            kind: kind,
            label: Self.label(for: token, kind: kind),
            value: value,
            minimum: minimum,
            maximum: maximum,
            step: step,
            unit: unit,
            options: kind == .function ? Self.booleanOptions : [],
            writable: lockedReason == nil,
            lockedReason: lockedReason
        )
    }

    private static let booleanOptions = [
        RadioLiteRigControlOption(value: 0, label: "关闭"),
        RadioLiteRigControlOption(value: 1, label: "开启"),
    ]

    private static func label(for token: String, kind: Kind) -> String {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if kind == .filter { return "滤波器带宽" }
        switch normalized {
        case "RFPOWER": return "发射功率"
        case "AF": return "音量"
        case "RF": return "射频增益"
        case "SQL": return "静噪"
        case "MICGAIN": return "麦克风增益"
        case "COMP": return "语音压缩"
        case "AGC": return "自动增益控制"
        case "ATT": return "衰减器"
        case "PREAMP": return "前置放大器"
        case "NB": return "脉冲噪声抑制"
        case "NR": return "降噪"
        case "ANF": return "自动陷波"
        case "TUNER": return "机内天调接入"
        default: return normalized.isEmpty ? token : normalized
        }
    }
}

struct RadioLiteRigControlOption: Equatable, Sendable {
    let value: Double
    let label: String
}

struct RadioLiteRigControlDisplayState: Identifiable, Equatable, Sendable {
    let id: String
    let kind: RadioLiteRigControl.Kind
    let label: String
    let value: Double
    let minimum: Double
    let maximum: Double
    let step: Double
    let unit: RadioLiteRigControl.Unit
    let options: [RadioLiteRigControlOption]
    let writable: Bool
    let lockedReason: String?

    func formattedValue(_ value: Double? = nil) -> String {
        let value = value ?? self.value
        switch unit {
        case .ratio:
            return String(format: "%.0f%%", value * 100)
        case .decibel:
            return step < 1
                ? String(format: "%.1f dB", value)
                : String(format: "%.0f dB", value)
        case .hertz:
            return String(format: "%.0f Hz", value)
        case .index:
            return step < 1
                ? String(format: "%.1f", value)
                : String(format: "%.0f", value)
        case .boolean:
            return value >= 0.5 ? "开启" : "关闭"
        case .unknown:
            return String(format: "%.2f", value)
        }
    }
}

struct RadioLiteRigControlCatalogue: Equatable, Sendable {
    private(set) var controls: [RadioLiteRigControl] = []
    private(set) var generation: UInt64 = 0

    @discardableResult
    mutating func beginDiscovery() -> UInt64 {
        invalidate()
        return generation
    }

    mutating func invalidate() {
        generation &+= 1
        controls.removeAll(keepingCapacity: false)
    }

    func isCurrent(_ candidate: UInt64) -> Bool {
        candidate == generation
    }

    @discardableResult
    mutating func publish(_ controls: [RadioLiteRigControl], generation candidate: UInt64) -> Bool {
        guard isCurrent(candidate) else { return false }
        self.controls = controls
        return true
    }
}

struct RadioLiteRigControlOperationOwnership: Equatable, Sendable {
    let radioId: String
    let catalogueGeneration: UInt64

    func isCurrent(selectedRadioId: String?, catalogueGeneration currentGeneration: UInt64) -> Bool {
        selectedRadioId == radioId && currentGeneration == catalogueGeneration
    }
}

enum RadioLiteTunerTapAction: Equatable, Sendable {
    case start
    case stop
    case unavailable
}

enum RadioLiteTunerInteractionPolicy {
    static func action(isTuning: Bool, tuneSupported: Bool) -> RadioLiteTunerTapAction {
        guard tuneSupported else { return .unavailable }
        return isTuning ? .stop : .start
    }

    static func shouldReengageSwitch(
        after reason: RadioLiteVoicePTTStopReason,
        switchAvailable: Bool
    ) -> Bool {
        switchAvailable && reason == .userRelease
    }
}

struct RadioLiteTunerSwitchReengageOwnership: Equatable, Sendable {
    let radioId: String
    let startupEpoch: UInt64
    let completionEpoch: UInt64

    func isCurrent(
        radioId candidateRadioId: String,
        startupEpoch candidateStartupEpoch: UInt64,
        currentEpoch: UInt64
    ) -> Bool {
        radioId == candidateRadioId
            && startupEpoch == candidateStartupEpoch
            && completionEpoch == currentEpoch
    }
}

enum RadioLiteRigControlProtocol {
    static func getRequest(radioId: String, commandId: String) -> JSONValue {
        .object([
            "t": .string("rig.controls.get"),
            "radioId": .string(radioId),
            "commandId": .string(commandId),
        ])
    }

    static func setRequest(
        radioId: String,
        controlToken: String,
        controlId: String,
        value: Double,
        commandId: String
    ) -> JSONValue {
        .object([
            "t": .string("rig.control.set"),
            "radioId": .string(radioId),
            "controlToken": .string(controlToken),
            "controlId": .string(controlId),
            "value": .number(value),
            "commandId": .string(commandId),
        ])
    }

    static func applying(
        _ confirmation: RadioLiteRigControlConfirmation,
        to controls: [RadioLiteRigControl]
    ) -> [RadioLiteRigControl] {
        var updated = controls
        if let index = updated.firstIndex(where: { $0.id == confirmation.control.id }) {
            updated[index] = confirmation.control
        } else {
            updated.append(confirmation.control)
        }
        return updated
    }
}
