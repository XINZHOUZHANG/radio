import Foundation
import UniformTypeIdentifiers
import UIKit
import XCTest
@testable import RadioLite

final class RadioLiteADIFDocumentTests: XCTestCase {
    func testADIFContentTypeHasStableIdentifierAndTextConformance() {
        XCTAssertEqual(
            RadioLiteADIFDocument.contentType.identifier,
            "xyz.992218.radio-lite.adif"
        )
        XCTAssertTrue(RadioLiteADIFDocument.contentType.isDeclared)
        XCTAssertTrue(RadioLiteADIFDocument.contentType.conforms(to: .plainText))
        XCTAssertTrue(RadioLiteADIFDocument.contentType.conforms(to: .data))
        XCTAssertEqual(
            Set(RadioLiteADIFDocument.contentType.tags[.filenameExtension] ?? []),
            Set(["adi", "adif"])
        )
        XCTAssertEqual(RadioLiteADIFDocument.supportedFilenameExtensions, ["adi", "adif"])
    }

    func testPickerAcceptsProviderItemsThenValidatesFilenameExtension() throws {
        XCTAssertEqual(
            RadioLiteADIFDocument.allowedContentTypes.map(\.identifier),
            [UTType.item.identifier]
        )

        for filename in ["station.adi", "station.adif", "station.ADI", "station.ADIF"] {
            let url = URL(fileURLWithPath: "/tmp/\(filename)")
            XCTAssertTrue(RadioLiteADIFDocument.supportsImportURL(url), filename)
            XCTAssertNoThrow(try RadioLiteADIFDocument.validateImportURL(url), filename)
        }

        for filename in ["station.txt", "station", "station.adi.zip"] {
            let url = URL(fileURLWithPath: "/tmp/\(filename)")
            XCTAssertFalse(RadioLiteADIFDocument.supportsImportURL(url), filename)
            XCTAssertThrowsError(try RadioLiteADIFDocument.validateImportURL(url), filename)
        }
    }

    func testCoordinatedReaderCopiesSelectedFileBeforeReturningData() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("radio-lite-adif-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sample.ADIF")
        let expected = Data("<CALL:6>JA1ABC<EOR>".utf8)
        try expected.write(to: url)

        let actual = try await RadioLiteADIFDocument.readCoordinatedData(from: url)

        XCTAssertEqual(actual, expected)
    }

    @MainActor
    func testDocumentPickerCoordinatorForwardsOnlyTheFirstSelection() {
        let firstURL = URL(fileURLWithPath: "/tmp/first.adi")
        let secondURL = URL(fileURLWithPath: "/tmp/second.adi")
        var selectedURLs: [URL] = []
        var cancellationCount = 0
        let coordinator = RadioLiteADIFDocumentPicker.Coordinator(
            onResult: { result in
                if case let .success(url) = result {
                    selectedURLs.append(url)
                }
            },
            onCancel: { cancellationCount += 1 }
        )
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.item],
            asCopy: true
        )

        coordinator.documentPicker(picker, didPickDocumentsAt: [firstURL])
        coordinator.documentPicker(picker, didPickDocumentsAt: [secondURL])
        coordinator.documentPickerWasCancelled(picker)

        XCTAssertEqual(selectedURLs, [firstURL])
        XCTAssertEqual(cancellationCount, 0)
    }

    @MainActor
    func testDocumentPickerCoordinatorForwardsCancellationOnlyOnce() {
        var resultCount = 0
        var cancellationCount = 0
        let coordinator = RadioLiteADIFDocumentPicker.Coordinator(
            onResult: { _ in resultCount += 1 },
            onCancel: { cancellationCount += 1 }
        )
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.item],
            asCopy: true
        )

        coordinator.documentPickerWasCancelled(picker)
        coordinator.documentPickerWasCancelled(picker)
        coordinator.documentPicker(picker, didPickDocumentsAt: [])

        XCTAssertEqual(resultCount, 0)
        XCTAssertEqual(cancellationCount, 1)
    }
}
