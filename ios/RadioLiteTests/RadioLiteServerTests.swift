import XCTest
@testable import RadioLite

final class RadioLiteServerTests: XCTestCase {
    func testNormalizesPlainTailscaleAddressAndKeepsSinglePortPaths() throws {
        let server = try RadioLiteServer(address: "100.64.0.10:8787/")
        XCTAssertEqual(server.baseURL.absoluteString, "http://100.64.0.10:8787")
        XCTAssertEqual(try server.url("/api/v1/logs").absoluteString, "http://100.64.0.10:8787/api/v1/logs")
        XCTAssertEqual(try server.webSocketURL("/ws/control").absoluteString, "ws://100.64.0.10:8787/ws/control")
    }

    func testPreservesReverseProxyBasePath() throws {
        let server = try RadioLiteServer(address: "https://radio.example/lite/")
        XCTAssertEqual(try server.url("healthz").absoluteString, "https://radio.example/lite/healthz")
        XCTAssertEqual(try server.webSocketURL("ws/media").absoluteString, "wss://radio.example/lite/ws/media")
    }

    func testNetworkTimeoutIsFiveMinutes() throws {
        let request = RadioLiteNetworkPolicy.request(url: try XCTUnwrap(URL(string: "http://100.64.0.10:8787/healthz")))
        let configuration = RadioLiteNetworkPolicy.configuration()
        XCTAssertEqual(request.timeoutInterval, 300)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 300)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 300)
        XCTAssertFalse(configuration.waitsForConnectivity)
    }

    func testStartupRestoreUsesAShortIndependentDeadlineAndOffersAnEscape() {
        XCTAssertEqual(RadioLiteStartupRestorePolicy.deadline, 10)
        XCTAssertEqual(RadioLiteStartupRestorePolicy.escapeDelay, 3)
        XCTAssertEqual(
            RadioLiteStartupRestorePolicy.timeoutMessage(serverAddress: "http://100.64.0.10:8787"),
            "无法连接到上次使用的服务器 http://100.64.0.10:8787，请检查网络或换一个地址"
        )
    }
}
