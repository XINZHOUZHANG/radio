import XCTest
@testable import TX5DRMobile

final class TX5DRServerTests: XCTestCase {
    func testAddsDefaultSchemeAndAPIPrefix() throws {
        let server = try TX5DRServer(address: "radio.example:8076/")

        XCTAssertEqual(server.baseURL.absoluteString, "http://radio.example:8076")
        XCTAssertEqual(try server.apiURL("/auth/me").absoluteString, "http://radio.example:8076/api/auth/me")
    }

    func testPreservesDeploymentBasePathAndEncodesQuery() throws {
        let server = try TX5DRServer(address: "https://radio.example/tx5dr/")
        let url = try server.apiURL("logbooks", queryItems: [URLQueryItem(name: "q", value: "BG 2")])

        XCTAssertEqual(url.absoluteString, "https://radio.example/tx5dr/api/logbooks?q=BG%202")
    }

    func testBuildsControlWebSocketURL() throws {
        let secure = try TX5DRServer(address: "https://radio.example")
        let insecure = try TX5DRServer(address: "http://192.0.2.10:8076")

        XCTAssertEqual(try secure.webSocketURL("/ws").absoluteString, "wss://radio.example/api/ws")
        XCTAssertEqual(try insecure.webSocketURL("/ws").absoluteString, "ws://192.0.2.10:8076/api/ws")
    }

    func testBuildsFilteredLogbookWebSocketURL() throws {
        let server = try TX5DRServer(address: "https://radio.example/tx5dr")
        let url = try server.webSocketURL(
            "/ws/logbook",
            queryItems: [
                URLQueryItem(name: "operatorId", value: "operator 1"),
                URLQueryItem(name: "logBookId", value: "field-log"),
                URLQueryItem(name: "token", value: "jwt+token"),
            ]
        )

        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "wss")
        XCTAssertEqual(components.host, "radio.example")
        XCTAssertEqual(components.path, "/tx5dr/api/ws/logbook")
        XCTAssertEqual(components.queryItems?.first { $0.name == "operatorId" }?.value, "operator 1")
        XCTAssertEqual(components.queryItems?.first { $0.name == "logBookId" }?.value, "field-log")
        XCTAssertEqual(components.queryItems?.first { $0.name == "token" }?.value, "jwt+token")
    }

    func testExternalizesInternalRealtimeOfferAndReplacesToken() throws {
        let server = try TX5DRServer(address: "https://radio.example:8443")
        let offer = try XCTUnwrap(URL(string: "ws://127.0.0.1:4000/api/realtime/ws-compat?token=old&mode=pcm"))
        let external = try server.externalizedOfferURL(offer, token: "new token")
        let components = try XCTUnwrap(URLComponents(url: external, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.scheme, "wss")
        XCTAssertEqual(components.host, "radio.example")
        XCTAssertEqual(components.port, 8443)
        XCTAssertEqual(components.path, "/api/realtime/ws-compat")
        XCTAssertEqual(components.queryItems?.filter { $0.name == "token" }.map(\.value), ["new token"])
        XCTAssertEqual(components.queryItems?.first { $0.name == "mode" }?.value, "pcm")
    }

    func testRejectsUnsupportedOrMissingAddresses() {
        XCTAssertThrowsError(try TX5DRServer(address: ""))
        XCTAssertThrowsError(try TX5DRServer(address: "ftp://radio.example"))
        XCTAssertThrowsError(try TX5DRServer(address: "http:///missing-host"))
    }
}
