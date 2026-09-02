import Foundation

struct RadioLiteHamlibModel: Codable, Identifiable, Equatable, Sendable {
    let modelId: Int
    let manufacturer: String
    let model: String
    let backendVersion: String
    let status: String

    var id: Int { modelId }
    var displayName: String { "\(manufacturer) \(model)" }

    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return displayName.localizedCaseInsensitiveContains(needle)
            || String(modelId).contains(needle)
    }
}

struct RadioLiteCuratedRigPreset: Codable, Identifiable, Equatable, Sendable {
    let slug: String
    let manufacturer: String
    let model: String
    let defaultBaudRate: Int?
    let hamlibModelId: Int?
    let available: Bool

    var id: String { slug }
    var displayName: String { "\(manufacturer) \(model)" }
}

struct RadioLiteSerialDevice: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let path: String
    let label: String
    let stable: Bool
}

struct RadioLiteDiscoveredAudioDevice: Codable, Identifiable, Equatable, Sendable {
    let backend: String
    let direction: String
    let id: String
    let label: String

    var endpoint: RadioLiteAudioEndpoint {
        .init(backend: backend, id: id, label: label)
    }
}

enum RadioLiteAudioLatency: String, Codable, CaseIterable, Identifiable, Sendable {
    case low
    case balanced
    case stable

    var id: String { rawValue }

    var label: String {
        switch self {
        case .low: "低延迟"
        case .balanced: "平衡"
        case .stable: "稳定"
        }
    }
}

enum RadioLiteAudioRoute: Codable, Equatable, Sendable {
    case systemDevice(hardwareId: String, latency: RadioLiteAudioLatency)
    case driverStream
    case none

    private enum CodingKeys: String, CodingKey { case kind, hardwareId, latency }
    private enum Kind: String, Codable { case systemDevice = "system-device", driverStream = "driver-stream", none }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .systemDevice:
            self = .systemDevice(
                hardwareId: try container.decode(String.self, forKey: .hardwareId),
                latency: try container.decode(RadioLiteAudioLatency.self, forKey: .latency)
            )
        case .driverStream:
            self = .driverStream
        case .none:
            self = .none
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .systemDevice(let hardwareId, let latency):
            try container.encode(Kind.systemDevice, forKey: .kind)
            try container.encode(hardwareId, forKey: .hardwareId)
            try container.encode(latency, forKey: .latency)
        case .driverStream:
            try container.encode(Kind.driverStream, forKey: .kind)
        case .none:
            try container.encode(Kind.none, forKey: .kind)
        }
    }

    var systemDeviceSelection: (hardwareId: String, latency: RadioLiteAudioLatency)? {
        guard case .systemDevice(let hardwareId, let latency) = self else { return nil }
        return (hardwareId, latency)
    }
}

struct RadioLiteAudioCard: Codable, Identifiable, Equatable, Sendable {
    let hardwareId: String
    let label: String
    let transport: String
    let complete: Bool
    let input: RadioLiteDiscoveredAudioDevice?
    let output: RadioLiteDiscoveredAudioDevice?

    var id: String { hardwareId }
    var isSelectableUSBCard: Bool {
        transport == "usb" && complete && input != nil && output != nil
    }
}

struct RadioLiteHardwareDiscovery: Codable, Equatable, Sendable {
    let hamlibModels: [RadioLiteHamlibModel]
    let curatedPresets: [RadioLiteCuratedRigPreset]
    let serialDevices: [RadioLiteSerialDevice]
    let audioInputs: [RadioLiteDiscoveredAudioDevice]
    let audioOutputs: [RadioLiteDiscoveredAudioDevice]
    let audioCards: [RadioLiteAudioCard]
    let pttMethods: [RadioLitePTTMethod]
    let baudRates: [Int]
    let warnings: [String]

    private enum CodingKeys: String, CodingKey {
        case hamlibModels, curatedPresets, serialDevices, audioInputs, audioOutputs, audioCards
        case pttMethods, baudRates, warnings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hamlibModels = try container.decode([RadioLiteHamlibModel].self, forKey: .hamlibModels)
        curatedPresets = try container.decode([RadioLiteCuratedRigPreset].self, forKey: .curatedPresets)
        serialDevices = try container.decode([RadioLiteSerialDevice].self, forKey: .serialDevices)
        audioInputs = try container.decode([RadioLiteDiscoveredAudioDevice].self, forKey: .audioInputs)
        audioOutputs = try container.decode([RadioLiteDiscoveredAudioDevice].self, forKey: .audioOutputs)
        audioCards = try container.decodeIfPresent([RadioLiteAudioCard].self, forKey: .audioCards) ?? []
        pttMethods = try container.decodeIfPresent([RadioLitePTTMethod].self, forKey: .pttMethods)
            ?? RadioLitePTTMethod.allCases
        baudRates = try container.decodeIfPresent([Int].self, forKey: .baudRates)
            ?? RadioLiteRadioConfigurationDraft.standardBaudRates
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
    }
}

