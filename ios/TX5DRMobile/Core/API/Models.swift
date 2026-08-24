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

struct SupportedRig: Codable, Identifiable, Sendable {
    var id: Int { rigModel }
    let rigModel: Int
    let mfgName: String
    let modelName: String
}

struct SupportedRigsResponse: Codable, Sendable {
    let rigs: [SupportedRig]
}

struct SerialPortInfo: Codable, Identifiable, Sendable {
    var id: String { path }
    let path: String
    let friendlyName: String?
    let manufacturer: String?
    let serialNumber: String?
}

struct SerialPortsResponse: Codable, Sendable {
    let ports: [SerialPortInfo]
}

struct AudioDeviceInfo: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let isDefault: Bool
    let channels: Int
    let sampleRate: Double
    let sampleRates: [Int]?
    let type: String
    let availability: String?
    let backend: String?
    let detail: String?
    let hardwareId: String?
}

struct AudioDevicesResponse: Codable, Sendable {
    let inputDevices: [AudioDeviceInfo]
    let outputDevices: [AudioDeviceInfo]
    let inputBufferSizes: [Int]
    let outputBufferSizes: [Int]
}

struct RadioProfile: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let radio: JSONValue
    let audio: JSONValue
    let audioLockedToRadio: Bool
    let createdAt: Double
    let updatedAt: Double
    let description: String?

    var radioType: String { radio["type"]?.stringValue ?? "unknown" }

    var endpointSummary: String {
        switch radioType {
        case "network":
            let host = radio["network"]?["host"]?.stringValue ?? "—"
            let port = radio["network"]?["port"]?.intValue.map(String.init) ?? "—"
            return "Rigctld \(host):\(port)"
        case "serial":
            return radio["serial"]?["path"]?.stringValue ?? "串口"
        case "icom-wlan":
            return "ICOM WLAN \(radio["icomWlan"]?["ip"]?.stringValue ?? "—")"
        case "tci":
            let host = radio["tci"]?["host"]?.stringValue ?? "—"
            let port = radio["tci"]?["port"]?.intValue.map(String.init) ?? "—"
            return "TCI \(host):\(port)"
        case "none": return "仅监听"
        default: return radioType
        }
    }
}

struct ProfileListResponse: Codable, Sendable {
    let profiles: [RadioProfile]
    let activeProfileId: String?
}

struct ProfileActionResponse: Codable, Sendable {
    let success: Bool
    let profile: RadioProfile?
    let message: String?
}

struct ActivateProfileResponse: Codable, Sendable {
    let success: Bool
    let profile: RadioProfile
    let wasRunning: Bool
}

enum RadioPowerTarget: String, Codable, CaseIterable, Identifiable, Sendable {
    case on
    case off
    case standby
    case operate

    var id: String { rawValue }
}

struct RadioPowerSupportInfo: Codable, Sendable {
    struct RigInfo: Codable, Sendable {
        let mfgName: String
        let modelName: String
    }

    let profileId: String
    let canPowerOn: Bool
    let canPowerOff: Bool
    let supportedStates: [RadioPowerTarget]
    let reason: String?
    let rigInfo: RigInfo?
}

struct RadioPowerResponse: Codable, Sendable {
    let success: Bool
    let target: RadioPowerTarget
    let state: String
}

struct RadioPowerStateEvent: Codable, Equatable, Sendable {
    let profileId: String?
    let state: String
    let stage: String
    let errorKey: String?
    let errorDetail: String?
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

struct SquelchStatus: Codable, Equatable, Sendable {
    let supported: Bool
    let open: Bool?
    let muted: Bool
    let source: String
    let updatedAt: Double
}

struct RadioTransmissionInterruption: Codable, Equatable, Sendable {
    let reason: String
    let message: String
    let recommendation: String
}

struct VoiceKeyerSlot: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let index: Int
    let label: String
    let hasAudio: Bool
    let durationMs: Int
    let updatedAt: Double?
    let repeatEnabled: Bool
    let repeatIntervalSec: Int
}

