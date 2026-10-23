import AppKit
import Photos
import Vision

struct ScanResult {
    let library: SavedLibrary
    let progress: ScanProgress
}

actor PhotoAnalyzer {
    static let threshold: Float = 0.32
    private var loadedCache: SavedLibrary?

    func scan(retryUnavailable: Bool = false, update: @escaping @Sendable (ScanUpdate) async -> Void) async throws -> ScanResult {
        var cache = loadedCache ?? LocalStore.read(SavedLibrary.self, name: "analysis.json") ?? SavedLibrary()
        if cache.version != 1 { cache = SavedLibrary() }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        let fetched = PHAsset.fetchAssets(with: options)
        var assets: [String: PHAsset] = [:]
        var stamps: [AssetStamp] = []
        fetched.enumerateObjects { asset, _, _ in
            assets[asset.localIdentifier] = asset
            stamps.append(AssetStamp(id: asset.localIdentifier, date: asset.creationDate ?? .distantPast,
                                     modified: asset.modificationDate, width: asset.pixelWidth, height: asset.pixelHeight,
                                     favorite: asset.isFavorite, live: asset.mediaSubtypes.contains(.photoLive)))
        }
        let sessions = ScanPlanner.sessions(stamps).reversed()
        var pending: [(key: String, session: ScanSession)] = []
        var ready: [SimilarGroup] = []
        var completedSessions: [String: CachedSession] = [:]
        var progress = ScanProgress(total: fetched.count)
        for session in sessions {
            let key = session.key
            if let saved = cache.sessions?[key], !(retryUnavailable && saved.unavailable > 0) {
                completedSessions[key] = saved
                ready.append(contentsOf: saved.groups)
                progress.checked += saved.count
                progress.cached += saved.count - saved.unavailable
                progress.unavailable += saved.unavailable
            } else { pending.append((key, session)) }
        }
        await update(.prepared(previous: cache.groups, ready: ready, progress: progress))
        let manager = PHImageManager()
        let previousGroups = cache.groups
        let needsCacheWrite = !pending.isEmpty || Set(cache.sessions?.keys.map { $0 } ?? []) != Set(completedSessions.keys)
        cache.groups = ready
        cache.sessions = completedSessions
        var recordsSinceCheckpoint = 0
        var pendingGroups: [SimilarGroup] = []
        var lastReport = Date.distantPast
        do {
            for (key, session) in pending {
                try Task.checkCancellation()
                var active: [(photos: [Photo], feature: VNFeaturePrintObservation)] = []
                var completed: [SimilarGroup] = []
                var unavailable = 0
                for stamp in session.assets {
                    try Task.checkCancellation()
                    // Once the timestamp passes a representative's window, later assets cannot join it.
                    let expired = active.filter { ScanPlanner.isClosed(representative: $0.photos[0].date, next: stamp.date) }
                    let closedGroups = expired.filter { $0.photos.count > 1 }.map { SimilarGroup(photos: $0.photos) }
                    active.removeAll { ScanPlanner.isClosed(representative: $0.photos[0].date, next: stamp.date) }
                    completed.append(contentsOf: closedGroups)
                    pendingGroups.append(contentsOf: closedGroups)
                    cache.groups.append(contentsOf: closedGroups)

                    let entry: (Photo, VNFeaturePrintObservation)? = autoreleasepool {
                        if let record = cache.records[stamp.id], stamp.canReuseFeature(record),
                           let feature = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: record.feature) {
                            progress.cached += 1
                            let photo = stamp.photo(score: record.photo.score)
                            cache.records[stamp.id] = AnalysisRecord(photo: photo, feature: record.feature)
                            return (photo, feature)
                        }
                        cache.records.removeValue(forKey: stamp.id)
                        guard let asset = assets[stamp.id] else { return nil }
                        let options = PHImageRequestOptions()
                        options.isSynchronous = true
                        options.isNetworkAccessAllowed = false
                        options.deliveryMode = .highQualityFormat
                        options.resizeMode = .fast
                        var bitmap: CGImage?
                        manager.requestImage(for: asset, targetSize: CGSize(width: 768, height: 768), contentMode: .aspectFit, options: options) { image, info in
                            guard (info?[PHImageResultIsDegradedKey] as? Bool) != true else { return }
                            bitmap = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                        }
                        guard let bitmap else { return nil }
                        let featureRequest = VNGenerateImageFeaturePrintRequest()
                        featureRequest.revision = VNGenerateImageFeaturePrintRequestRevision2
                        let aesthetics = VNCalculateImageAestheticsScoresRequest()
                        do {
                            try VNImageRequestHandler(cgImage: bitmap).perform([featureRequest, aesthetics])
                            guard let feature = featureRequest.results?.first else { return nil }
                            let photo = stamp.photo(score: aesthetics.results?.first?.overallScore ?? 0)
                            let data = try NSKeyedArchiver.archivedData(withRootObject: feature, requiringSecureCoding: true)
                            cache.records[stamp.id] = AnalysisRecord(photo: photo, feature: data)
                            progress.analyzed += 1
                            recordsSinceCheckpoint += 1
                            return (photo, feature)
                        } catch { return nil }
                    }
                    if let (photo, feature) = entry {
                        var match: Int?
                        var best = Self.threshold
                        if photo.date != .distantPast {
                            for candidate in active.indices {
                                var distance: Float = 1
                                if (try? feature.computeDistance(&distance, to: active[candidate].feature)) != nil, distance < best {
                                    best = distance
                                    match = candidate
                                }
                            }
                        }
                        if let match { active[match].photos.append(photo) }
                        else { active.append(([photo], feature)) }
                    } else { unavailable += 1; progress.unavailable += 1 }
                    progress.checked += 1
                    if Date().timeIntervalSince(lastReport) > 0.2 {
                        if !pendingGroups.isEmpty { await update(.completedGroups(pendingGroups)); pendingGroups = [] }
                        await update(.progress(progress))
                        lastReport = Date()
                    }
                    if recordsSinceCheckpoint >= 100 {
                        try LocalStore.write(cache, name: "analysis.json")
                        recordsSinceCheckpoint = 0
                    }
                }
                let remaining = active.filter { $0.photos.count > 1 }.map { SimilarGroup(photos: $0.photos) }
                completed.append(contentsOf: remaining)
                pendingGroups.append(contentsOf: remaining)
                cache.groups.append(contentsOf: remaining)
                cache.sessions?[key] = CachedSession(groups: completed, unavailable: unavailable, count: session.assets.count)
                if Date().timeIntervalSince(lastReport) > 0.2 || progress.checked == progress.total {
                    if !pendingGroups.isEmpty { await update(.completedGroups(pendingGroups)); pendingGroups = [] }
                    await update(.progress(progress))
                    lastReport = Date()
                }
            }
            try Task.checkCancellation()
            cache.records = cache.records.filter { assets[$0.key] != nil }
            cache.groups.sort { $0.date > $1.date }
            if needsCacheWrite { try LocalStore.write(cache, name: "analysis.json") }
            loadedCache = cache
            return ScanResult(library: cache, progress: progress)
        } catch {
            if !pendingGroups.isEmpty { await update(.completedGroups(pendingGroups)) }
            await update(.progress(progress))
            // Preserve analyzed records and closed groups on cancellation as well as on normal completion.
            // Keep previous group metadata for decisions belonging to unfinished windows.
            let readyIDs = Set(cache.groups.map(\.id))
            cache.groups.append(contentsOf: previousGroups.filter { !readyIDs.contains($0.id) })
            try? LocalStore.write(cache, name: "analysis.json")
            loadedCache = cache
            throw error
        }
    }
}
