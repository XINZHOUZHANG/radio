import Foundation

enum RadioServerNotice {
    static func localized(_ message: String) -> String {
        switch message {
        case "strategy_not_queue_capable":
            return "当前自动化策略不支持呼叫队列，请使用“呼叫”"
        default:
            return message
        }
    }
}
