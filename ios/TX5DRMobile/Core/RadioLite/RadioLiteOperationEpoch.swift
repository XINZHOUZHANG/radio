import Foundation

struct RadioLiteOperationEpoch: Equatable, Sendable {
    private(set) var current: UInt64 = 0

    mutating func begin() -> UInt64 {
        advance()
        return current
    }

    mutating func invalidate() {
        advance()
    }

    func owns(_ value: UInt64) -> Bool {
        value != 0 && value == current
    }

    private mutating func advance() {
        current &+= 1
        if current == 0 { current = 1 }
    }
}
