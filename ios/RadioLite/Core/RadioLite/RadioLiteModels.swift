import Foundation

enum RadioLiteUserRole: String, Codable, Sendable {
    case admin
    case `operator`
}
struct RadioLiteUser: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let username: String
    let role: RadioLiteUserRole
    let canTransmit: Bool
    let enabled: Bool
    let mustChangePassword: Bool
    let authRevision: Int
    let createdAtMs: Int64
    let updatedAtMs: Int64
    let lastLoginAtMs: Int64?
}

struct RadioLitePrincipal: Codable, Equatable, Sendable {
    let userId: String
    let deviceId: String?
    let role: RadioLiteUserRole
    let canTransmit: Bool
}

struct RadioLiteDeviceCredentials: Codable, Equatable, Sendable {
    let deviceId: String
    let accessToken: String
    let accessExpiresAtMs: Int64
    let refreshToken: String
    let refreshExpiresAtMs: Int64
}

struct RadioLiteBrowserCredentials: Codable, Equatable, Sendable {
    let sessionToken: String
    let csrfToken: String
    let createdAtMs: Int64
}

enum RadioLiteCredential: Codable, Equatable, Sendable {
    case device(RadioLiteDeviceCredentials)
    case browser(RadioLiteBrowserCredentials)

    private enum CodingKeys: String, CodingKey { case kind, device, browser }
    private enum Kind: String, Codable { case device, browser }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .device:
            self = .device(try container.decode(RadioLiteDeviceCredentials.self, forKey: .device))
        case .browser:
            self = .browser(try container.decode(RadioLiteBrowserCredentials.self, forKey: .browser))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .device(let value):
            try container.encode(Kind.device, forKey: .kind)
            try container.encode(value, forKey: .device)
        case .browser(let value):
            try container.encode(Kind.browser, forKey: .kind)
            try container.encode(value, forKey: .browser)
        }
    }
}

struct RadioLiteStoredLogin: Codable, Equatable, Sendable {
    let serverAddress: String
    let credential: RadioLiteCredential
    let username: String?
}

struct RadioLiteRigConnection: Codable, Equatable, Sendable {
    let kind: String
    let devicePath: String?
    let baudRate: Int?
    let host: String?
    let port: Int?
}

struct RadioLiteAudioEndpoint: Codable, Equatable, Sendable {
    let backend: String
    let id: String
    let label: String?
}

struct RadioLiteStationIdentity: Codable, Equatable, Sendable {
    let callsign: String
    let grid: String?
}

enum RadioLitePTTMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case rig = "RIG"
    case dtr = "DTR"
    case rts = "RTS"
    case parallel = "Parallel"
    case cm108 = "CM108"
    case gpio = "GPIO"
    case gpion = "GPION"
    case none = "None"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rig: "电台 CAT"
        case .dtr: "串口 DTR"
        case .rts: "串口 RTS"
        case .parallel: "并口"
        case .cm108: "CM108 GPIO"
        case .gpio: "GPIO（高电平发射）"
        case .gpion: "GPIO（低电平发射）"
        case .none: "不控制 PTT"
        }
    }

    var requiresDevicePath: Bool {
        switch self {
        case .dtr, .rts, .parallel, .cm108, .gpio, .gpion: true
        case .rig, .none: false
        }
    }

    var requiresBit: Bool { self == .gpio || self == .gpion }
}

struct RadioLitePTTConfiguration: Codable, Equatable, Sendable {
    let method: RadioLitePTTMethod
    let path: String?
    let bit: Int?

    init(method: RadioLitePTTMethod, path: String? = nil, bit: Int? = nil) {
        self.method = method
        self.path = path
        self.bit = bit
    }
}

