import XCTest
@testable import TX5DRMobile

final class PluginModelsTests: XCTestCase {
    func testDecodesPluginSnapshotAndSettingScopes() throws {
        let payload = Data(#"{
          "state":"ready",
          "generation":4,
          "plugins":[{
            "name":"auto-cq",
            "type":"utility",
            "instanceScope":"operator",
            "version":"1.2.3",
            "description":"Automation",
            "isBuiltIn":false,
            "loaded":true,
            "enabled":true,
            "errorCount":0,
            "settings":{
              "enabled":{"type":"boolean","default":true,"label":"Enabled","scope":"global"},
              "interval":{"type":"number","default":15,"label":"Interval","min":5,"max":60,"scope":"operator"}
            },
            "quickActions":[{"id":"run","label":"Run now"}],
            "ui":{"dir":"ui","pages":[{"id":"dashboard","title":"Dashboard","entry":"dashboard.html","accessScope":"operator","resourceBinding":"operator"}]}
          }],
          "panelMeta":[],
          "panelContributions":[]
        }"#.utf8)

        let snapshot = try JSONDecoder().decode(TX5DRPluginSystemSnapshot.self, from: payload)
        let plugin = try XCTUnwrap(snapshot.plugins.first)

        XCTAssertEqual(snapshot.generation, 4)
        XCTAssertEqual(plugin.type, .utility)
        XCTAssertTrue(plugin.hasGlobalSettings)
        XCTAssertTrue(plugin.hasOperatorSettings)
        XCTAssertEqual(plugin.quickActions?.first?.id, "run")
        XCTAssertEqual(plugin.ui?.pages?.first?.resourceBinding, "operator")
    }

    func testDecodesMarketplaceCatalog() throws {
        let payload = Data(#"{
          "catalog":{
            "schemaVersion":1,
            "generatedAt":"2026-08-24T00:00:00Z",
            "channel":"stable",
            "plugins":[{
              "name":"log-sync",
              "title":"Log Sync",
              "description":"Synchronize QSOs",
              "latestVersion":"2.0.0",
              "minHostVersion":"1.0.0",
              "categories":["logbook"],
              "keywords":[],
              "permissions":["logbook:sync"],
              "screenshots":[],
              "artifactUrl":"https://example.test/log-sync.tgz",
              "sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
              "size":1024,
              "publishedAt":"2026-08-24T00:00:00Z"
            }]
          },
          "sourceUrl":"https://example.test/catalog.json"
        }"#.utf8)

        let response = try JSONDecoder().decode(TX5DRPluginMarketCatalogResponse.self, from: payload)

        XCTAssertEqual(response.catalog.channel, "stable")
        XCTAssertEqual(response.catalog.plugins.first?.name, "log-sync")
        XCTAssertEqual(response.catalog.plugins.first?.permissions, ["logbook:sync"])
    }

    func testBuildsSanitizedPluginInvokeRequest() throws {
        let request = try TX5DRPluginPageBridgeRequest(message: .object([
            "type": .string("tx5dr:invoke"),
            "requestId": .string("req-1"),
            "action": .string("saveConfig"),
            "data": .object(["enabled": .bool(true)]),
            "pageId": .string("forged-page"),
            "pageSessionId": .string("forged-session"),
        ]))

        XCTAssertEqual(request.endpoint, .invoke)
        XCTAssertEqual(request.requestId, "req-1")
        XCTAssertEqual(request.body(pageId: "settings", pageSessionId: "session-1"), .object([
            "pageId": .string("settings"),
            "pageSessionId": .string("session-1"),
            "action": .string("saveConfig"),
            "data": .object(["enabled": .bool(true)]),
        ]))
    }

    func testRejectsUnknownPluginBridgeMessage() {
        XCTAssertThrowsError(try TX5DRPluginPageBridgeRequest(message: .object([
            "type": .string("tx5dr:admin-shell"),
            "requestId": .string("req-2"),
        ]))) { error in
            XCTAssertEqual(error as? TX5DRPluginPageBridgeError, .unsupportedMessage("tx5dr:admin-shell"))
        }
    }

    func testPluginPageNavigationAllowsOnlyServerOriginAndItsBlobURLs() throws {
        let configuration = TX5DRPluginPageConfiguration(
            pageURL: try XCTUnwrap(URL(string: "https://radio.example/api/plugins/demo/ui/main.html")),
            serverBaseURL: try XCTUnwrap(URL(string: "https://radio.example")),
            pluginName: "demo",
            pageId: "main",
            params: [:],
            locale: "zh-Hant",
            theme: "dark"
        )

        XCTAssertTrue(configuration.isAllowedNavigation(try XCTUnwrap(URL(string: "https://radio.example/help"))))
        XCTAssertTrue(configuration.isAllowedNavigation(try XCTUnwrap(URL(string: "blob:https://radio.example/id"))))
        XCTAssertTrue(configuration.isAllowedNavigation(try XCTUnwrap(URL(string: "about:blank"))))
        XCTAssertFalse(configuration.isAllowedNavigation(try XCTUnwrap(URL(string: "https://evil.example"))))
        XCTAssertFalse(configuration.isAllowedNavigation(try XCTUnwrap(URL(string: "blob:https://evil.example/id"))))
        XCTAssertFalse(configuration.isAllowedNavigation(try XCTUnwrap(URL(string: "javascript:alert(1)"))))
    }
}