enum RadioLiteHardwarePreflightStatus: String, Codable, Equatable, Sendable {
    case passed
    case warning
    case failed
}

enum RadioLiteHardwarePreflightCheckID: String, Codable, Equatable, Hashable, Sendable {
    case cat
    case capabilities
    case audioInput
    case audioOutput
}

struct RadioLiteHardwarePreflightCheck: Codable, Identifiable, Equatable, Sendable {
    let id: RadioLiteHardwarePreflightCheckID
    let status: RadioLiteHardwarePreflightStatus
    let message: String
    let details: [String: String]
}

struct RadioLiteHardwarePreflightResult: Codable, Equatable, Sendable {
    let profileId: String
    let testedAtMs: Int64
    let readOnly: Bool
    let overallStatus: RadioLiteHardwarePreflightStatus
    let checks: [RadioLiteHardwarePreflightCheck]
}

struct RadioLiteHardwarePreflightOwnership: Equatable, Sendable {
    private let draftSnapshot: RadioLiteRadioConfigurationDraft
    private let serverAddressSnapshot: String
    private let userIdSnapshot: String?

    init(draft: RadioLiteRadioConfigurationDraft, serverAddress: String, userId: String?) {
        draftSnapshot = draft
        serverAddressSnapshot = serverAddress
        userIdSnapshot = userId
    }

    func makeProfile() throws -> RadioLiteRadioProfile {
        try draftSnapshot.makeProfile()
    }

    func isCurrent(
        _ draft: RadioLiteRadioConfigurationDraft,
        serverAddress: String,
        userId: String?
    ) -> Bool {
        draft == draftSnapshot
            && serverAddress == serverAddressSnapshot
            && userId == userIdSnapshot
    }
}

enum RadioLiteConnectionKind: String, CaseIterable, Identifiable, Sendable {
    case managedSerial = "managed-serial"
    case networkRigctld = "network-rigctld"
    case hamlibDummy = "hamlib-dummy"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .managedSerial: "本机串口"
        case .networkRigctld: "网络 rigctld"
        case .hamlibDummy: "Hamlib Dummy"
        }
    }
}

enum RadioLiteRadioConfigurationError: LocalizedError, Equatable {
    case required(String)
    case invalid(String)
    case conflict(String)

    var errorDescription: String? {
        switch self {
        case .required(let field): "请填写\(field)"
        case .invalid(let field): "\(field)格式不正确"
        case .conflict(let message): message
        }
    }
}

struct RadioLiteRadioConfigurationDraft: Equatable, Sendable {
    static let standardBaudRates = [
        1_200, 2_400, 4_800, 9_600, 19_200, 38_400, 57_600, 115_200, 230_400,
    ]

    let id: String
    var name: String
    var hamlibModelId: Int
    var connectionKind: RadioLiteConnectionKind
    var catDevicePath: String
    var baudRate: Int
    var rigctldHost: String
    var rigctldPort: Int
    var pttMethod: RadioLitePTTMethod
    var pttDevicePath: String
    var pttBit: Int
    var audioInput: RadioLiteAudioEndpoint
    var audioOutput: RadioLiteAudioEndpoint
    var audioRoute: RadioLiteAudioRoute?
    var callsign: String
    var grid: String
    var hardwareTxEnabled: Bool

    init(profile: RadioLiteRadioProfile) {
        id = profile.id
        name = profile.name
        hamlibModelId = profile.hamlibModelId
        connectionKind = RadioLiteConnectionKind(rawValue: profile.connection.kind) ?? .managedSerial
        catDevicePath = profile.connection.devicePath ?? "/dev/ttyUSB0"
        baudRate = profile.connection.baudRate ?? 115_200
        rigctldHost = profile.connection.host ?? "127.0.0.1"
        rigctldPort = profile.connection.port ?? 4_532
        pttMethod = profile.ptt.method
        pttDevicePath = profile.ptt.path ?? profile.connection.devicePath ?? "/dev/ttyUSB0"
        pttBit = profile.ptt.bit ?? 0
        audioInput = profile.audioInput
        audioOutput = profile.audioOutput
        audioRoute = profile.audioRoute
        callsign = profile.station.callsign
        grid = profile.station.grid ?? ""
        hardwareTxEnabled = profile.hardwareTxEnabled
    }

