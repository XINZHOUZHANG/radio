import Foundation

enum TX5DRPluginType: String, Codable, Sendable {
    case strategy
    case utility
}

enum TX5DRPluginSettingType: String, Codable, Sendable {
    case boolean
    case number
    case string
    case stringArray = "string[]"
    case objectArray = "object[]"
    case keyedStringArrays
    case keyedObjectArrays
    case keyedObjects
    case info
}

struct TX5DRPluginSettingOption: Codable, Identifiable, Sendable {
    let label: String
    let value: String

    var id: String { value }
}

struct TX5DRPluginSettingDescriptor: Codable, Sendable {
    let type: TX5DRPluginSettingType
    let defaultValue: JSONValue
    let label: String
    let description: String?
    let min: Double?
    let max: Double?
    let options: [TX5DRPluginSettingOption]?
    let itemFields: [JSONValue]?
    let keys: [JSONValue]?
    let visibleWhen: JSONValue?
    let descriptionWhen: [JSONValue]?
    let hidden: Bool?
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case type
        case defaultValue = "default"
        case label
        case description
        case min
        case max
        case options
        case itemFields
        case keys
        case visibleWhen
        case descriptionWhen
        case hidden
        case scope
    }

    var effectiveScope: String { scope ?? "global" }
}

struct TX5DRPluginQuickAction: Codable, Identifiable, Sendable {
    let id: String
    let label: String
    let icon: String?
}

struct TX5DRPluginPanelDescriptor: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let component: String
    let pageId: String?
    let params: [String: String]?
    let slot: String?
    let width: String?
    let icon: String?
    let openMode: String?
    let uiSize: String?
}

struct TX5DRPluginUIPage: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let entry: String
    let icon: String?
    let accessScope: String?
    let resourceBinding: String?
}

struct TX5DRPluginUIConfig: Codable, Sendable {
    let dir: String?
    let pages: [TX5DRPluginUIPage]?
}

struct TX5DRPluginPageConfiguration: Equatable, Sendable {
    let pageURL: URL
    let serverBaseURL: URL
    let pluginName: String
    let pageId: String
    let params: [String: String]
    let locale: String
    let theme: String

    func isSameOrigin(_ candidate: URL) -> Bool {
        guard let expected = URLComponents(url: serverBaseURL, resolvingAgainstBaseURL: false),
              let actual = URLComponents(url: candidate, resolvingAgainstBaseURL: false) else {
            return false
        }
        return expected.scheme?.lowercased() == actual.scheme?.lowercased()
            && expected.host?.lowercased() == actual.host?.lowercased()
            && effectivePort(expected) == effectivePort(actual)
    }

    func isAllowedNavigation(_ candidate: URL) -> Bool {
        if isSameOrigin(candidate) { return true }
        if candidate.absoluteString == "about:blank" { return true }
        if candidate.scheme?.lowercased() == "blob" {
            let inner = String(candidate.absoluteString.dropFirst("blob:".count))
            guard let innerURL = URL(string: inner) else { return false }
            return isSameOrigin(innerURL)
        }
        return false
    }

    private func effectivePort(_ components: URLComponents) -> Int? {
        if let port = components.port { return port }
        switch components.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }
}

enum TX5DRPluginPageEndpoint: String, Equatable, Sendable {
    case invoke = "ui-invoke"
    case store = "ui-store"
    case files = "ui-files"
    case heartbeat = "ui-session/heartbeat"
    case pushes = "ui-session/pushes"
}

enum TX5DRPluginPageBridgeError: LocalizedError, Equatable {
    case invalidMessage
    case unsupportedMessage(String)
    case missingField(String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidMessage: "插件页面发出了无效消息"
        case .unsupportedMessage(let type): "不支持的插件页面消息：\(type)"
        case .missingField(let field): "插件页面消息缺少 \(field)"
        case .server(let message): message
        }
    }
}

struct TX5DRPluginPageBridgeRequest: Equatable, Sendable {
    let requestId: String
    let endpoint: TX5DRPluginPageEndpoint
    private let fields: [String: JSONValue]

