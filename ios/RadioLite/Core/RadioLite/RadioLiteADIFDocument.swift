import Foundation
import UniformTypeIdentifiers

enum RadioLiteADIFDocument {
    static let typeIdentifier = "xyz.992218.radio-lite.adif"
    static let contentType = UTType(importedAs: typeIdentifier, conformingTo: .plainText)
    static let supportedFilenameExtensions = ["adi", "adif"]
    // Some Files providers expose an unknown ADI extension only as public.item.
    // Let the picker return those URLs, then enforce the ADIF extension ourselves.
    static let allowedContentTypes: [UTType] = [.item]

    static func supportsImportURL(_ url: URL) -> Bool {
        supportedFilenameExtensions.contains(url.pathExtension.lowercased())
    }

    static func validateImportURL(_ url: URL) throws {
        guard supportsImportURL(url) else {
            throw ImportValidationError.unsupportedFilenameExtension
        }
    }

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

    private enum ImportValidationError: LocalizedError {
        case unsupportedFilenameExtension

        var errorDescription: String? {
            "请选择扩展名为 .adi 或 .adif 的日志文件。"
        }
    }
}
