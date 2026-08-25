import Foundation

struct RadioLiteDigitalSlotClock {
    enum Parity: Equatable {
        case even
        case odd
    }

    enum DisplayState: Equatable {
        case receiving
        case waitingToTransmit
        case transmitting
    }

    struct Snapshot: Equatable {
        let slotIndex: Int
        let slotStart: Date
        let elapsedSeconds: TimeInterval
        let progress: Double
        let remainingSeconds: TimeInterval
        let parity: Parity
    }

    let mode: String
    let periodSeconds: TimeInterval

    init?(mode: String) {
        let normalizedMode = mode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        switch normalizedMode {
        case "FT8":
            periodSeconds = 15
        case "FT4":
            periodSeconds = 7.5
        default:
            return nil
        }
        self.mode = normalizedMode
    }

    func snapshot(at date: Date) -> Snapshot {
        let timestamp = date.timeIntervalSince1970
        let slotIndex = Int(floor(timestamp / periodSeconds))
        let slotStart = Date(timeIntervalSince1970: TimeInterval(slotIndex) * periodSeconds)
        let elapsedSeconds = timestamp - slotStart.timeIntervalSince1970
        return Snapshot(
            slotIndex: slotIndex,
            slotStart: slotStart,
            elapsedSeconds: elapsedSeconds,
            progress: elapsedSeconds / periodSeconds,
            remainingSeconds: periodSeconds - elapsedSeconds,
            parity: slotIndex.isMultiple(of: 2) ? .even : .odd
        )
    }

    func displayState(
        at date: Date,
        rigState: RadioLiteRigState?,
        automaticQSO: RadioLiteAutoQSO?
    ) -> DisplayState {
        if rigState?.ptt == true { return .transmitting }
        guard let automaticQSO,
              automaticQSO.mode.uppercased() == mode,
              let txParity = parity(for: automaticQSO.txParity),
              txParity == snapshot(at: date).parity else {
            return .receiving
        }
        return .waitingToTransmit
    }

    private func parity(for value: String?) -> Parity? {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "even": .even
        case "odd": .odd
        default: nil
        }
    }
}
