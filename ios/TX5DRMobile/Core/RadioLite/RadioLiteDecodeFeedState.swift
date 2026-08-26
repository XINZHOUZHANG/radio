import Foundation

struct RadioLiteDecodeFeedState: Equatable, Sendable {
    private(set) var mode: String
    private(set) var cqOnly: Bool
    private(set) var displayedBatch: RadioLiteDigitalDecodeBatch?
    private(set) var selectedDecodeId: String?

    private var latestBatch: RadioLiteDigitalDecodeBatch?

    init(mode: String = "FT8", cqOnly: Bool = true) {
        self.mode = Self.normalizedMode(mode)
        self.cqOnly = cqOnly
    }

    var filteredDecodes: [RadioLiteDigitalDecode] {
        let decodes = displayedBatch?.decodes ?? []
        guard cqOnly else { return decodes }
        return decodes.filter { Self.isCQ($0.message) }
    }

    var selectedDecode: RadioLiteDigitalDecode? {
        guard let selectedDecodeId else { return nil }
        return displayedBatch?.decodes.first { $0.id == selectedDecodeId }
    }

    mutating func receive(_ batch: RadioLiteDigitalDecodeBatch?) {
        latestBatch = matchingBatch(batch)
        if selectedDecodeId == nil {
            displayedBatch = latestBatch
        }
    }

    mutating func select(decodeId: String) {
        guard filteredDecodes.contains(where: { $0.id == decodeId }) else { return }
        selectedDecodeId = decodeId
    }

    mutating func resume() {
        selectedDecodeId = nil
        displayedBatch = latestBatch
    }

    mutating func setCQOnly(_ value: Bool) {
        cqOnly = value
        guard let selectedDecodeId,
              !filteredDecodes.contains(where: { $0.id == selectedDecodeId }) else { return }
        resume()
    }

    mutating func changeMode(
        to value: String,
        latestBatch: RadioLiteDigitalDecodeBatch?
    ) {
        mode = Self.normalizedMode(value)
        selectedDecodeId = nil
        self.latestBatch = matchingBatch(latestBatch)
        displayedBatch = self.latestBatch
    }

    private func matchingBatch(
        _ batch: RadioLiteDigitalDecodeBatch?
    ) -> RadioLiteDigitalDecodeBatch? {
        guard let batch, Self.normalizedMode(batch.mode) == mode else { return nil }
        return batch
    }

    private static func normalizedMode(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private static func isCQ(_ message: String) -> Bool {
        let normalized = message.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized == "CQ" || normalized.hasPrefix("CQ ")
    }
}
