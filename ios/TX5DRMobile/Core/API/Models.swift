import Foundation

enum UserRole: String, Codable, Sendable {
    case admin
    case `operator`
    case viewer
}

struct AuthStatus: Codable, Sendable {
    let enabled: Bool
    let allowPublicViewing: Bool
}

struct LoginResponse: Codable, Sendable {
    let jwt: String
    let role: UserRole
    let label: String
    let operatorIds: [String]
    let maxOperators: Int?
}

struct AuthMeResponse: Codable, Sendable {
    let role: UserRole
    let label: String
    let operatorIds: [String]
    let tokenId: String
    let maxOperators: Int?
    let permissionGrants: [JSONValue]?
    let loginCredential: AuthMeLoginCredential?
}

struct AuthMeLoginCredential: Codable, Sendable {
    let configured: Bool
    let username: String?
    let allowSelfService: Bool
}

struct LoginCredentialSummary: Codable, Sendable {
    let username: String
    let allowSelfService: Bool
}

struct AuthTokenInfo: Codable, Identifiable, Sendable {
    let id: String
    let token: String?
    let label: String
    let role: UserRole
    let operatorIds: [String]
    let createdBy: String?
    let createdAt: Double
    let expiresAt: Double?
    let lastUsedAt: Double?
    let revoked: Bool
    let system: Bool?
    let maxOperators: Int?
    let permissionGrants: [JSONValue]?
    let allowSelfLoginCredential: Bool?
    let loginCredential: LoginCredentialSummary?
}

struct CreateAccountRequest: Codable, Sendable {
    struct Credential: Codable, Sendable {
        let username: String
        let password: String
    }

    let label: String
    let role: UserRole
    let operatorIds: [String]
    let expiresAt: Double?
    let maxOperators: Int
    let allowSelfLoginCredential: Bool
    let loginCredential: Credential
}

struct CreateAccountResponse: Codable, Identifiable, Sendable {
    let id: String
    let token: String
    let label: String
    let role: UserRole
    let operatorIds: [String]
    let maxOperators: Int?
    let allowSelfLoginCredential: Bool?
    let loginCredential: LoginCredentialSummary?
}

struct BrowserLoginCodeResponse: Codable, Sendable {
    let code: String
    let expiresAt: Double
}

struct MobilePairingCodeResponse: Codable, Sendable {
    let code: String
    let expiresAt: Double
}

struct ModeDescriptor: Codable, Hashable, Identifiable, Sendable {
    var id: String { name }
    let name: String
    let slotMs: Double
    let toleranceMs: Double
    let windowTiming: [Double]
    let transmitTiming: Double
    let encodeAdvance: Double

    static let ft8 = ModeDescriptor(
        name: "FT8", slotMs: 15_000, toleranceMs: 100,
        windowTiming: [-3_200, -1_500, -300], transmitTiming: 500, encodeAdvance: 0
    )
    static let ft4 = ModeDescriptor(
        name: "FT4", slotMs: 7_500, toleranceMs: 50,
        windowTiming: [-1_500, 0], transmitTiming: 500, encodeAdvance: 300
    )
    static let voice = ModeDescriptor(
        name: "VOICE", slotMs: 0, toleranceMs: 0,
        windowTiming: [], transmitTiming: 0, encodeAdvance: 0
    )
    static let cw = ModeDescriptor(
        name: "CW", slotMs: 0, toleranceMs: 0,
        windowTiming: [], transmitTiming: 0, encodeAdvance: 0
    )
}

struct FrequencyState: Codable, Equatable, Sendable {
    let frequency: Double
    let mode: String
    let band: String
    let description: String
    let radioMode: String?
    let radioConnected: Bool
    let source: String?
}

struct PTTStatus: Codable, Equatable, Sendable {
    let isTransmitting: Bool
    let operatorIds: [String]
    let phase: String?
    let frameId: String?
    let source: String?
}

struct TuneToneStatus: Codable, Equatable, Sendable {
    let active: Bool
    let toneHz: Double?
    let startedAt: Double?
    let maxDurationMs: Double
    let error: String?
}

struct MeterData: Codable, Equatable, Sendable {
    struct SWR: Codable, Equatable, Sendable { let raw: Double; let swr: Double; let alert: Bool }
    struct ALC: Codable, Equatable, Sendable { let raw: Double; let percent: Double; let alert: Bool }
    struct Level: Codable, Equatable, Sendable {
        let raw: Double
        let percent: Double
        let sUnits: Double
        let dbAboveS9: Double?
        let dBm: Double
        let formatted: String
        let displayStyle: String
    }
    struct Power: Codable, Equatable, Sendable {
        let raw: Double
        let percent: Double
        let watts: Double?
        let maxWatts: Double?
    }
    let swr: SWR?
    let alc: ALC?
    let level: Level?
    let power: Power?
}

struct FrameMessage: Codable, Hashable, Identifiable, Sendable {
    var id: String { "\(message)-\(freq)-\(dt)" }
    let snr: Double
    let freq: Double
    let dt: Double
    let message: String
    let confidence: Double
    let operatorId: String?
}

struct SlotPack: Codable, Sendable {
    let slotId: String
    let startMs: Double
    let endMs: Double
    let frames: [FrameMessage]
}