    init(message: JSONValue) throws {
        guard let object = message.objectValue,
              let type = object["type"]?.stringValue,
              let requestId = object["requestId"]?.stringValue,
              !requestId.isEmpty else {
            throw TX5DRPluginPageBridgeError.invalidMessage
        }

        self.requestId = requestId
        switch type {
        case "tx5dr:invoke":
            guard let action = object["action"]?.stringValue, !action.isEmpty else {
                throw TX5DRPluginPageBridgeError.missingField("action")
            }
            endpoint = .invoke
            fields = Self.pick(object, keys: ["action", "data"])
        case "tx5dr:store:get", "tx5dr:store:set", "tx5dr:store:delete":
            endpoint = .store
            fields = Self.pick(object, keys: ["type", "key", "value", "callsign", "operatorId"])
        case "tx5dr:file:upload", "tx5dr:file:read", "tx5dr:file:delete", "tx5dr:file:list":
            endpoint = .files
            fields = Self.pick(object, keys: ["type", "path", "prefix", "data", "callsign", "operatorId"])
        default:
            throw TX5DRPluginPageBridgeError.unsupportedMessage(type)
        }
    }

    func body(pageId: String, pageSessionId: String) -> JSONValue {
        var body = fields
        body["pageId"] = .string(pageId)
        body["pageSessionId"] = .string(pageSessionId)
        return .object(body)
    }

    private static func pick(_ source: [String: JSONValue], keys: [String]) -> [String: JSONValue] {
        Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            source[key].map { (key, $0) }
        })
    }
}

struct TX5DRPluginSource: Codable, Sendable {
    let kind: String
    let version: String
    let channel: String
    let artifactUrl: String
    let sha256: String
    let installedAt: Double
}

struct TX5DRPluginStrategyFeatures: Codable, Sendable {
    let targetQueue: Int?
}

struct TX5DRPluginStatus: Codable, Identifiable, Sendable {
    let name: String
    let type: TX5DRPluginType
    let strategyFeatures: TX5DRPluginStrategyFeatures?
    let instanceScope: String?
    let version: String
    let description: String?
    let isBuiltIn: Bool
    let loaded: Bool
    let enabled: Bool
    let autoDisabled: Bool?
    let errorCount: Int
    let lastError: String?
    let assignedOperatorIds: [String]?
    let settings: [String: TX5DRPluginSettingDescriptor]?
    let quickActions: [TX5DRPluginQuickAction]?
    let panels: [TX5DRPluginPanelDescriptor]?
    let permissions: [String]?
    let capabilities: [String]?
    let autoCallEnabledOperatorIds: [String]?
    let pausedOperatorIds: [String]?
    let ui: TX5DRPluginUIConfig?
    let locales: [String: [String: String]]?
    let source: TX5DRPluginSource?

    var id: String { name }
    var hasGlobalSettings: Bool {
        settings?.contains { $0.value.effectiveScope == "global" && $0.value.hidden != true } == true
    }
    var hasOperatorSettings: Bool {
        settings?.contains { $0.value.effectiveScope == "operator" && $0.value.hidden != true } == true
    }
}

struct TX5DRPluginSystemSnapshot: Codable, Sendable {
    let state: String
    let generation: Int
    let plugins: [TX5DRPluginStatus]
    let panelMeta: [JSONValue]?
    let panelContributions: [JSONValue]?
    let lastError: String?
}

struct TX5DRPluginStatusChange: Codable, Sendable {
    let generation: Int
    let plugin: TX5DRPluginStatus
}

struct TX5DRPluginDataPayload: Codable, Sendable {
    let pluginName: String
    let operatorId: String
    let panelId: String
    let data: JSONValue

    var key: String { "\(pluginName):\(operatorId):\(panelId)" }
}

struct TX5DRPluginLogEntry: Codable, Identifiable, Sendable {
    let pluginName: String
    let level: String
    let message: String
    let data: JSONValue?
    let timestamp: Double

    var id: String { "plugin:\(pluginName):\(Int(timestamp)):\(message)" }
}

struct TX5DRPluginRuntimeLogEntry: Codable, Identifiable, Sendable {
    let source: String
    let stage: String
    let level: String
    let message: String
    let timestamp: Double
    let pluginName: String?
    let directoryName: String?
    let details: JSONValue?

    var id: String { "runtime:\(pluginName ?? "system"):\(Int(timestamp)):\(message)" }
}

struct TX5DRPluginRuntimeInfo: Codable, Sendable {
    let pluginDir: String
    let pluginDataDir: String
    let dataDir: String
    let configDir: String
    let logsDir: String
    let cacheDir: String
    let distribution: String
    let hostPluginDirHint: String?
}

struct TX5DRPluginSettingsResponse: Codable, Sendable {
    let settings: [String: JSONValue]
}

