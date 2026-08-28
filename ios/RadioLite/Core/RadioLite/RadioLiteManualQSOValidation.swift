import Foundation

enum RadioLiteManualQSOValidationError: LocalizedError, Equatable {
    case radioUnavailable
    case invalidCall
    case invalidGrid
    case invalidFrequency
    case invalidStartTime
    case invalidEndTime
    case endBeforeStart
    case invalidSentReport
    case invalidReceivedReport
    case invalidPower
    case invalidComment

    var errorDescription: String? {
        switch self {
        case .radioUnavailable:
            "当前没有可用电台，请先选择电台"
        case .invalidCall:
            "呼号须为 3–32 位，只能使用英文字母、数字、/、. 和 -"
        case .invalidGrid:
            "网格须为 2、4、6 或 8 位有效 Maidenhead 定位符"
        case .invalidFrequency:
            "频率须为服务端支持的业余频段内有效 MHz 数值"
        case .invalidStartTime:
            "开始时间无效"
        case .invalidEndTime:
            "结束时间无效"
        case .endBeforeStart:
            "结束时间不能早于开始时间"
        case .invalidSentReport:
            "发送报告只能使用 1–16 个可打印 ASCII 字符"
        case .invalidReceivedReport:
            "接收报告只能使用 1–16 个可打印 ASCII 字符"
        case .invalidPower:
            "功率须为 0–100000 W 的有效数字"
        case .invalidComment:
            "备注只能使用 1–256 个可打印 ASCII 字符，不能包含中文、换行或表情"
        }
    }
}

struct RadioLiteManualQSOForm {
    let radioId: String?
    let call: String
    let grid: String
    let frequencyMHz: String
    let mode: String
    let submode: String
    let rstSent: String
    let rstReceived: String
    let powerWatts: String
    let comment: String
    let startedAt: Date
    let endedAt: Date?

    func makeRequest() throws -> RadioLiteManualQSO {
        guard let radioId, isBoundedMessageText(radioId, maximum: 32) else {
            throw RadioLiteManualQSOValidationError.radioUnavailable
        }

        let normalizedCall = call.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard isPrintableASCII(call, minimum: 3, maximum: 32),
              (3...32).contains(normalizedCall.count),
              normalizedCall.unicodeScalars.allSatisfy(isCallsignCharacter) else {
            throw RadioLiteManualQSOValidationError.invalidCall
        }

        let normalizedGrid = grid.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let requestGrid: String?
        if normalizedGrid.isEmpty {
            requestGrid = nil
        } else {
            guard isBoundedMessageText(grid, maximum: 8),
                  isMaidenhead(normalizedGrid) else {
                throw RadioLiteManualQSOValidationError.invalidGrid
            }
            requestGrid = normalizedGrid
        }

        let normalizedFrequency = normalizedDecimal(frequencyMHz)
        guard let frequency = Double(normalizedFrequency), frequency.isFinite else {
            throw RadioLiteManualQSOValidationError.invalidFrequency
        }
        let roundedFrequencyHz = (frequency * 1_000_000).rounded()
        guard roundedFrequencyHz.isFinite,
              roundedFrequencyHz >= 1,
              roundedFrequencyHz <= 450_000_000 else {
            throw RadioLiteManualQSOValidationError.invalidFrequency
        }
        let frequencyHz = Int64(roundedFrequencyHz)
        guard isSupportedFrequency(frequencyHz) else {
            throw RadioLiteManualQSOValidationError.invalidFrequency
        }

        let startedAtMs = try timestamp(startedAt, error: .invalidStartTime)
        let endedAtMs: Int64?
        if let endedAt {
            let value = try timestamp(endedAt, error: .invalidEndTime)
            guard value >= startedAtMs else {
                throw RadioLiteManualQSOValidationError.endBeforeStart
            }
            endedAtMs = value
        } else {
            endedAtMs = nil
        }

        let requestPower: Double?
        let normalizedPower = normalizedDecimal(powerWatts)
        if normalizedPower.isEmpty {
            requestPower = nil
        } else {
            guard let value = Double(normalizedPower),
                  value.isFinite,
                  (0...100_000).contains(value) else {
                throw RadioLiteManualQSOValidationError.invalidPower
            }
            requestPower = value
        }

        let requestComment: String?
        if comment.isEmpty {
            requestComment = nil
        } else {
            guard isPrintableASCII(comment, minimum: 1, maximum: 256) else {
                throw RadioLiteManualQSOValidationError.invalidComment
            }
            requestComment = comment
        }

        return RadioLiteManualQSO(
            radioId: radioId,
            call: normalizedCall,
            startedAtMs: startedAtMs,
            endedAtMs: endedAtMs,
            frequencyHz: frequencyHz,
            band: nil,
            mode: mode,
            submode: submode.isEmpty ? nil : submode,
            rstSent: try report(rstSent, error: .invalidSentReport),
            rstReceived: try report(rstReceived, error: .invalidReceivedReport),
            grid: requestGrid,
            txPowerWatts: requestPower,
            comment: requestComment
        )
    }

    private func report(
        _ value: String,
        error: RadioLiteManualQSOValidationError
    ) throws -> String? {
        guard !value.isEmpty else { return nil }
        guard isPrintableASCII(value, minimum: 1, maximum: 16) else { throw error }
        return value
    }

    private func timestamp(
        _ date: Date,
        error: RadioLiteManualQSOValidationError
    ) throws -> Int64 {
        let milliseconds = date.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite,
              milliseconds >= 0,
              milliseconds <= 9_007_199_254_740_991 else {
            throw error
        }
        return Int64(milliseconds.rounded(.towardZero))
    }
}

private func normalizedDecimal(_ value: String) -> String {
    value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: ",", with: ".")
}

private func isBoundedMessageText(_ value: String, maximum: Int) -> Bool {
    !value.isEmpty && value.count <= maximum && !value.unicodeScalars.contains {
        $0.value == 0 || $0.value == 10 || $0.value == 13
    }
}

private func isCallsignCharacter(_ scalar: Unicode.Scalar) -> Bool {
    (48...57).contains(Int(scalar.value))
        || (65...90).contains(Int(scalar.value))
        || scalar == "/"
        || scalar == "."
        || scalar == "-"
}

private func isMaidenhead(_ value: String) -> Bool {
    guard [2, 4, 6, 8].contains(value.count) else { return false }
    return value.range(
        of: "^(?:[A-R]{2})(?:[0-9]{2})?(?:[A-X]{2})?(?:[0-9]{2})?$",
        options: .regularExpression
    ) != nil
}

private func isPrintableASCII(_ value: String, minimum: Int, maximum: Int) -> Bool {
    (minimum...maximum).contains(value.count) && value.unicodeScalars.allSatisfy {
        (32...126).contains(Int($0.value))
    }
}

private func isSupportedFrequency(_ frequencyHz: Int64) -> Bool {
    let ranges: [ClosedRange<Int64>] = [
        135_700...137_800,
        472_000...479_000,
        1_800_000...2_000_000,
        3_500_000...4_000_000,
        5_000_000...5_500_000,
        7_000_000...7_300_000,
        10_100_000...10_150_000,
        14_000_000...14_350_000,
        18_068_000...18_168_000,
        21_000_000...21_450_000,
        24_890_000...24_990_000,
        28_000_000...29_700_000,
        50_000_000...54_000_000,
        144_000_000...148_000_000,
        420_000_000...450_000_000,
    ]
    return ranges.contains { $0.contains(frequencyHz) }
}
