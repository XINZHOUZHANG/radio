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

    func replacingValue(_ replacement: Double) -> Self {
        Self(
            id: id,
            kind: kind,
            token: token,
            value: replacement,
            minimum: minimum,
            maximum: maximum,
            step: step,
            unit: unit,
            transmitLocked: transmitLocked
        )
    }

    private init(
        id: String,
        kind: Kind,
        token: String,
        value: Double,
        minimum: Double,
        maximum: Double,
        step: Double,
        unit: Unit,
        transmitLocked: Bool
    ) {
        self.id = id
        self.kind = kind
        self.token = token
        self.value = value
        self.minimum = minimum
        self.maximum = maximum
        self.step = step
        self.unit = unit
        self.transmitLocked = transmitLocked
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
    case unavailable
}

enum RadioLiteTunerInteractionPolicy {
    static func startAction(
        isTuning: Bool,
        isPending: Bool,
        tuneSupported: Bool
    ) -> RadioLiteTunerTapAction {
        guard tuneSupported, !isTuning, !isPending else { return .unavailable }
        return .start
    }

    static func canEmergencyStop(isTuning: Bool) -> Bool {
        isTuning
    }

    static func reflectingSuccessfulTuneStart(
        in controls: [RadioLiteRigControl]
    ) -> [RadioLiteRigControl] {
        controls.map { control in
            control.id == "function:TUNER" ? control.replacingValue(1) : control
        }
    }

    static func tunerSwitch(in controls: [RadioLiteRigControl]) -> RadioLiteRigControl? {
        controls.first { $0.id == "function:TUNER" }
    }

    static func generalControls(in controls: [RadioLiteRigControl]) -> [RadioLiteRigControl] {
        controls.filter { $0.id != "function:TUNER" }
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

enum RadioLiteControlValue: Codable, Equatable, Hashable, Sendable {
    case boolean(Bool)
    case number(Double)
    case string(String)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .boolean(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var jsonValue: JSONValue {
        switch self {
        case .boolean(let value): .bool(value)
        case .number(let value): .number(value)
        case .string(let value): .string(value)
        case .null: .null
        }
    }

    var numberValue: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }

    var booleanValue: Bool? {
        guard case .boolean(let value) = self else { return nil }
        return value
    }
}

enum RadioLiteCapabilityGroup: Codable, Equatable, Hashable, Sendable {
    case antenna
    case rf
    case audio
    case mode
    case cw
    case repeater
    case spectrum
    case system
    case unknown(String)

    static let productOrder: [Self] = [
        .antenna, .rf, .audio, .mode, .cw, .repeater, .spectrum, .system,
    ]

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "antenna": self = .antenna
        case "rf": self = .rf
        case "audio": self = .audio
        case "mode": self = .mode
        case "cw": self = .cw
        case "repeater": self = .repeater
        case "spectrum": self = .spectrum
        case "system": self = .system
        default: self = .unknown(value)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }

    var wireValue: String {
        switch self {
        case .antenna: "antenna"
        case .rf: "rf"
        case .audio: "audio"
        case .mode: "mode"
        case .cw: "cw"
        case .repeater: "repeater"
        case .spectrum: "spectrum"
        case .system: "system"
        case .unknown(let value): value
        }
    }

    var label: String {
        switch self {
        case .antenna: "天线"
        case .rf: "射频"
        case .audio: "音频"
        case .mode: "模式"
        case .cw: "CW"
        case .repeater: "中继"
        case .spectrum: "频谱"
        case .system: "系统"
        case .unknown(let value): value.uppercased()
        }
    }

    var systemImage: String {
        switch self {
        case .antenna: "antenna.radiowaves.left.and.right"
        case .rf: "wave.3.right"
        case .audio: "speaker.wave.2.fill"
        case .mode: "dial.medium"
        case .cw: "waveform.path.ecg"
        case .repeater: "repeat"
        case .spectrum: "chart.bar.xaxis"
        case .system, .unknown: "gearshape.fill"
        }
    }

    var productIndex: Int {
        Self.productOrder.firstIndex(of: self) ?? Self.productOrder.count
    }
}

enum RadioLiteCapabilityAccess: Codable, Equatable, Sendable {
    case readOnly
    case readWrite
    case action
    case unknown(String)

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "read-only": self = .readOnly
        case "read-write": self = .readWrite
        case "action": self = .action
        default: self = .unknown(value)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        let value: String
        switch self {
        case .readOnly: value = "read-only"
        case .readWrite: value = "read-write"
        case .action: value = "action"
        case .unknown(let unknown): value = unknown
        }
        try container.encode(value)
    }

    var permitsMutation: Bool {
        self == .readWrite || self == .action
    }
}