struct VoiceKeyerPanel: Codable, Equatable, Sendable {
    let callsign: String
    let slotCount: Int
    let maxSlotCount: Int
    let slots: [VoiceKeyerSlot]
}

enum VoiceKeyerMode: String, Codable, Equatable, Sendable {
    case idle
    case playing
    case repeatWaiting = "repeat-waiting"
    case stopping
    case error
}

struct VoiceKeyerStatus: Codable, Equatable, Sendable {
    let active: Bool
    let callsign: String?
    let slotId: String?
    let mode: VoiceKeyerMode
    let repeating: Bool
    let startedBy: String?
    let startedByLabel: String?
    let nextRunAt: Double?
    let error: String?
}

struct VoiceKeyerPanelResponse: Codable, Sendable {
    let success: Bool
    let panel: VoiceKeyerPanel
}

struct VoiceKeyerSlotUpdate: Codable, Sendable {
    let label: String?
    let repeatEnabled: Bool?
    let repeatIntervalSec: Int?

    init(label: String? = nil, repeatEnabled: Bool? = nil, repeatIntervalSec: Int? = nil) {
        self.label = label
        self.repeatEnabled = repeatEnabled
        self.repeatIntervalSec = repeatIntervalSec
    }
}

enum CWKeyerBackend: String, Codable, CaseIterable, Identifiable, Sendable {
    case cat
    case serial

    var id: String { rawValue }
}

struct CWKeyerConfig: Codable, Equatable, Sendable {
    let backend: CWKeyerBackend
    let keyPort: String
    let keyMethod: String
    let keyActiveLevel: String
    let wpm: Int
}

enum CWKeyerMode: String, Codable, Equatable, Sendable {
    case idle
    case keying
    case playing
    case repeatWaiting = "repeat-waiting"
    case error
}

struct CWKeyerStatus: Codable, Equatable, Sendable {
    let active: Bool
    let mode: CWKeyerMode
    let startedBy: String?
    let startedByLabel: String?
    let messageId: String?
    let nextRunAt: Double?
    let error: String?
    let backend: CWKeyerBackend?
    let backendAvailable: Bool?
    let backendError: String?
    let currentText: String?
    let lastText: String?
}

struct CWMessageSlot: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let index: Int
    let label: String
    let text: String
    let repeatEnabled: Bool
    let repeatIntervalSec: Int
}

struct CWMessagePanel: Codable, Equatable, Sendable {
    let callsign: String
    let slotCount: Int
    let maxSlotCount: Int
    let slots: [CWMessageSlot]
}

struct CWMessagePanelResponse: Codable, Sendable {
    let success: Bool
    let panel: CWMessagePanel
}

struct CWKeyerConfigResponse: Codable, Sendable {
    let success: Bool
    let config: CWKeyerConfig
}

struct CWMessageSlotUpdate: Codable, Sendable {
    let label: String?
    let text: String?
    let repeatEnabled: Bool?
    let repeatIntervalSec: Int?

    init(label: String? = nil, text: String? = nil, repeatEnabled: Bool? = nil, repeatIntervalSec: Int? = nil) {
        self.label = label
        self.text = text
        self.repeatEnabled = repeatEnabled
        self.repeatIntervalSec = repeatIntervalSec
    }
}

enum CWDecoderBackend: String, Codable, CaseIterable, Identifiable, Sendable {
    case deepCWONNX = "deepcw-onnx"
    var id: String { rawValue }
}

enum CWDecoderRuntimeBackend: String, Codable, CaseIterable, Identifiable, Sendable {
    case cpu
    case cuda
    case coreml
    case directml
    case wasm
    case webgpu
    var id: String { rawValue }
}

enum CWDecoderModelSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case tiny
    case small
    var id: String { rawValue }
}

struct CWDecoderConfig: Codable, Equatable, Sendable {
    let enabled: Bool
    let backend: CWDecoderBackend
    let runtimeBackend: CWDecoderRuntimeBackend
    let modelSize: CWDecoderModelSize
    let language: String
    let mode: String
    let targetFreqHz: Int
    let filterWidthHz: Int
    let windowSeconds: Double
    let decodeIntervalMs: Int
    let muteWhileTransmitting: Bool
    let workerCount: Int
    let minCommitChars: Int
    let commitStability: Int
    let maxPendingAgeMs: Int
}

