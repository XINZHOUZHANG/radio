import Foundation

@MainActor
enum RadioLiteVoicePTTStartup {
    static func schedule(
        requiresMediaSubscription: Bool,
        prepareReceiveRecovery: () -> Void,
        operation: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        if requiresMediaSubscription {
            prepareReceiveRecovery()
        }
        return Task { @MainActor in
            guard !Task.isCancelled else { return }
            await operation()
        }
    }
}
