import SwiftUI
import Photos

struct PhotoView: View {
    let photo: Photo
    var large = false
    @Environment(\.displayScale) private var displayScale
    @State private var image: NSImage?
    @State private var unavailable = false
    @State private var needsDownload = false
    @State private var requests: [PHImageRequestID] = []
    @State private var generation = UUID()
    @State private var loadingPreview = false
    @State private var previewLoaded = false
    @State private var downloadProgress: Double?
    @State private var failure: String?
    @State private var requestedSize = CGSize(width: 600, height: 600)

    var body: some View {
        GeometryReader { geometry in
            let target = previewTarget(for: geometry.size)
            content
                .task(id: "\(photo.id)-\(photo.modified?.timeIntervalSince1970 ?? 0)-\(large)-\(target.width)-\(target.height)") {
                    guard geometry.size.width > 0, geometry.size.height > 0 else { return }
                    load(targetSize: target)
                }
        }
        .onDisappear { cancelRequests() }
        .accessibilityLabel("Photo from \(photo.date.formatted(date: .abbreviated, time: .shortened))")
    }

    private var content: some View {
        ZStack(alignment: .bottom) {
            Rectangle().fill(.quaternary.opacity(0.5))
            if let image {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if unavailable && !loadingPreview {
                VStack(spacing: 8) {
                    Image(systemName: "icloud.slash").font(.title2)
                    Text(large ? "Preview unavailable" : "Not available locally").font(.caption)
                }.foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !large {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if large && loadingPreview {
                HStack(spacing: 8) {
                    if let downloadProgress {
                        ProgressView(value: downloadProgress).frame(width: 80)
                        Text("Downloading from iCloud · \(Int(downloadProgress * 100))%")
                    } else {
                        ProgressView().controlSize(.small)
                        Text("Loading preview…")
                    }
                }.font(.caption).padding(12).background(.regularMaterial, in: Capsule()).padding(12)
            } else if large && needsDownload {
                HStack(spacing: 8) {
                    Text("Higher quality is in iCloud")
                    Button("Download This Photo") { downloadCurrentPhoto() }
                        .help("Allow Apple Photos to download this image. It may fetch the original; no other photos are downloaded.")
                }.font(.caption).padding(12).background(.regularMaterial, in: Capsule()).padding(12)
            } else if large, let failure {
                HStack(spacing: 8) {
                    Label(failure, systemImage: "exclamationmark.icloud")
                    Button("Retry") { load(targetSize: requestedSize) }
                }.font(.caption).padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)).padding(12)
            }
        }
    }

    private func cancelRequests() {
        // Invalidate callbacks already dispatched to the main actor before cancelling PhotoKit work.
        generation = UUID()
        for request in requests { PHImageManager.default().cancelImageRequest(request) }
        requests = []
    }

    private func previewTarget(for size: CGSize) -> CGSize {
        guard large else { return CGSize(width: 600, height: 600) }
        let width = CGFloat(max(photo.width, 1))
        let height = CGFloat(max(photo.height, 1))
        let fit = min(size.width * displayScale / width, size.height * displayScale / height)
        // Quantization avoids repeated requests for every pixel while resizing the window.
        let edge = min(2560, max(width, height), max(256, ceil(max(width, height) * fit / 256) * 256))
        let ratio = edge / max(width, height)
        return CGSize(width: (width * ratio).rounded(), height: (height * ratio).rounded())
    }

    private func load(targetSize: CGSize) {
        cancelRequests()
        let token = generation
        requestedSize = targetSize
        image = nil
        unavailable = false
        loadingPreview = large
        previewLoaded = false
        downloadProgress = nil
        failure = nil
        needsDownload = false
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [photo.id], options: nil).firstObject else {
            unavailable = true
            loadingPreview = false
            failure = large ? "This photo is no longer available in Photos." : nil
            return
        }
        let thumbnailOptions = PHImageRequestOptions()
        thumbnailOptions.isNetworkAccessAllowed = false
        thumbnailOptions.deliveryMode = .opportunistic
        thumbnailOptions.resizeMode = .fast
        let thumbnail = PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 600, height: 600), contentMode: .aspectFit, options: thumbnailOptions) { result, info in
            guard (info?[PHImageCancelledKey] as? Bool) != true else { return }
            Task { @MainActor in
                guard generation == token, !previewLoaded else { return }
                if let result { image = result }
                else if image == nil { unavailable = true }
            }
        }
        requests.append(thumbnail)
        guard large else { return }

        loadPreview(asset: asset, targetSize: targetSize, token: token, allowNetwork: false)
    }

    private func downloadCurrentPhoto() {
        guard needsDownload,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [photo.id], options: nil).firstObject else { return }
        needsDownload = false
        loadingPreview = true
        downloadProgress = 0
        loadPreview(asset: asset, targetSize: requestedSize, token: generation, allowNetwork: true)
    }

    private func loadPreview(asset: PHAsset, targetSize: CGSize, token: UUID, allowNetwork: Bool) {
        // Only an explicit Download This Photo click allows an iCloud request.
        // A bounded rendition avoids requesting the maximum-resolution original for every group.
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = allowNetwork
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.progressHandler = { progress, _, _, _ in
            Task { @MainActor in
                guard generation == token, loadingPreview else { return }
                downloadProgress = min(max(progress, 0), 1)
            }
        }
        let previewRequest = PHImageManager.default().requestImage(for: asset, targetSize: targetSize, contentMode: .aspectFit, options: options) { result, info in
            let cancelled = (info?[PHImageCancelledKey] as? Bool) == true
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
            let message = (info?[PHImageErrorKey] as? Error)?.localizedDescription
            let inCloud = (info?[PHImageResultIsInCloudKey] as? Bool) == true
            Task { @MainActor in
                guard generation == token, !cancelled else { return }
                if let result {
                    image = result
                    unavailable = false
                }
                guard !degraded else { return }
                if result == nil, !allowNetwork, inCloud {
                    needsDownload = true
                    loadingPreview = false
                    return
                }
                loadingPreview = false
                previewLoaded = result != nil
                if result == nil {
                    failure = message ?? "Couldn’t load the preview. Check your connection and try again."
                    unavailable = image == nil
                }
            }
        }
        requests.append(previewRequest)
    }
}