struct CWDecoderConfigUpdate: Codable, Sendable {
    let enabled: Bool?
    let backend: CWDecoderBackend?
    let runtimeBackend: CWDecoderRuntimeBackend?
    let modelSize: CWDecoderModelSize?
    let language: String?
    let mode: String?
    let targetFreqHz: Int?
    let filterWidthHz: Int?
    let windowSeconds: Double?
    let decodeIntervalMs: Int?
    let muteWhileTransmitting: Bool?
    let workerCount: Int?
    let minCommitChars: Int?
    let commitStability: Int?
    let maxPendingAgeMs: Int?

    init(
        enabled: Bool? = nil,
        backend: CWDecoderBackend? = nil,
        runtimeBackend: CWDecoderRuntimeBackend? = nil,
        modelSize: CWDecoderModelSize? = nil,
        language: String? = nil,
        mode: String? = nil,
        targetFreqHz: Int? = nil,
        filterWidthHz: Int? = nil,
        windowSeconds: Double? = nil,
        decodeIntervalMs: Int? = nil,
        muteWhileTransmitting: Bool? = nil,
        workerCount: Int? = nil,
        minCommitChars: Int? = nil,
        commitStability: Int? = nil,
        maxPendingAgeMs: Int? = nil
    ) {
        self.enabled = enabled
        self.backend = backend
        self.runtimeBackend = runtimeBackend
        self.modelSize = modelSize
        self.language = language
        self.mode = mode
        self.targetFreqHz = targetFreqHz
        self.filterWidthHz = filterWidthHz
        self.windowSeconds = windowSeconds
        self.decodeIntervalMs = decodeIntervalMs
        self.muteWhileTransmitting = muteWhileTransmitting
        self.workerCount = workerCount
        self.minCommitChars = minCommitChars
        self.commitStability = commitStability
        self.maxPendingAgeMs = maxPendingAgeMs
    }
}

struct CWDecoderBackendDescriptor: Codable, Identifiable, Equatable, Sendable {
    let id: CWDecoderBackend
    let name: String
    let available: Bool
    let runtimeBackends: [CWDecoderRuntimeBackend]
    let modelSizes: [CWDecoderModelSize]
    let languages: [String]
    let modes: [String]
    let version: String?
    let label: String?
    let model: String?
    let runtime: String?
    let attributionName: String?
    let sourceUrl: String?
    let license: String?
    let error: String?
    let reason: String?
}

enum CWDecoderStatusState: String, Codable, Equatable, Sendable {
    case disabled
    case starting
    case listening
    case decoding
    case muted
    case error
}

struct CWDecoderStatus: Codable, Equatable, Sendable {
    let enabled: Bool
    let state: CWDecoderStatusState
    let config: CWDecoderConfig
    let backend: CWDecoderBackendDescriptor?
    let muted: Bool
    let active: Bool
    let lastDecodeAt: Double?
    let lastError: String?
    let running: Bool?
    let backendId: CWDecoderBackend?
    let pendingText: String?
    let committedText: String?
    let queuedSamples: Int?
    let updatedAt: Double

    var isRunning: Bool {
        running ?? (active || state == .listening || state == .decoding || state == .muted)
    }
}

struct CWDecoderCharacterSpan: Codable, Equatable, Sendable {
    let char: String
    let startFrame: Int
    let endFrame: Int
}

struct CWDecoderWordSpaceSpan: Codable, Equatable, Sendable {
    let startFrame: Int
    let endFrame: Int
}

struct CWDecoderTranscriptSegment: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let sessionId: String
    let sequence: Int
    let text: String
    let plainText: String?
    let finalized: Bool
    let prependSpace: Bool
    let confidence: Double?
    let targetFreqHz: Double?
    let filterWidthHz: Double?
    let characterSpans: [CWDecoderCharacterSpan]?
    let wordSpaceSpans: [CWDecoderWordSpaceSpan]?
    let startedAt: Double?
    let endedAt: Double?
    let updatedAt: Double
    let wpm: Double?
}