enum RadioLiteCapabilityPresentation: Codable, Equatable, Sendable {
    case meter
    case toggle
    case slider
    case discrete
    case enumeration
    case offset
    case button
    case unknown(String)

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "meter": self = .meter
        case "toggle": self = .toggle
        case "slider": self = .slider
        case "discrete": self = .discrete
        case "enum": self = .enumeration
        case "offset": self = .offset
        case "button": self = .button
        default: self = .unknown(value)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        let value: String
        switch self {
        case .meter: value = "meter"
        case .toggle: value = "toggle"
        case .slider: value = "slider"
        case .discrete: value = "discrete"
        case .enumeration: value = "enum"
        case .offset: value = "offset"
        case .button: value = "button"
        case .unknown(let unknown): value = unknown
        }
        try container.encode(value)
    }

    var isSupported: Bool {
        if case .unknown = self { return false }
        return true
    }
}

enum RadioLiteCapabilityUnit: Codable, Equatable, Sendable {
    case ratio
    case decibel
    case hertz
    case watts
    case milliseconds
    case index
    case boolean
    case unknown(String)

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "ratio": self = .ratio
        case "decibel": self = .decibel
        case "hertz": self = .hertz
        case "watts": self = .watts
        case "milliseconds": self = .milliseconds
        case "index": self = .index
        case "boolean": self = .boolean
        default: self = .unknown(value)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        let value: String
        switch self {
        case .ratio: value = "ratio"
        case .decibel: value = "decibel"
        case .hertz: value = "hertz"
        case .watts: value = "watts"
        case .milliseconds: value = "milliseconds"
        case .index: value = "index"
        case .boolean: value = "boolean"
        case .unknown(let unknown): value = unknown
        }
        try container.encode(value)
    }
}

struct RadioLiteCapabilityOption: Codable, Equatable, Sendable {
    let value: RadioLiteControlValue
    let label: String
}

struct RadioLiteCapabilityControl: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let token: String
    let group: RadioLiteCapabilityGroup
    let access: RadioLiteCapabilityAccess
    let presentation: RadioLiteCapabilityPresentation
    let value: RadioLiteControlValue
    let minimum: Double?
    let maximum: Double?
    let step: Double?
    let unit: RadioLiteCapabilityUnit?
    let options: [RadioLiteCapabilityOption]?
    let transmitLocked: Bool

    func replacingValue(_ replacement: RadioLiteControlValue) -> Self {
        Self(
            id: id,
            token: token,
            group: group,
            access: access,
            presentation: presentation,
            value: replacement,
            minimum: minimum,
            maximum: maximum,
            step: step,
            unit: unit,
            options: options,
            transmitLocked: transmitLocked
        )
    }

    func displayState(
        isTransmitting: Bool,
        hasControl: Bool
    ) -> RadioLiteCapabilityDisplayState {
        let disabledReason: String?
        if !presentation.isSupported {
            disabledReason = "当前版本不支持此控件"
        } else if access == .readOnly || presentation == .meter {
            disabledReason = nil
        } else if !hasControl {
            disabledReason = "需要先取得电台控制权"
        } else if transmitLocked && isTransmitting {
            disabledReason = "发射期间不可调整"
        } else if !access.permitsMutation {
            disabledReason = "该控件为只读"
        } else {
            disabledReason = nil
        }
        return RadioLiteCapabilityDisplayState(
            label: Self.label(for: token),
            isEnabled: access.permitsMutation
                && presentation != .meter
                && disabledReason == nil,
            disabledReason: disabledReason
        )
    }

    func formattedValue(_ candidate: RadioLiteControlValue? = nil) -> String {
        let candidate = candidate ?? value
        if let option = options?.first(where: { $0.value == candidate }) {
            return option.label
        }
        switch candidate {
        case .boolean(let enabled): return enabled ? "开启" : "关闭"
        case .string(let value): return value
        case .null: return "—"
        case .number(let value):
            if presentation == .offset {
                switch unit {
                case .hertz: return String(format: "%+.0f Hz", value)
                case .milliseconds: return String(format: "%+.0f ms", value)
                default: return String(format: "%+.0f", value)
                }
            }
            switch unit {
            case .ratio: return String(format: "%.0f%%", value * 100)
            case .decibel: return String(format: abs(value.rounded() - value) < 0.000_001 ? "%.0f dB" : "%.1f dB", value)
            case .hertz: return String(format: "%.0f Hz", value)
            case .watts: return String(format: "%.1f W", value)
            case .milliseconds: return String(format: "%.0f ms", value)
            case .boolean: return value >= 0.5 ? "开启" : "关闭"
            case .index, .unknown, .none: return String(format: abs(value.rounded() - value) < 0.000_001 ? "%.0f" : "%.2f", value)
            }
        }
    }

    func validated(_ candidate: RadioLiteControlValue) -> RadioLiteControlValue? {
        guard access.permitsMutation else { return nil }
        switch presentation {
        case .toggle:
            guard case .boolean = candidate else { return nil }
        case .slider, .offset, .meter:
            guard case .number(let number) = candidate, number.isFinite else { return nil }
            if let minimum, number < minimum { return nil }
            if let maximum, number > maximum { return nil }
        case .discrete:
            if let options, !options.isEmpty {
                guard options.contains(where: { $0.value == candidate }) else { return nil }
            } else {
                guard case .number(let number) = candidate, number.isFinite else { return nil }
                if let minimum, number < minimum { return nil }
                if let maximum, number > maximum { return nil }
            }
        case .enumeration:
            guard options?.contains(where: { $0.value == candidate }) == true else { return nil }
        case .button:
            guard candidate == .null else { return nil }
        case .unknown:
            return nil
        }
        return candidate
    }

    private static func label(for token: String) -> String {
        switch token.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
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
        case "TUNER": return "机内天调"
        case "CWPITCH": return "CW 音调"
        case "PASSBAND", "CURRENT": return "滤波器带宽"
        default: return token.isEmpty ? "Hamlib 控件" : token.uppercased()
        }
    }
}