struct RadioLiteRadioProfile: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let hamlibModelId: Int
    let connection: RadioLiteRigConnection
    let ptt: RadioLitePTTConfiguration
    let audioInput: RadioLiteAudioEndpoint
    let audioOutput: RadioLiteAudioEndpoint
    let station: RadioLiteStationIdentity
    let hardwareTxEnabled: Bool

    init(
        id: String,
        name: String,
        hamlibModelId: Int,
        connection: RadioLiteRigConnection,
        ptt: RadioLitePTTConfiguration,
        audioInput: RadioLiteAudioEndpoint,
        audioOutput: RadioLiteAudioEndpoint,
        station: RadioLiteStationIdentity,
        hardwareTxEnabled: Bool
    ) {
        self.id = id
        self.name = name
        self.hamlibModelId = hamlibModelId
        self.connection = connection
        self.ptt = ptt
        self.audioInput = audioInput
        self.audioOutput = audioOutput
        self.station = station
        self.hardwareTxEnabled = hardwareTxEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, hamlibModelId, connection, ptt, audioInput, audioOutput, station, hardwareTxEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        hamlibModelId = try container.decode(Int.self, forKey: .hamlibModelId)
        let decodedConnection = try container.decode(RadioLiteRigConnection.self, forKey: .connection)
        connection = decodedConnection
        ptt = try container.decodeIfPresent(RadioLitePTTConfiguration.self, forKey: .ptt)
            ?? .init(method: decodedConnection.kind == "hamlib-dummy" ? .none : .rig)
        audioInput = try container.decode(RadioLiteAudioEndpoint.self, forKey: .audioInput)
        audioOutput = try container.decode(RadioLiteAudioEndpoint.self, forKey: .audioOutput)
        station = try container.decode(RadioLiteStationIdentity.self, forKey: .station)
        hardwareTxEnabled = try container.decode(Bool.self, forKey: .hardwareTxEnabled)
    }
}

struct RadioLiteRadiosResponse: Codable, Equatable, Sendable {
    let version: Int
    let radios: [RadioLiteRadioProfile]
}

struct RadioLiteAuthWelcome: Codable, Equatable, Sendable {
    let t: String
    let protocolVersion: Int
    let channel: String
    let principal: RadioLitePrincipal
    let radios: [RadioLiteRadioProfile]
}

struct RadioLiteRigState: Codable, Equatable, Sendable {
    let frequencyHz: Int64
    let mode: String
    let passbandHz: Int
    let ptt: Bool
}

enum RadioLiteRigMode: String, Codable, CaseIterable, Identifiable, Equatable, Hashable, Sendable {
    case usb = "USB"
    case dataUpper = "DATA-U"
    case lsb = "LSB"
    case dataLower = "DATA-L"
    case cw = "CW"
    case cwr = "CWR"
    case am = "AM"
    case fm = "FM"

    var id: String { rawValue }
    var label: String { rawValue }

    var hamlibMode: String {
        switch self {
        case .dataUpper: "PKTUSB"
        case .dataLower: "PKTLSB"
        default: rawValue
        }
    }

    func matches(readback: String?) -> Bool {
        guard let readback else { return false }
        let normalized = readback.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        switch self {
        case .dataUpper:
            return ["DATA-U", "PKTUSB", "USB-D", "USB-DATA", "DIGU"].contains(normalized)
        case .dataLower:
            return ["DATA-L", "PKTLSB", "LSB-D", "LSB-DATA", "DIGL"].contains(normalized)
        default:
            return normalized == rawValue
        }
    }

    static func handlesFailure(code: String) -> Bool {
        ["rig_mode_rejected", "rig_mode_unconfirmed", "hamlib_report"].contains(code)
    }

    static func failureNotice(code: String, requested: RadioLiteRigMode) -> String? {
        guard handlesFailure(code: code) else { return nil }
        let suffix = requested == .dataUpper
            ? "FT8 通常使用 DATA-U（Hamlib PKTUSB）。"
            : "请选择当前电台支持的其他模式。"
        return "当前电台不支持 \(requested.label)；已保留原模式。\(suffix)"
    }
}

struct RadioLiteMediaPolicy: Codable, Equatable, Sendable {
    let tier: String
    let opusBitrate: Int
    let opusFrameMs: Int
    let spectrumBins: Int
    let spectrumFps: Int
}

struct RadioLiteDigitalDecode: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let message: String
    let snrDb: Double
    let deltaTimeSeconds: Double
    let audioFrequencyHz: Int
    let confidence: Double
}

struct RadioLiteDigitalDecodeBatch: Codable, Identifiable, Equatable, Sendable {
    let radioId: String
    let mode: String
    let slotStartMs: Int64
    let slotEndMs: Int64
    let receivedAtMs: Int64
    let revision: Int
    let decodes: [RadioLiteDigitalDecode]