struct CWDecoderPendingSegment: Codable, Equatable, Sendable {
    let sessionId: String
    let version: Int
    let text: String
    let plainText: String?
    let finalized: Bool
    let confidence: Double?
    let targetFreqHz: Double?
    let filterWidthHz: Double?
    let characterSpans: [CWDecoderCharacterSpan]?
    let wordSpaceSpans: [CWDecoderWordSpaceSpan]?
    let updatedAt: Double
}

struct CWDecoderConfigResponse: Codable, Sendable {
    let success: Bool
    let config: CWDecoderConfig
    let status: CWDecoderStatus
}

struct CWDecoderBackendsResponse: Codable, Sendable {
    let success: Bool
    let backends: [CWDecoderBackendDescriptor]
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

struct AssistedQueueRow: Codable, Identifiable, Sendable {
    var id: String { entryId }
    let entryId: String
    let callsign: String
    let order: Int
    let draggable: Bool
    let displayState: String
    let tone: String
    let icon: String
    let pauseReason: String?
    let noResponseCycles: Int?
    let targetGrid: String?
    let lastSnr: Double?
    let lastHeardCyclesAgo: Int?
}

struct AssistedQueueSnapshot: Codable, Sendable {
    let version: Int
    let activeEntryId: String?
    let rows: [AssistedQueueRow]
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

enum SpectrumKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case audio
    case radioSDR = "radio-sdr"
    case openWebRXSDR = "openwebrx-sdr"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .audio: "音频"
        case .radioSDR: "电台 SDR"
        case .openWebRXSDR: "OpenWebRX"
        }
    }
}

enum SpectrumSourceFrequencyRangeMode: String, Codable, Sendable {
    case absolute
    case baseband
}

struct SpectrumSourceAvailability: Codable, Equatable, Sendable {
    let kind: SpectrumKind
    let supported: Bool
    let available: Bool
    let defaultSelected: Bool
    let reason: String?
    let sourceBinCount: Int?
    let displayBinCount: Int
    let supportsWaterfall: Bool
    let frequencyRangeMode: SpectrumSourceFrequencyRangeMode
}

struct SpectrumCapabilities: Codable, Equatable, Sendable {
    let profileId: String?
    let defaultKind: SpectrumKind
    let sources: [SpectrumSourceAvailability]

    var availableSources: [SpectrumSourceAvailability] {
        sources.filter(\.available)
    }

    func source(for kind: SpectrumKind?) -> SpectrumSourceAvailability? {
        guard let kind else { return nil }
        return sources.first { $0.kind == kind }
    }
}

struct SpectrumSubscriptionChange: Codable, Equatable, Sendable {
    let requestedKind: SpectrumKind?
    let effectiveKind: SpectrumKind?
    let ok: Bool
    let reason: String?
    let capabilities: SpectrumCapabilities?
}

enum SpectrumSessionSourceMode: String, Codable, Sendable {
    case baseband
    case center
    case fixed
    case scrollCenter = "scroll-center"
    case scrollFixed = "scroll-fixed"
    case full
    case detail
    case unknown
}

enum SpectrumSessionFrequencyRangeMode: String, Codable, Sendable {
    case baseband
    case absoluteCenter = "absolute-center"
    case absoluteFixed = "absolute-fixed"
    case absoluteWindowed = "absolute-windowed"
}

enum SpectrumSessionControlID: String, Codable, Sendable {
    case zoomStep = "zoom-step"
    case digitalWindowToggle = "digital-window-toggle"
    case openWebRXDetailToggle = "openwebrx-detail-toggle"
    case viewportZoom = "viewport-zoom"
}

enum SpectrumSessionControlAction: String, Codable, Sendable {
    case zoomIn = "in"
    case zoomOut = "out"
    case toggle
}

