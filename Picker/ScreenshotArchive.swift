import AppKit
import Photos
import CryptoKit

struct ExportedResource: Codable {
    let filename: String
    let sha256: String
    let bytes: Int
}
struct ExportedScreenshot: Codable {
    let id: String
    let modified: Date?
    let created: Date?
    let files: [ExportedResource]
}
struct ScreenshotExport: Codable {
    let exportedAt: Date
    let assets: [ExportedScreenshot]
}

enum ArchiveError: LocalizedError {
    case changed, emptyFile, missingResources
    var errorDescription: String? {
        switch self {
        case .changed: "A screenshot or exported file changed. Nothing was deleted. Export again before deleting."
        case .emptyFile: "An exported file is empty. Nothing was deleted."
        case .missingResources: "Photos couldn’t provide the screenshot’s original resources. Nothing was deleted."
        }
    }
}

actor ScreenshotExporter {
    static func digest(_ url: URL) throws -> (hash: String, bytes: Int) {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        var bytes = 0
        while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty {
            hash.update(data: chunk)
            bytes += chunk.count
        }
        guard bytes > 0 else { throw ArchiveError.emptyFile }
        return (hash.finalize().map { String(format: "%02x", $0) }.joined(), bytes)
    }
    func export(ids: [String], to folder: URL, progress: @escaping @Sendable (Int, Int) -> Void) async throws -> ScreenshotExport {
        var exported: [ExportedScreenshot] = []
        for (index, id) in ids.enumerated() {
            try Task.checkCancellation()
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { throw ArchiveError.changed }
            let modified = asset.modificationDate
            let resources = PHAssetResource.assetResources(for: asset)
            guard resources.contains(where: { $0.type == .photo }) else { throw ArchiveError.missingResources }
            let prefix = UUID().uuidString
            var files: [ExportedResource] = []
            for (resourceIndex, resource) in resources.enumerated() {
                try Task.checkCancellation()
                let original = URL(fileURLWithPath: resource.originalFilename).lastPathComponent
                let name = "\(prefix)-\(resourceIndex)-\(original)"
                let url = folder.appendingPathComponent(name)
                let options = PHAssetResourceRequestOptions()
                options.isNetworkAccessAllowed = true
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    }
                }
                let digest = try Self.digest(url)
                files.append(ExportedResource(filename: name, sha256: digest.hash, bytes: digest.bytes))
            }
            guard let current = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject,
                  current.modificationDate == modified else { throw ArchiveError.changed }
            exported.append(ExportedScreenshot(id: id, modified: modified, created: asset.creationDate, files: files))
            progress(index + 1, ids.count)
        }
        try Task.checkCancellation()
        let manifest = ScreenshotExport(exportedAt: .now, assets: exported)
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("Picker Export.json"), options: .atomic)
        return manifest
    }
    func verify(_ manifest: ScreenshotExport, in folder: URL) throws {
        guard !manifest.assets.isEmpty else { throw ArchiveError.missingResources }
        for asset in manifest.assets {
            guard !asset.files.isEmpty else { throw ArchiveError.missingResources }
            for resource in asset.files {
                let digest = try Self.digest(folder.appendingPathComponent(resource.filename))
                guard digest.hash == resource.sha256, digest.bytes == resource.bytes else { throw ArchiveError.changed }
            }
        }
    }
}

@MainActor @Observable
final class ScreenshotArchive {
    var photos: [Photo] = []
    var selected = Set<String>()
    var busy = false
    var status = ""
    var completed = 0
    var error: String?
    var export: ScreenshotExport?
    var folder: URL?
    private var scopedFolder: URL?
    private var task: Task<Void, Never>?
    private let exporter = ScreenshotExporter()

    func load() {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d AND (mediaSubtypes & %d) != 0", PHAssetMediaType.image.rawValue, PHAssetMediaSubtype.photoScreenshot.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        var result: [Photo] = []
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in
            result.append(Photo(id: asset.localIdentifier, date: asset.creationDate ?? .distantPast, modified: asset.modificationDate,
                                width: asset.pixelWidth, height: asset.pixelHeight, favorite: asset.isFavorite, live: false, score: 0))
        }
        photos = result
        selected = Set(result.map(\.id))
    }
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Export Screenshots"
        panel.message = "Choose where to save your screenshots. Exporting originals may download the selected screenshots from iCloud. Photos won’t be deleted until you confirm after export."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        releaseAccess()
        if parent.startAccessingSecurityScopedResource() { scopedFolder = parent }
        let destination = parent.appendingPathComponent("Picker Screenshots \(UUID().uuidString.prefix(8))", isDirectory: true)
        do { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false) }
        catch { self.error = error.localizedDescription; releaseAccess(); return }
        folder = destination
        export = nil
        let ids = photos.filter { selected.contains($0.id) }.map(\.id)
        busy = true
        completed = 0
        status = "Exporting \(ids.count) screenshots through Photos…"
        task = Task {
            do {
                export = try await exporter.export(ids: ids, to: destination) { [self] count, total in
                    Task { @MainActor in
                        self.completed = count
                        self.status = "Exported \(count) of \(total) screenshots"
                    }
                }
                status = "Export verified. You can now delete these screenshots from Photos."
            } catch {
                self.error = error is CancellationError ? "Export stopped. Nothing was deleted. Any completed files remain in the export folder." : "Export didn’t finish. Nothing was deleted. \(error.localizedDescription)"
                export = nil
            }
            busy = false
            task = nil
        }
    }
    func cancel() { task?.cancel() }
    func releaseAccess() {
        scopedFolder?.stopAccessingSecurityScopedResource()
        scopedFolder = nil
    }
    func deleteExported() async {
        guard let export, let folder, !busy else { return }
        busy = true
        status = "Verifying exported files before deletion…"
        defer { busy = false }
        do {
            try await exporter.verify(export, in: folder)
            var assets: [PHAsset] = []
            for item in export.assets {
                guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [item.id], options: nil).firstObject,
                      asset.modificationDate == item.modified else { throw ArchiveError.changed }
                assets.append(asset)
            }
            try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(assets as NSArray) }
            self.export = nil
            load()
            status = "Exported \(assets.count) screenshots and moved them to Recently Deleted in Photos."
        } catch {
            self.error = "Screenshots weren’t deleted. Your exported files are saved. \(error.localizedDescription)"
        }
    }
}
