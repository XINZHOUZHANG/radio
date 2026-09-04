import Foundation
import UniformTypeIdentifiers
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
}
