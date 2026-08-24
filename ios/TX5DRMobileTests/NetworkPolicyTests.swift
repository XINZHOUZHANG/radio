import Foundation
import XCTest
@testable import TX5DRMobile

final class NetworkPolicyTests: XCTestCase {
    func testWebSocketTaskAcceptsLargeTX5DRSnapshots() throws {
        let session = URLSession(configuration: .ephemeral)
        let url = try XCTUnwrap(URL(string: "ws://127.0.0.1/api/ws"))

        let task = TX5DRNetworkPolicy.webSocketTask(session: session, url: url)
        addTeardownBlock {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }

        XCTAssertEqual(task.maximumMessageSize, 64 * 1024 * 1024)
    }
}