struct TX5DRPluginOperatorState: Codable, Sendable {
    let operatorId: String
    let currentStrategy: String
    let strategyState: String
    let slots: [String: String]
    let context: JSONValue
    let operatorSettings: [String: [String: JSONValue]]
    let pluginSnapshot: TX5DRPluginSystemSnapshot
    let plugins: [TX5DRPluginStatus]
}

struct TX5DRPluginPauseResponse: Codable, Sendable {
    let success: Bool
    let operatorId: String
    let pausedPlugins: [String]
}

struct TX5DRPluginMarketScreenshot: Codable, Sendable {
    let src: String
    let alt: String?
}

struct TX5DRPluginMarketEntry: Codable, Identifiable, Sendable {
    let name: String
    let title: String
    let description: String
    let readmeMarkdown: String?
    let readmeSourceUrl: String?
    let latestVersion: String
    let minHostVersion: String
    let author: String?
    let license: String?
    let repository: String?
    let homepage: String?
    let categories: [String]
    let keywords: [String]
    let permissions: [String]
    let screenshots: [TX5DRPluginMarketScreenshot]
    let artifactUrl: String
    let sha256: String
    let size: Int
    let publishedAt: String

    var id: String { name }
}

struct TX5DRPluginMarketCatalog: Codable, Sendable {
    let schemaVersion: Int
    let generatedAt: String
    let channel: String
    let plugins: [TX5DRPluginMarketEntry]
}

struct TX5DRPluginMarketCatalogResponse: Codable, Sendable {
    let catalog: TX5DRPluginMarketCatalog
    let sourceUrl: String
}

struct TX5DRPluginMarketInstallResult: Codable, Sendable {
    let success: Bool
    let action: String
    let pluginName: String
    let record: JSONValue?
}

enum TX5DRLogbookSyncOperation: String, Codable, Sendable {
    case upload
    case download
    case fullSync = "full_sync"
}

struct TX5DRLogbookSyncAction: Codable, Identifiable, Sendable {
    let id: String
    let label: String
    let description: String?
    let icon: String?
    let pageId: String?
    let operation: TX5DRLogbookSyncOperation?
}

struct TX5DRLogbookSyncProvider: Codable, Identifiable, Sendable {
    let id: String
    let pluginName: String
    let displayName: String
    let icon: String?
    let color: String?
    let accessScope: String?
    let settingsPageId: String
    let actions: [TX5DRLogbookSyncAction]?
}

struct TX5DRLogbookSyncConfiguredResponse: Codable, Sendable {
    let providers: [String: Bool]
}

struct TX5DRLogbookSyncFailure: Codable, Identifiable, Sendable {
    let code: String
    let message: String
    let source: String?
    let operation: String?
    let providerId: String?
    let qsoId: String?
    let qsoCallsign: String?
    let httpStatus: Int?
    let retryable: Bool?
    let detail: String?

    var id: String {
        [providerId, operation, qsoId, code, message].compactMap { $0 }.joined(separator: ":")
    }
}

struct TX5DRLogbookSyncTestResult: Codable, Sendable {
    let success: Bool
    let message: String?
    let details: JSONValue?
    let failures: [TX5DRLogbookSyncFailure]?
}

struct TX5DRLogbookSyncPreflightIssue: Codable, Identifiable, Sendable {
    let code: String
    let severity: String
    let message: String
    let detail: String?
    let qsoId: String?
    let qsoCallsign: String?

    var id: String { [qsoId, code, message].compactMap { $0 }.joined(separator: ":") }
}

struct TX5DRLogbookSyncUploadPreflight: Codable, Sendable {
    let ready: Bool
    let pendingCount: Int
    let uploadableCount: Int
    let blockedCount: Int
    let issues: [TX5DRLogbookSyncPreflightIssue]?
    let canSkipBlocked: Bool?
    let guidance: [String]?
}

struct TX5DRLogbookSyncUploadResult: Codable, Sendable {
    let submitted: Int?
    let verified: Int?
    let uploaded: Int
    let skipped: Int
    let failed: Int
    let failures: [TX5DRLogbookSyncFailure]?
}

struct TX5DRLogbookSyncDownloadResult: Codable, Sendable {
    let downloaded: Int
    let matched: Int
    let updated: Int
    let imported: Int?
    let windowCount: Int?
    let failures: [TX5DRLogbookSyncFailure]?
}