enum SpectrumSessionControlKind: String, Codable, Sendable {
    case server
    case local
}

struct SpectrumSessionControl: Codable, Equatable, Sendable {
    let id: SpectrumSessionControlID
    let action: SpectrumSessionControlAction
    let kind: SpectrumSessionControlKind
    let visible: Bool
    let enabled: Bool
    let active: Bool
    let pending: Bool

    var key: String { "\(id.rawValue)-\(action.rawValue)" }
}

struct SpectrumSessionVoiceState: Codable, Equatable, Sendable {
    enum OffsetModel: String, Codable, Sendable {
        case upper
        case lower
        case symmetric
    }

    let radioMode: String?
    let bandwidthLabel: String?
    let occupiedBandwidthHz: Double?
    let offsetModel: OffsetModel?
}

struct SpectrumSessionPresetMarker: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let frequency: Double
    let label: String
    let description: String?
    let clickable: Bool
}

struct SpectrumSessionInteractionState: Codable, Equatable, Sendable {
    enum FrequencyGestureTarget: String, Codable, Sendable {
        case operatorTX = "operator-tx"
        case radioFrequency = "radio-frequency"
    }

    enum RangeMode: String, Codable, Sendable {
        case automatic = "auto"
        case manual
    }

    let showTxMarkers: Bool
    let showRxMarkers: Bool
    let canDragTx: Bool
    let canRightClickSetFrequency: Bool
    let canDoubleClickSetFrequency: Bool
    let canDragFrequency: Bool
    let frequencyGestureTarget: FrequencyGestureTarget?
    let frequencyStepHz: Int?
    let presetMarkers: [SpectrumSessionPresetMarker]
    let canDragVoiceOverlay: Bool
    let showVoiceOverlay: Bool
    let canLocalViewportZoom: Bool
    let canLocalViewportPan: Bool
    let supportsManualRange: Bool
    let supportsAutoRange: Bool
    let defaultRangeMode: RangeMode?
}

struct SpectrumSessionState: Codable, Equatable, Sendable {
    let kind: SpectrumKind?
    let sourceMode: SpectrumSessionSourceMode
    let frequencyRangeMode: SpectrumSessionFrequencyRangeMode
    let displayRange: SpectrumFrame.FrequencyRange?
    let centerFrequency: Double?
    let currentRadioFrequency: Double?
    let standardFrequencyHz: Double?
    let edgeLowHz: Double?
    let edgeHighHz: Double?
    let spanHz: Double?
    let voice: SpectrumSessionVoiceState
    let interaction: SpectrumSessionInteractionState
    let controls: [SpectrumSessionControl]
}

struct SpectrumFrame: Codable, Equatable, Sendable {
    struct FrequencyRange: Codable, Equatable, Sendable {
        let min: Double
        let max: Double
    }

    struct BinaryFormat: Codable, Equatable, Sendable {
        let type: String
        let length: Int
        let scale: Double?
        let offset: Double?
    }

    struct BinaryData: Codable, Equatable, Sendable {
        let data: String
        let format: BinaryFormat
    }

    struct Meta: Codable, Equatable, Sendable {
        let sourceBinCount: Int
        let displayBinCount: Int
        let centerFrequency: Double?
        let spanHz: Double?
        let profileId: String?
        let radioModel: String?
    }

    let timestamp: Double
    let kind: SpectrumKind
    let frequencyRange: FrequencyRange
    let binaryData: BinaryData
    let meta: Meta?

