import Foundation

enum FT8QueueCapability {
    static let builtInStrategyID = "assisted-qso-queue"

    static func supports(strategyName: String?, plugins: [TX5DRPluginStatus]) -> Bool {
        guard let strategyName, !strategyName.isEmpty else { return false }
        if strategyName == builtInStrategyID { return true }
        return plugins.contains { plugin in
            plugin.name == strategyName && plugin.strategyFeatures?.targetQueue == 1
        }
    }
}
