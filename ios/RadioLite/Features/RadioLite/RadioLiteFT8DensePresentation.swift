import Foundation

/// Presentation only: never infers a transmission from the text of a received decode.
enum RadioLiteDenseDecodeSemantics {
    static func normalizedToken(_ value: String) -> String {
        value.uppercased().trimmingCharacters(in: CharacterSet(charactersIn: "<>[]{}(), \t\n"))
    }

    static func baseCallsign(_ value: String) -> String {
        let normalized = normalizedToken(value)
        return normalized.split(separator: "/").map(String.init)
            .filter {
                $0.count >= 3 && $0.contains(where: \.isLetter)
                    && $0.contains(where: \.isNumber)
                    && !RadioLiteMaidenheadDistance.isLocator($0)
            }
            .max(by: { $0.count < $1.count }) ?? normalized
    }

    static func matchesCallsign(_ token: String, _ callsign: String?) -> Bool {
        guard let callsign, !normalizedToken(callsign).isEmpty else { return false }
        return baseCallsign(token) == baseCallsign(callsign)
    }

    static func kind(
        message: String,
        stationCallsign: String?,
        workedCallsigns: Set<String>,
        isConfirmedLocalTransmit: Bool = false
    ) -> DecodeKind {
        if isConfirmedLocalTransmit { return .myTx }
        let tokens = message.split(whereSeparator: \.isWhitespace).map(String.init)
        if tokens.contains(where: { matchesCallsign($0, stationCallsign) }) { return .toMe }
        let parsed = RadioLiteFTMessage.parse(message)
        if let sender = parsed.sender,
           workedCallsigns.contains(baseCallsign(sender)) { return .worked }
        return tokens.first.map(normalizedToken) == "CQ" ? .cq : .plain
    }

    static func isNewDX(message: String, stationCallsign: String?, workedCallsigns: Set<String>) -> Bool {
        let parsed = RadioLiteFTMessage.parse(message)
        guard let sender = parsed.sender,
              !workedCallsigns.contains(baseCallsign(sender)),
              let stationCallsign,
              let station = RadioLiteCallsignCountryResolver.offline.location(for: stationCallsign),
              let remote = RadioLiteCallsignCountryResolver.offline.location(for: sender) else { return false }
        // Country/territory flags distinguish e.g. Hong Kong, without treating a province as DX.
        return station.flag != remote.flag && station.flag != nil && remote.flag != nil
    }
}

struct RadioLiteDenseDecodePresentation {
    struct Segment {
        let text: String
        let isStation: Bool
        let isCQPrefix: Bool
    }

    let kind: DecodeKind
    let time: String
    let snr: String
    let frequency: String
    let segments: [Segment]
    let tail: String
    let accessibilityLabel: String

    init(
        decode: RadioLiteDigitalDecode,
        slotStartMs: Int64,
        stationCallsign: String?,
        workedCallsigns: Set<String>,
        isConfirmedLocalTransmit: Bool = false
    ) {
        kind = RadioLiteDenseDecodeSemantics.kind(
            message: decode.message,
            stationCallsign: stationCallsign,
            workedCallsigns: workedCallsigns,
            isConfirmedLocalTransmit: isConfirmedLocalTransmit
        )
        time = Self.minuteSecond.string(from: Date(timeIntervalSince1970: Double(slotStartMs) / 1_000))
        snr = isConfirmedLocalTransmit ? "TX" : String(format: "%+03.0f", decode.snrDb)
        frequency = String(decode.audioFrequencyHz)
        let parsed = RadioLiteFTMessage.parse(decode.message)
        var tokens = decode.message.split(whereSeparator: \.isWhitespace).map(String.init)
        let isCQ = tokens.first.map(RadioLiteDenseDecodeSemantics.normalizedToken) == "CQ"
        // The locator is moved, not discarded. Keep exchange payloads such as RR73 in the message.
        var tailComponents: [String] = []
        if let sender = parsed.sender,
           let flag = RadioLiteCallsignCountryResolver.offline.flag(for: sender) { tailComponents.append(flag) }
        if let grid = parsed.grid, tokens.last.map(RadioLiteDenseDecodeSemantics.normalizedToken) == grid {
            tokens.removeLast()
            tailComponents.append(grid)
        }
        tail = tailComponents.joined(separator: " ")
        segments = tokens.enumerated().map { index, token in
            Segment(
                text: (index == 0 ? "" : " ") + token,
                isStation: RadioLiteDenseDecodeSemantics.matchesCallsign(token, stationCallsign),
                isCQPrefix: isCQ && (index == 0 || (index == 1 && token.uppercased() == "DX"))
            )
        }
        accessibilityLabel = "UTC \(time)，消息 \(decode.message)，\(frequency) 赫兹，信噪比 \(snr)"
    }

    private static let minuteSecond: DateFormatter = {
        let value = DateFormatter()
        value.locale = Locale(identifier: "en_US_POSIX")
        value.timeZone = TimeZone(secondsFromGMT: 0)
        value.dateFormat = "mmss"
        return value
    }()
}

enum RadioLiteFT8TimingPresentation {
    static func meanDelta(
        batches: [RadioLiteDigitalDecodeBatch], mode: String, at date: Date
    ) -> Double? {
        let now = Int64(date.timeIntervalSince1970 * 1_000)
        let values = batches.filter {
            $0.mode == mode && $0.receivedAtMs >= now - 30_000 && $0.receivedAtMs <= now
        }.flatMap(\.decodes).map(\.deltaTimeSeconds).filter(\.isFinite)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}
