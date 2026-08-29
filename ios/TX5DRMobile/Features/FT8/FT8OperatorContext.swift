import Foundation

enum FT8OperatorContextError: LocalizedError, Equatable {
    case invalidFrequency
    case invalidSentReport
    case invalidReceivedReport

    var errorDescription: String? {
        switch self {
        case .invalidFrequency: "音频频率必须是 1–3000 Hz 的整数"
        case .invalidSentReport: "发送报告必须是整数"
        case .invalidReceivedReport: "接收报告必须是整数"
        }
    }
}

struct FT8OperatorContextDraft: Equatable, Sendable {
    var targetCallsign = ""
    var targetGrid = ""
    var audioFrequencyHz = "1000"
    var reportSent = "0"
    var reportReceived = "0"

    init() {}

    init(status: JSONValue?) {
        let context = status?["context"]
        let runtimeContext = status?["runtime"]?["context"]

        targetCallsign = runtimeContext?["targetCallsign"]?.stringValue
            ?? context?["targetCall"]?.stringValue
            ?? ""
        targetGrid = runtimeContext?["targetGrid"]?.stringValue
            ?? context?["targetGrid"]?.stringValue
            ?? ""
        audioFrequencyHz = Self.integerText(
            context?["frequency"]?.doubleValue
                ?? runtimeContext?["actualFrequency"]?.doubleValue,
            fallback: "1000"
        )
        reportSent = Self.integerText(
            runtimeContext?["reportSent"]?.doubleValue
                ?? context?["reportSent"]?.doubleValue,
            fallback: "0"
        )
        reportReceived = Self.integerText(
            runtimeContext?["reportReceived"]?.doubleValue
                ?? context?["reportReceived"]?.doubleValue,
            fallback: "0"
        )
    }

    func commandContext() throws -> [String: JSONValue] {
        let frequencyText = audioFrequencyHz.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let frequency = Int(frequencyText), (1...3_000).contains(frequency) else {
            throw FT8OperatorContextError.invalidFrequency
        }
        guard let sent = Int(reportSent.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw FT8OperatorContextError.invalidSentReport
        }
        guard let received = Int(reportReceived.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw FT8OperatorContextError.invalidReceivedReport
        }

        return [
            "targetCallsign": .string(normalizedUppercase(targetCallsign)),
            "targetGrid": .string(normalizedUppercase(targetGrid)),
            "frequency": .number(Double(frequency)),
            "reportSent": .number(Double(sent)),
            "reportReceived": .number(Double(received)),
        ]
    }

    var validationMessage: String? {
        do {
            _ = try commandContext()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func normalizedUppercase(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private static func integerText(_ value: Double?, fallback: String) -> String {
        guard let value, value.isFinite else { return fallback }
        return String(Int(value.rounded()))
    }
}