    var validationMessage: String? {
        do {
            _ = try makeProfile()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func makeProfile() throws -> RadioLiteRadioProfile {
        let trimmedName = try required(name, field: "电台名称")
        let normalizedCallsign = try required(callsign, field: "本站呼号").uppercased()
        guard normalizedCallsign.range(of: "^[A-Z0-9/]{3,16}$", options: .regularExpression) != nil else {
            throw RadioLiteRadioConfigurationError.invalid("本站呼号")
        }
        let normalizedGrid = grid.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !normalizedGrid.isEmpty,
           normalizedGrid.range(of: "^[A-R]{2}[0-9]{2}(?:[A-X]{2})?$", options: .regularExpression) == nil {
            throw RadioLiteRadioConfigurationError.invalid("本站网格")
        }
        guard !audioInput.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RadioLiteRadioConfigurationError.required("音频输入")
        }
        guard !audioOutput.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RadioLiteRadioConfigurationError.required("音频输出")
        }

        let connection: RadioLiteRigConnection
        let modelId: Int
        switch connectionKind {
        case .hamlibDummy:
            modelId = 1
            connection = .init(kind: connectionKind.rawValue, devicePath: nil, baudRate: nil, host: nil, port: nil)
        case .managedSerial:
            guard hamlibModelId > 1 else { throw RadioLiteRadioConfigurationError.invalid("Hamlib 型号") }
            modelId = hamlibModelId
            let path = try required(catDevicePath, field: "CAT 串口")
            guard path.hasPrefix("/dev/") else { throw RadioLiteRadioConfigurationError.invalid("CAT 串口") }
            guard Self.standardBaudRates.contains(baudRate) else {
                throw RadioLiteRadioConfigurationError.invalid("CAT 波特率")
            }
            connection = .init(
                kind: connectionKind.rawValue,
                devicePath: path,
                baudRate: baudRate,
                host: nil,
                port: nil
            )
        case .networkRigctld:
            guard hamlibModelId > 1 else { throw RadioLiteRadioConfigurationError.invalid("Hamlib 型号") }
            modelId = hamlibModelId
            let host = try required(rigctldHost, field: "rigctld 主机")
            guard (1...65_535).contains(rigctldPort) else {
                throw RadioLiteRadioConfigurationError.invalid("rigctld 端口")
            }
            connection = .init(
                kind: connectionKind.rawValue,
                devicePath: nil,
                baudRate: nil,
                host: host,
                port: rigctldPort
            )
        }

        let ptt: RadioLitePTTConfiguration
        if connectionKind == .hamlibDummy {
            ptt = .init(method: .none)
        } else if connectionKind == .networkRigctld {
            ptt = .init(method: .rig)
        } else if pttMethod.requiresDevicePath {
            let path = try required(pttDevicePath, field: "PTT 设备")
            guard path.hasPrefix("/dev/") else { throw RadioLiteRadioConfigurationError.invalid("PTT 设备路径") }
            let bit = pttMethod.requiresBit ? pttBit : nil
            if let bit, !(0...7).contains(bit) {
                throw RadioLiteRadioConfigurationError.invalid("PTT GPIO 位")
            }
            ptt = .init(method: pttMethod, path: path, bit: bit)
        } else {
            ptt = .init(method: pttMethod)
        }
        if hardwareTxEnabled, ptt.method == .none {
            throw RadioLiteRadioConfigurationError.conflict("不控制 PTT 时不能启用真实硬件发射")
        }

        return RadioLiteRadioProfile(
            id: id,
            name: trimmedName,
            hamlibModelId: modelId,
            connection: connection,
            ptt: ptt,
            audioInput: audioInput,
            audioOutput: audioOutput,
            audioRoute: audioRoute,
            station: .init(callsign: normalizedCallsign, grid: normalizedGrid.isEmpty ? nil : normalizedGrid),
            hardwareTxEnabled: connectionKind == .hamlibDummy ? false : hardwareTxEnabled
        )
    }

    @discardableResult
    mutating func selectAudioCard(_ card: RadioLiteAudioCard) -> Bool {
        guard card.isSelectableUSBCard, let input = card.input, let output = card.output else {
            return false
        }
        let latency = audioRoute?.systemDeviceSelection?.latency ?? .balanced
        audioInput = input.endpoint
        audioOutput = output.endpoint
        audioRoute = .systemDevice(hardwareId: card.hardwareId, latency: latency)
        return true
    }

    mutating func setAudioLatency(_ latency: RadioLiteAudioLatency) {
        guard let hardwareId = audioRoute?.systemDeviceSelection?.hardwareId else { return }
        audioRoute = .systemDevice(hardwareId: hardwareId, latency: latency)
    }

    mutating func useExplicitAudioEndpoints() {
        audioRoute = nil
    }

    private func required(_ value: String, field: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RadioLiteRadioConfigurationError.required(field) }
        return trimmed
    }
}

struct RadioLiteRadioUpsertRequest: Encodable, Equatable, Sendable {
    let profile: RadioLiteRadioProfile
    let hardwareTxConfirmation: String?

    init(profile: RadioLiteRadioProfile, confirmHardwareTransmission: Bool) {
        self.profile = profile
        hardwareTxConfirmation = profile.hardwareTxEnabled && confirmHardwareTransmission
            ? profile.id
            : nil
    }
}

struct RadioLiteSavedRadioResponse: Codable, Equatable, Sendable {
    let radio: RadioLiteRadioProfile
    let reconnectRequired: Bool

    private enum CodingKeys: String, CodingKey { case radio, reconnectRequired }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        radio = try container.decode(RadioLiteRadioProfile.self, forKey: .radio)
        reconnectRequired = try container.decodeIfPresent(Bool.self, forKey: .reconnectRequired) ?? true
    }
}
