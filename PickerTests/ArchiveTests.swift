import XCTest
@testable import Picker

final class ArchiveTests: XCTestCase {
    func fixture() throws -> (URL, ScreenshotExport) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("screenshot.png")
        try Data("original screenshot contents".utf8).write(to: file)
        let digest = try ScreenshotExporter.digest(file)
        let manifest = ScreenshotExport(exportedAt: .now, assets: [ExportedScreenshot(id: "test", modified: nil, created: nil,
            files: [ExportedResource(filename: "screenshot.png", sha256: digest.hash, bytes: digest.bytes)])])
        return (folder, manifest)
    }
    func testVerifiedArchiveAndManifestRoundTrip() async throws {
        let (folder, manifest) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let restored = try JSONDecoder().decode(ScreenshotExport.self, from: JSONEncoder().encode(manifest))
        try await ScreenshotExporter().verify(restored, in: folder)
        XCTAssertEqual(restored.assets.first?.id, "test")
    }
    func testChangedExportBlocksDeletionVerification() async throws {
        let (folder, manifest) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("modified screenshot content!".utf8).write(to: folder.appendingPathComponent("screenshot.png"))
        do {
            try await ScreenshotExporter().verify(manifest, in: folder)
            XCTFail("Changed exports must block deletion")
        } catch { XCTAssertTrue(error is ArchiveError) }
    }
    func testMissingExportBlocksDeletionVerification() async throws {
        let (folder, manifest) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.removeItem(at: folder.appendingPathComponent("screenshot.png"))
        do {
            try await ScreenshotExporter().verify(manifest, in: folder)
            XCTFail("Missing exports must block deletion")
        } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
    }
    func testEmptyFilesAreRejected() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertThrowsError(try ScreenshotExporter.digest(folder))
    }
}