    var normalizedBins: [Double] {
        guard binaryData.format.type == "int16",
              let data = Data(base64Encoded: binaryData.data) else { return [] }
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

enum SpectrumSourceSelector {
    static let priority: [SpectrumKind] = [.openWebRXSDR, .radioSDR, .audio]

    static func pick(capabilities: SpectrumCapabilities, preferred: SpectrumKind?) -> SpectrumKind? {
        if let preferred, capabilities.source(for: preferred)?.available == true {
            return preferred
        }
        return priority.first { capabilities.source(for: $0)?.available == true }
    }
}

struct SpectrumWaterfallRow: Equatable, Sendable {
    let timestamp: Double
    let bins: [Double]
}

struct SpectrumHistoryBuffer: Equatable, Sendable {
    private struct Signature: Equatable, Sendable {
        let kind: SpectrumKind
        let range: SpectrumFrame.FrequencyRange
        let binCount: Int
    }

    let maxRows: Int
    private(set) var rows: [SpectrumWaterfallRow] = []
    private(set) var latestBins: [Double] = []
    private(set) var frequencyRange: SpectrumFrame.FrequencyRange?
    private(set) var kind: SpectrumKind?
    private var signature: Signature?

    init(maxRows: Int = 120) {
        self.maxRows = max(1, maxRows)
    }

    mutating func append(frame: SpectrumFrame) {
        let bins = frame.normalizedBins
        guard !bins.isEmpty else { return }

        let nextSignature = Signature(kind: frame.kind, range: frame.frequencyRange, binCount: bins.count)
        if signature != nextSignature {
            rows.removeAll(keepingCapacity: true)
            signature = nextSignature
        }

        latestBins = bins
        frequencyRange = frame.frequencyRange
        kind = frame.kind
        rows.append(SpectrumWaterfallRow(timestamp: frame.timestamp, bins: bins))
        if rows.count > maxRows {
            rows.removeFirst(rows.count - maxRows)
        }
    }

    mutating func reset() {
        rows.removeAll(keepingCapacity: true)
        latestBins = []
        frequencyRange = nil
        kind = nil
        signature = nil
    }
}

struct PSKReporterStats: Codable, Equatable, Sendable {
    let lastReportTime: Double?
    let todayReportCount: Int
    let totalReportCount: Int
    let lastError: String?
    let consecutiveFailures: Int
}

struct PSKReporterConfig: Codable, Equatable, Sendable {
    let enabled: Bool
    let receiverCallsign: String
    let receiverLocator: String
    let decodingSoftware: String
    let antennaInformation: String
    let reportIntervalSeconds: Int
    let useTestServer: Bool
    let stats: PSKReporterStats
}

struct PSKReporterConfigUpdate: Codable, Equatable, Sendable {
    let enabled: Bool
    let receiverCallsign: String
    let receiverLocator: String
    let antennaInformation: String
    let reportIntervalSeconds: Int
    let useTestServer: Bool
}

struct PSKReporterStatus: Codable, Equatable, Sendable {
    let enabled: Bool
    let configValid: Bool
    let activeCallsign: String?
    let activeLocator: String?
    let pendingSpots: Int
    let lastReportTime: Double?
    let nextReportIn: Int?
    let isReporting: Bool
    let lastError: String?
}

struct RigctldBridgeConfig: Codable, Equatable, Sendable {
    let enabled: Bool
    let bindAddress: String
    let port: Int
    let readOnly: Bool
}

struct RigctldListenAddress: Codable, Equatable, Sendable {
    let host: String
    let port: Int
}

struct RigctldClientSnapshot: Codable, Equatable, Identifiable, Sendable {
    let id: Int
    let peer: String
    let connectedAt: Double
    let lastCommand: String?
    let lastCommandAt: Double?
}

struct RigctldStatus: Codable, Equatable, Sendable {
    let config: RigctldBridgeConfig
    let running: Bool
    let address: RigctldListenAddress?
    let clients: [RigctldClientSnapshot]
    let error: String?
}

struct OpenWebRXProfileCoverage: Codable, Equatable, Sendable {
    let profileId: String
    let profileName: String
    let centerFreq: Double
    let sampRate: Double
    let lastUpdated: Double
}

struct OpenWebRXStation: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let url: String
    let description: String?
    let profileCoverages: [OpenWebRXProfileCoverage]?
}

struct OpenWebRXProfile: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
}

struct OpenWebRXTestResult: Codable, Equatable, Sendable {
    let success: Bool
    let serverVersion: String?
    let profiles: [OpenWebRXProfile]?
    let error: String?
}

