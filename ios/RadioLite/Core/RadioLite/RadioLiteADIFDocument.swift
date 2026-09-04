import Foundation
import UniformTypeIdentifiers

enum RadioLiteADIFDocument {
    static let typeIdentifier = "xyz.992218.radio-lite.adif"
    static let contentType = UTType(importedAs: typeIdentifier, conformingTo: .plainText)
    static let supportedFilenameExtensions = ["adi", "adif"]
    static let allowedContentTypes: [UTType] = [contentType, .plainText, .data]

    static func readCoordinatedData(from sourceURL: URL) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try readCoordinatedDataSynchronously(from: sourceURL)
        }.value
    }

    private static func readCoordinatedDataSynchronously(from sourceURL: URL) throws -> Data {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("radio-lite-adif-import-\(UUID().uuidString)")
            .appendingPathExtension("adi")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var copyResult: Result<Void, Error>?
        coordinator.coordinate(
            readingItemAt: sourceURL,
            options: .withoutChanges,
            error: &coordinationError
        ) { coordinatedURL in
            copyResult = Result {
                try FileManager.default.copyItem(at: coordinatedURL, to: temporaryURL)
            }
        }

        if let coordinationError {
            throw coordinationError
        }
        guard let copyResult else {
            throw CocoaError(.fileReadUnknown)
        }
        try copyResult.get()
        return try Data(contentsOf: temporaryURL)
    }
}