    var id: String { "\(radioId):\(mode):\(slotStartMs)" }
}

struct RadioLiteDigitalDecodeSnapshot: Codable, Equatable, Sendable {
    let radioId: String
    let revision: Int
    let batches: [RadioLiteDigitalDecodeBatch]
}

struct RadioLiteCallQueueEntry: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let radioId: String
    let ownerId: String
    let targetCallsign: String
    let targetGrid: String?
    let mode: String
    let audioFrequencyHz: Int
    let txParity: String
    let sourceDecodeId: String?
    let enqueuedAtMs: Int64
    let status: String
}

struct RadioLiteCallQueueSnapshot: Codable, Equatable, Sendable {
    let radioId: String
    let revision: Int
    let activeId: String?
    let entries: [RadioLiteCallQueueEntry]
}

struct RadioLiteAutoQSO: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let radioId: String
    let queueEntryId: String
    let targetCallsign: String
    let targetGrid: String?
    let myCallsign: String
    let myGrid: String
    let mode: String
    let dialFrequencyHz: Int64
    let audioFrequencyHz: Int
    let txParity: String
    let phase: String
    let outboundMessage: String?
    let reportSent: String?
    let reportReceived: String?
    let callAttempts: Int
    let reportAttempts: Int
    let finalAttempts: Int
    let startedAtMs: Int64
    let endedAtMs: Int64?
    let lastActivityAtMs: Int64
    let lastInboundMessage: String?
    let failureReason: String?
}

struct RadioLiteDigitalSnapshot: Codable, Equatable, Sendable {
    let t: String
    let radioId: String
    let decodes: RadioLiteDigitalDecodeSnapshot
    let queue: RadioLiteCallQueueSnapshot
    let qso: RadioLiteAutoQSO?
}

struct RadioLiteQSORecord: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let radioId: String?
    let source: String
    let call: String
    let startedAtMs: Int64
    let endedAtMs: Int64?
    let frequencyHz: Int64?
    let band: String
    let mode: String
    let submode: String?
    let rstSent: String?
    let rstReceived: String?
    let grid: String?
    let myCall: String?
    let myGrid: String?
    let fields: [String: String]
}

struct RadioLiteLogPage: Codable, Equatable, Sendable {
    let records: [RadioLiteQSORecord]
    let total: Int
    let limit: Int
    let offset: Int
}

struct RadioLiteGridSummary: Codable, Identifiable, Equatable, Sendable {
    let grid: String
    let latitude: Double
    let longitude: Double
    let latitudeSpan: Double
    let longitudeSpan: Double
    let qsoCount: Int
    let lastQsoAtMs: Int64
    let bands: [String: Int]
    let modes: [String: Int]

    var id: String { grid }
}

struct RadioLiteGridResponse: Codable, Equatable, Sendable {
    let resolution: Int
    let grids: [RadioLiteGridSummary]
}

struct RadioLiteManualQSO: Encodable, Equatable, Sendable {
    let radioId: String
    let call: String
    let startedAtMs: Int64
    let endedAtMs: Int64?
    let frequencyHz: Int64
    let band: String?
    let mode: String
    let submode: String?
    let rstSent: String?
    let rstReceived: String?
    let grid: String?
    let txPowerWatts: Double?
    let comment: String?
}

struct RadioLiteSavedQSO: Codable, Equatable, Sendable {
    let record: RadioLiteQSORecord
    let created: Bool
}

struct RadioLiteIssuedCode: Codable, Equatable, Sendable {
    let code: String
    let expiresAtMs: Int64
}

struct RadioLiteUsersResponse: Codable, Equatable, Sendable {
    let users: [RadioLiteUser]
}

struct RadioLiteCreatedUserResponse: Codable, Equatable, Sendable {
    let user: RadioLiteUser
}

struct RadioLiteSetupStatus: Codable, Equatable, Sendable {
    let initializationRequired: Bool
}

struct RadioLiteServerFeatures: Codable, Equatable, Sendable {
    let hardwarePreflight: Bool
    let safetyEvents: Bool
}

struct RadioLiteHealth: Codable, Equatable, Sendable {
    let status: String
    let service: String
    let protocolVersion: Int
    let features: RadioLiteServerFeatures?
}