struct OpenWebRXListenStatus: Codable, Equatable, Sendable {
    let previewSessionId: String?
    let stationId: String
    let connected: Bool
    let serverVersion: String?
    let profiles: [OpenWebRXProfile]
    let currentProfileId: String?
    let centerFreq: Double?
    let sampleRate: Double?
    let frequency: Double?
    let modulation: String?
    let smeterDb: Double?
    let isListening: Bool
    let error: String?
}

struct OpenWebRXListenStart: Codable, Sendable {
    let stationId: String
    let profileId: String?
    let frequency: Double?
    let modulation: String?
}

struct OpenWebRXListenTune: Codable, Sendable {
    let profileId: String?
    let frequency: Double?
    let modulation: String?
    let bandpassLow: Double?
    let bandpassHigh: Double?
}

struct OpenWebRXProfileSelectRequest: Codable, Equatable, Identifiable, Sendable {
    let requestId: String
    let targetFrequency: Double
    let profiles: [OpenWebRXProfile]
    let currentProfileId: String?

    var id: String { requestId }
}

struct OpenWebRXProfileVerifyResult: Codable, Equatable, Sendable {
    let requestId: String
    let success: Bool
    let profileId: String
    let profileName: String?
    let centerFreq: Double?
    let sampRate: Double?
    let error: String?
}

struct OpenWebRXStationListResponse: Codable, Sendable {
    let stations: [OpenWebRXStation]
}

struct OpenWebRXStationActionResponse: Codable, Sendable {
    let success: Bool
    let station: OpenWebRXStation
}

struct OpenWebRXListenStartResponse: Codable, Sendable {
    let success: Bool
    let status: OpenWebRXListenStatus
}

struct OpenWebRXListenStatusResponse: Codable, Sendable {
    let status: OpenWebRXListenStatus?
}

struct RealtimeSessionRequest: Codable, Sendable {
    let scope: String
    let direction: String
    let previewSessionId: String?
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

struct LogbookStatistics: Codable, Sendable {
    let totalQSOs: Int
    let totalOperators: Int
    let uniqueCallsigns: Int
    let lastQSO: String?
    let firstQSO: String?
    let dxcc: JSONValue?
}

struct LogbookDetail: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let description: String?
    let fileName: String
    let storageKind: String
    let createdAt: Double
    let lastUsed: Double
    let isActive: Bool
    let health: LogbookHealth
    let statistics: LogbookStatistics
    let connectedOperators: [String]
}

struct LogbookDetailResponse: Codable, Sendable {
    let success: Bool
    let data: LogbookDetail
}

struct LogbookActionResponse: Codable, Sendable {
    let success: Bool
    let message: String
    let data: LogbookInfo?
}

struct LogbookImportResult: Codable, Sendable {
    let detectedFormat: String
    let totalRead: Int
    let imported: Int
    let merged: Int
    let skipped: Int
}

struct LogbookImportResponse: Codable, Sendable {
    let success: Bool
    let message: String
    let data: LogbookImportResult
}

struct LogbookBackupArtifact: Codable, Sendable {
    let createdAt: Double
    let size: Int
    let recordCount: Int?
    let opaqueRecordCount: Int?
}

struct LogbookBackupCapabilities: Codable, Sendable {
    let canCreate: Bool
    let canDownload: Bool
    let canRestore: Bool
    let canDownloadPreRestore: Bool
}

struct LogbookBackupStatus: Codable, Sendable {
    let logBookId: String
    let revision: String
    let mainHealth: LogbookHealth
    let dirty: Bool
    let pendingMutations: Int
    let latest: LogbookBackupArtifact?
    let preRestore: LogbookBackupArtifact?
    let operation: JSONValue?
    let unsaved: [JSONValue]?
    let capabilities: LogbookBackupCapabilities
    let error: JSONValue?
}

struct LogbookBackupStatusResponse: Codable, Sendable {
    let success: Bool
    let data: LogbookBackupStatus
}

struct LogbookRestoreFileSummary: Codable, Sendable {
    let size: Int
    let recordCount: Int
    let opaqueRecordCount: Int
    let incompleteTail: Bool
    let issueCount: Int
}

