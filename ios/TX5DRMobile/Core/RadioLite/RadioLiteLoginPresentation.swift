import Foundation

struct RadioLiteSetupValidation: Equatable {
    let setupCode: String
    let username: String
    let password: String

    var setupCodeIsValid: Bool {
        setupCode.count == 6 && setupCode.unicodeScalars.allSatisfy {
            (48...57).contains(Int($0.value))
        }
    }

    var usernameIsValid: Bool {
        let normalized = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.range(
            of: "^[a-z0-9][a-z0-9_.-]{2,31}$",
            options: .regularExpression
        ) != nil
    }

    var passwordIsValid: Bool { !password.isEmpty }
    var isValid: Bool { setupCodeIsValid && usernameIsValid && passwordIsValid }

    let setupCodeHint = "初始化码必须是 6 位数字"
    let usernameHint = "用户名须为 3–32 位，可使用字母、数字、点、横线和下划线"
    let passwordHint = "密码仅需非空，可使用任意字符"
}

struct RadioLiteNoticeState: Equatable {
    private(set) var message: String?
    private var activeDeduplicationKey: String?
    private var dismissedDeduplicationKeys: Set<String> = []

    mutating func present(_ message: String, deduplicationKey: String? = nil) {
        if let deduplicationKey, dismissedDeduplicationKeys.contains(deduplicationKey) {
            return
        }
        self.message = message
        activeDeduplicationKey = deduplicationKey
    }

    mutating func dismiss() {
        if let activeDeduplicationKey {
            dismissedDeduplicationKeys.insert(activeDeduplicationKey)
        }
        message = nil
        activeDeduplicationKey = nil
    }

    mutating func resolve(keysWithPrefix prefix: String) {
        dismissedDeduplicationKeys = Set(
            dismissedDeduplicationKeys.filter { !$0.hasPrefix(prefix) }
        )
        if activeDeduplicationKey?.hasPrefix(prefix) == true {
            message = nil
            activeDeduplicationKey = nil
        }
    }

    mutating func reset() {
        message = nil
        activeDeduplicationKey = nil
        dismissedDeduplicationKeys.removeAll()
    }
}
