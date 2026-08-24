import XCTest
@testable import TX5DRMobile

final class FT8QueueCapabilityTests: XCTestCase {
    func testRecognizesOnlyBuiltInOrAdvertisedQueueStrategies() throws {
        let payload = Data(#"""
        {
          "state":"ready",
          "generation":1,
          "plugins":[{
            "name":"custom-queue",
            "type":"strategy",
            "strategyFeatures":{"targetQueue":1},
            "version":"1.0.0",
            "isBuiltIn":false,
            "loaded":true,
            "enabled":true,
            "errorCount":0
          }]
        }
        """#.utf8)
        let snapshot = try JSONDecoder().decode(TX5DRPluginSystemSnapshot.self, from: payload)

        XCTAssertTrue(FT8QueueCapability.supports(
            strategyName: "assisted-qso-queue",
            plugins: []
        ))
        XCTAssertTrue(FT8QueueCapability.supports(
            strategyName: "custom-queue",
            plugins: snapshot.plugins
        ))
        XCTAssertFalse(FT8QueueCapability.supports(
            strategyName: "auto-cq",
            plugins: snapshot.plugins
        ))
        XCTAssertFalse(FT8QueueCapability.supports(strategyName: nil, plugins: snapshot.plugins))
    }
}
