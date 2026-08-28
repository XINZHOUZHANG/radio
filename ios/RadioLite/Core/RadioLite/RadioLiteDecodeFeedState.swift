import Foundation

struct RadioLiteDecodeFeedState: Equatable, Sendable {
    private static let maximumBatches = 16

    private(set) var mode: String
    private(set) var cqOnly: Bool
    private(set) var displayedBatches: [RadioLiteDigitalDecodeBatch] = []
    private(set) var selectedDecodeId: String?
    private(set) var isFollowingLatest = true
    private(set) var latestScrollRequestRevision: UInt64 = 0

    private var latestBatches: [RadioLiteDigitalDecodeBatch] = []

    init(mode: String = "FT8", cqOnly: Bool = false) {
        self.mode = Self.normalizedMode(mode)
        self.cqOnly = cqOnly
    }

    var displayedBatch: RadioLiteDigitalDecodeBatch? { displayedBatches.first }

    var filteredDecodes: [RadioLiteDigitalDecode] {
        displayedBatches.flatMap { filteredDecodes(in: $0) }
    }

    func filteredDecodes(
        in batch: RadioLiteDigitalDecodeBatch
    ) -> [RadioLiteDigitalDecode] {
        let decodes = batch.decodes
        guard cqOnly else { return decodes }
        return decodes.filter { Self.isCQ($0.message) }
    }

    var selectedDecode: RadioLiteDigitalDecode? {
        guard let selectedDecodeId else { return nil }
        for batch in displayedBatches {
            if let decode = batch.decodes.first(where: { $0.id == selectedDecodeId }) {
                return decode
            }
        }
        return nil
    }

    mutating func receive(_ batch: RadioLiteDigitalDecodeBatch?) {
        receive(batch.map { [$0] } ?? [])
    }

    mutating func receive(_ batches: [RadioLiteDigitalDecodeBatch]) {
        latestBatches = matchingBatches(batches)
        guard isFollowingLatest, selectedDecodeId == nil else { return }
        displayedBatches = latestBatches
    }

    mutating func select(decodeId: String) {
        guard filteredDecodes.contains(where: { $0.id == decodeId }) else { return }
        selectedDecodeId = decodeId
        isFollowingLatest = false
    }

    mutating func pauseFollowingLatest() {
        isFollowingLatest = false
    }

    mutating func resume() {
        selectedDecodeId = nil
        isFollowingLatest = true
        displayedBatches = latestBatches
        latestScrollRequestRevision &+= 1
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
        changeMode(to: value, batches: latestBatch.map { [$0] } ?? [])
    }

    mutating func changeMode(
        to value: String,
        batches: [RadioLiteDigitalDecodeBatch]
    ) {
        mode = Self.normalizedMode(value)
        selectedDecodeId = nil
        isFollowingLatest = true
        latestBatches = matchingBatches(batches)
        displayedBatches = latestBatches
        latestScrollRequestRevision &+= 1
    }

    private func matchingBatches(
        _ batches: [RadioLiteDigitalDecodeBatch]
    ) -> [RadioLiteDigitalDecodeBatch] {
        var newestRevisionByID: [String: RadioLiteDigitalDecodeBatch] = [:]
        for batch in batches where Self.normalizedMode(batch.mode) == mode {
            if let current = newestRevisionByID[batch.id], current.revision > batch.revision {
                continue
            }
            newestRevisionByID[batch.id] = batch
        }
        return Array(newestRevisionByID.values.sorted {
            if $0.slotStartMs == $1.slotStartMs { return $0.revision > $1.revision }
            return $0.slotStartMs > $1.slotStartMs
        }.prefix(Self.maximumBatches))
    }

    private static func normalizedMode(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private static func isCQ(_ message: String) -> Bool {
        let normalized = message.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized == "CQ" || normalized.hasPrefix("CQ ")
    }
}