struct RadioOperatorConfig: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let myCallsign: String
    let myGrid: String?
    let frequency: Double
    let transmitCycles: [Double]
    let mode: ModeDescriptor?
    let logBookId: String?
}

struct SaveRadioOperatorRequest: Codable, Sendable {
    let myCallsign: String
    let myGrid: String?
    let frequency: Double
    let transmitCycles: [Double]
    let mode: ModeDescriptor?
    let logBookId: String?
}

struct RadioOperatorActionResponse: Codable, Sendable {
    let success: Bool
    let message: String
    let data: RadioOperatorConfig?
}

struct CapabilityDescriptor: Codable, Identifiable, Sendable {
    struct Range: Codable, Sendable { let min: Double; let max: Double; let step: Double? }
    struct Option: Codable, Sendable {
        let value: JSONValue
        let label: String?
        let labelI18nKey: String?
    }
    let id: String
    let category: String
    let valueType: String
    let range: Range?
    let discreteOptions: [Option]?
    let options: [Option]?
    let readable: Bool
    let writable: Bool
    let labelI18nKey: String
    let hasSurfaceControl: Bool
}

struct CapabilityState: Codable, Identifiable, Sendable {
    let id: String
    let supported: Bool
    let availability: String?
    let availabilityReason: String?
    let lastError: String?
    let value: JSONValue?
    let meta: [String: JSONValue]?
    let updatedAt: Double
}

struct CapabilityList: Codable, Sendable {
    let descriptors: [CapabilityDescriptor]
    let capabilities: [CapabilityState]
}

struct SpectrumFrame: Codable, Sendable {
    struct FrequencyRange: Codable, Sendable { let min: Double; let max: Double }
    struct BinaryFormat: Codable, Sendable { let type: String; let length: Int; let scale: Double?; let offset: Double? }
    struct BinaryData: Codable, Sendable { let data: String; let format: BinaryFormat }
    let timestamp: Double
    let kind: String
    let frequencyRange: FrequencyRange
    let binaryData: BinaryData

    var normalizedBins: [Double] {
        guard let data = Data(base64Encoded: binaryData.data) else { return [] }
        let scale = binaryData.format.scale ?? 1
        let offset = binaryData.format.offset ?? 0
        return data.withUnsafeBytes { bytes in
            let count = min(binaryData.format.length, bytes.count / MemoryLayout<Int16>.size)
            return (0..<count).map { index in
                let raw = Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))
                return Double(raw) * scale + offset
            }
        }
    }
}

struct RealtimeSessionRequest: Codable, Sendable {
    let scope: String
    let direction: String
    let transportOverride: String
    let audioCodecPreference: String
    let audioCodecCapabilities: AudioCodecCapabilities

    struct AudioCodecCapabilities: Codable, Sendable {
        let pcmS16le: Bool
    }
}

struct RealtimeTransportOffer: Codable, Sendable {
    let transport: String
    let direction: String
    let url: URL
    let token: String
    let participantIdentity: String?
    let participantName: String?
}

struct RealtimeSessionResponse: Codable, Sendable {
    let scope: String
    let direction: String
    let preferredTransport: String
    let offers: [RealtimeTransportOffer]
}

struct DataResponse<Value: Codable & Sendable>: Codable, Sendable {
    let success: Bool
    let data: Value
}

struct OperatorListResponse: Codable, Sendable {
    let success: Bool
    let data: [RadioOperatorConfig]
}

struct GenericSuccessResponse: Codable, Sendable {
    let success: Bool
    let message: String?
}

struct LogbookHealth: Codable, Sendable {
    let state: String
    let readable: Bool
    let writable: Bool
    let updatedAt: Double
}

struct LogbookInfo: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let description: String?
    let fileName: String
    let storageKind: String
    let createdAt: Double
    let lastUsed: Double
    let isActive: Bool
    let health: LogbookHealth
}

struct LogbookListResponse: Codable, Sendable {
    let success: Bool
    let data: [LogbookInfo]
}

struct QSORecord: Codable, Identifiable, Sendable {
    let id: String
    let callsign: String
    let grid: String?
    let frequency: Double
    let mode: String
    let submode: String?
    let startTime: Double
    let endTime: Double?
    let reportSent: String?
    let reportReceived: String?
    let messageHistory: [String]
    let comment: String?
    let myCallsign: String?
    let myGrid: String?
    let qth: String?
    let dxccEntity: String?
    let lotwQslSent: String?
    let lotwQslReceived: String?
    let qrzQslSent: String?
    let qrzQslReceived: String?
    let notes: String?
}

struct QSOListResponse: Codable, Sendable {
    struct Metadata: Codable, Sendable {
        let total: Int
        let totalRecords: Int
        let offset: Int
        let limit: Int
        let hasFilters: Bool
    }

    let success: Bool
    let data: [QSORecord]
    let meta: Metadata
}

struct CreateQSORequest: Codable, Sendable {
    let callsign: String
    let frequency: Double
    let mode: String
    let submode: String?
    let startTime: Double
    let endTime: Double?
    let grid: String?
    let qth: String?
    let reportSent: String?
    let reportReceived: String?
    let messageHistory: [String]
    let comment: String?
    let notes: String?
}

struct QSOActionResponse: Codable, Sendable {
    let success: Bool
    let message: String
    let data: QSORecord?
}