struct LogbookRestorePreflight: Codable, Sendable {
    let preflightToken: String
    let expiresAt: Double
    let revision: String
    let main: LogbookRestoreFileSummary
    let backup: LogbookRestoreFileSummary
    let recordDelta: Int
    let estimatedLoss: Int
    let highRisk: Bool
}

struct LogbookRestorePreflightResponse: Codable, Sendable {
    let success: Bool
    let data: LogbookRestorePreflight
}

struct LogbookUnsavedQSORetryResponse: Codable, Sendable {
    let success: Bool
    let data: QSORecord
}

struct LogbookUnsavedQSODiscardResponse: Codable, Sendable {
    struct Result: Codable, Sendable {
        let attemptId: String
    }

    let success: Bool
    let data: Result
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
    let dxccId: Int?
    let dxccEntity: String?
    let dxccStatus: String?
    let dxccSource: String?
    let dxccConfidence: String?
    let dxccNeedsReview: Bool?
    let cqZone: Int?
    let ituZone: Int?
    let countryCode: String?
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

struct LogbookRecentGlobeResponse: Codable, Sendable {
    struct Payload: Codable, Sendable {
        struct Home: Codable, Sendable {
            let source: String
            let grid: String?
            let latitude: Double
            let longitude: Double
        }

        struct Item: Codable, Identifiable, Sendable {
            let id: String
            let callsign: String
            let startTime: Double
            let mode: String
            let frequency: Double
            let grid: String
        }

        struct Metadata: Codable, Sendable {
            let hours: Int
            let totalReturned: Int
            let droppedInvalidGrid: Int
            let limited: Bool
        }

        let home: Home?
        let items: [Item]
        let meta: Metadata
    }

    let success: Bool
    let data: Payload
}

struct LogbookWorkedGridResponse: Codable, Sendable {
    struct Payload: Codable, Sendable {
        struct Item: Codable, Identifiable, Sendable {
            let grid: String
            let count: Int

            var id: String { grid }
        }

        struct Metadata: Codable, Sendable {
            let band: String?
            let total: Int
        }

        let items: [Item]
        let meta: Metadata
    }

    let success: Bool
    let data: Payload
}

struct LogbookQSOQuery: Equatable, Sendable {
    var callsign: String?
    var grid: String?
    var band: String?
    var mode: String?
    var startDate: String?
    var endDate: String?
    var qslStatus: String?
    var dxccStatus: String?
    var qslFlow: String?
    var excludeModes: String?
    var limit = 50
    var offset = 0

    var queryItems: [URLQueryItem] {
        var items = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
        ]
        let filters: [(String, String?)] = [
            ("callsign", callsign),
            ("grid", grid),
            ("band", band),
            ("mode", mode),
            ("startDate", startDate),
            ("endDate", endDate),
            ("qslStatus", qslStatus),
            ("dxccStatus", dxccStatus),
            ("qslFlow", qslFlow),
            ("excludeModes", excludeModes),
        ]
        items.append(contentsOf: filters.compactMap { name, value in
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                return nil
            }
            return URLQueryItem(name: name, value: value)
        })
        return items
    }

    var activeFilterCount: Int {
        [callsign, grid, band, mode, startDate, endDate, qslStatus, dxccStatus, qslFlow, excludeModes]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .count
    }
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

struct UpdateQSORequest: Codable, Sendable {
    let callsign: String?
    let frequency: Double?
    let mode: String?
    let submode: String?
    let startTime: Double?
    let endTime: Double?
    let grid: String?
    let qth: String?
    let reportSent: String?
    let reportReceived: String?
    let messageHistory: [String]?
    let comment: String?
    let myCallsign: String?
    let myGrid: String?
    let lotwQslSent: String?
    let lotwQslReceived: String?
    let qrzQslSent: String?
    let qrzQslReceived: String?
    let notes: String?
}

struct QSOActionResponse: Codable, Sendable {
    let success: Bool
    let message: String
    let data: QSORecord?
}
