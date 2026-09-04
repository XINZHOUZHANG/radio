import Foundation

struct RadioLiteGridLogPresentation: Equatable {
    let grid: String
    private(set) var records: [RadioLiteQSORecord] = []
    private(set) var total: Int
    private(set) var nextOffset = 0

    init(grid: String, expectedTotal: Int) {
        self.grid = grid.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        total = max(0, expectedTotal)
    }

    var hasMore: Bool {
        nextOffset < total
    }

    @discardableResult
    mutating func apply(_ page: RadioLiteLogPage, requestedGrid: String) -> Bool {
        let normalizedGrid = requestedGrid
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard normalizedGrid == grid else {
            return false
        }
        guard page.offset == 0 || page.offset == nextOffset else {
            return false
        }

        if page.offset == 0 {
            records = []
            nextOffset = 0
        }
        var knownIDs = Set(records.map(\.id))
        records.append(contentsOf: page.records.filter { knownIDs.insert($0.id).inserted })
        total = max(0, page.total)
        nextOffset = page.offset + page.records.count
        return true
    }
}