struct RadioLiteCapabilityDisplayState: Equatable, Sendable {
    let label: String
    let isEnabled: Bool
    let disabledReason: String?
}

struct RadioLiteCapabilityGroupSection: Identifiable, Equatable, Sendable {
    let id: RadioLiteCapabilityGroup
    let controls: [RadioLiteCapabilityControl]
}

struct RadioLiteCapabilityGroups: Equatable, Sendable {
    let groups: [RadioLiteCapabilityGroupSection]

    init(_ controls: [RadioLiteCapabilityControl]) {
        let visible = controls.filter {
            $0.presentation.isSupported && $0.id != RadioLiteCapabilityProtocol.tunerActionId
        }
        let grouped = Dictionary(grouping: visible, by: \.group)
        groups = grouped.map { RadioLiteCapabilityGroupSection(id: $0.key, controls: $0.value) }
            .sorted {
                let left = $0.id.productIndex
                let right = $1.id.productIndex
                return left == right ? $0.id.wireValue < $1.id.wireValue : left < right
            }
    }
}

struct RadioLiteCapabilitiesResponse: Codable, Equatable, Sendable {
    let t: String
    let radioId: String
    let commandId: String
    let controls: [RadioLiteCapabilityControl]
}

struct RadioLiteCapabilityControlReadback: Codable, Equatable, Sendable {
    let id: String
    let value: RadioLiteControlValue
}

struct RadioLiteCapabilityControlConfirmation: Codable, Equatable, Sendable {
    let t: String
    let radioId: String
    let commandId: String
    let control: RadioLiteCapabilityControlReadback
}

struct RadioLiteActionConfirmation: Codable, Equatable, Sendable {
    let t: String
    let radioId: String
    let commandId: String
    let id: String
    let transmitToken: String?
    let heartbeatDeadlineMs: Int64?
    let hardDeadlineMs: Int64?
}

struct RadioLiteActionCompletion: Codable, Equatable, Sendable {
    let t: String
    let radioId: String
    let id: String
    let transmitToken: String
    let reason: String
}

struct RadioLiteCapabilityCatalogue: Equatable, Sendable {
    private(set) var controls: [RadioLiteCapabilityControl] = []
    private(set) var generation: UInt64 = 0
    private(set) var isAvailable = false

    @discardableResult
    mutating func beginDiscovery() -> UInt64 {
        generation &+= 1
        controls.removeAll(keepingCapacity: false)
        isAvailable = false
        return generation
    }

    mutating func invalidate() {
        _ = beginDiscovery()
    }

    func isCurrent(_ candidate: UInt64) -> Bool {
        candidate == generation
    }

    @discardableResult
    mutating func publish(
        _ controls: [RadioLiteCapabilityControl],
        generation candidate: UInt64
    ) -> Bool {
        guard isCurrent(candidate) else { return false }
        self.controls = controls
        isAvailable = true
        return true
    }
}

enum RadioLiteCapabilityProtocol {
    static let tunerActionId = "action:TUNER"

    static func getRequest(radioId: String, commandId: String) -> JSONValue {
        .object([
            "t": .string("rig.capabilities.get"),
            "radioId": .string(radioId),
            "commandId": .string(commandId),
        ])
    }

    static func setRequest(
        radioId: String,
        controlToken: String,
        controlId: String,
        value: RadioLiteControlValue,
        commandId: String
    ) -> JSONValue {
        .object([
            "t": .string("rig.control.set"),
            "radioId": .string(radioId),
            "controlToken": .string(controlToken),
            "controlId": .string(controlId),
            "value": value.jsonValue,
            "commandId": .string(commandId),
        ])
    }

    static func actionRequest(
        radioId: String,
        controlToken: String,
        id: String,
        commandId: String
    ) -> JSONValue {
        .object([
            "t": .string("rig.action.invoke"),
            "radioId": .string(radioId),
            "controlToken": .string(controlToken),
            "id": .string(id),
            "commandId": .string(commandId),
        ])
    }

    static func applying(
        _ confirmation: RadioLiteCapabilityControlConfirmation,
        to controls: [RadioLiteCapabilityControl]
    ) -> [RadioLiteCapabilityControl] {
        controls.map {
            $0.id == confirmation.control.id
                ? $0.replacingValue(confirmation.control.value)
                : $0
        }
    }
}
