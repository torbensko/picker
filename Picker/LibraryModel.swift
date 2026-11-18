import AppKit
import Photos
import SwiftUI

enum ReviewFilter: String, CaseIterable, Identifiable {
    case all = "Similar Photos", cleanup = "Cleanup", pending = "Pending", history = "History"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .all: "square.stack"
        case .cleanup: "photo.on.rectangle"
        case .pending: "tray.full"
        case .history: "clock.arrow.circlepath"
        }
    }
}

enum DeletionScope { case currentGroup, pending }

@MainActor @Observable
final class LibraryModel: NSObject, PHPhotoLibraryChangeObserver {
    var authorization: PHAuthorizationStatus
    var groups: [SimilarGroup] = []
    var decisions: [String: Decision] = [:]
    private(set) var cleanupCatalog: [CleanupPhoto] = []
    private var cleanupByID: [String: CleanupPhoto] = [:]
    private var cleanupMarks: [String: Photo] = [:]
    private var viewedCleanupPhotos: [String: Photo] = [:]
    private(set) var cleanupReady = false
    var cleanupNotice: String?

    var history: [String: ProcessedGroup] = [:] {
        didSet { rebuildProcessedKeepers() }
    }
    private var processedKeepersByAssetID: [String: [Photo]] = [:]
    var deletionPlan: [ProcessedGroup] = []
    var deletionScope: DeletionScope = .pending
    var filter: ReviewFilter = .all
    var selectedID: String?
    var highlightedID: String?
    var preview = false
    var showQueue = false
    var showScreenshots = false
    var scanning = false
    var preparingReview = false
    var deleting = false
    var scanned = 0
    var cachedPhotos = 0
    var newlyAnalyzed = 0
    private var readyGroupIDs = Set<String>()
    private var comparisonGroups: [String: SimilarGroup] = [:]
    private var resumeAfterReview = false
    var total = 0
    var unavailable = 0
    var hasScanned = false
    var status = "Your photos stay on your Mac."
    var errorMessage: String?
    private var scanTask: Task<Void, Never>?
    private var registered = false
    private var needsRefresh = false
    private let analyzer = PhotoAnalyzer()
    private let persistenceEnabled: Bool

    typealias DeleteAssets = @MainActor ([Photo], Set<String>) async throws -> Void
    private let deleteAssets: DeleteAssets

    init(persistenceEnabled: Bool = true, deleteAssets: DeleteAssets? = nil) {
        self.persistenceEnabled = persistenceEnabled
        self.authorization = persistenceEnabled ? PHPhotoLibrary.authorizationStatus(for: .readWrite) : .notDetermined
        self.deleteAssets = deleteAssets ?? (persistenceEnabled ? Self.deleteUsingPhotoKit : { _, _ in
            throw DeletionError.permission
        })
        super.init()
    }

    // A screenshot sheet may own an export or deletion task. Wait for it to close,
    // and for scan checkpoints and PhotoKit changes to finish, before restarting.
    var blocksUpdateRelaunch: Bool { scanning || preparingReview || deleting || showQueue || showScreenshots }

    var hasAccess: Bool { authorization == .authorized || authorization == .limited }
    var selectedGroup: SimilarGroup? {
        if filter == .pending || filter == .cleanup { return nil }
        if filter == .history { return selectedHistory?.group }
        return groups.first { $0.id == selectedID }
    }
    var selectedHistory: ProcessedGroup? { selectedID.flatMap { history[$0] } }
    var historyEntries: [ProcessedGroup] { history.values.sorted { $0.processedAt > $1.processedAt } }
    var pendingCleanup: [Photo] {
        cleanupMarks.values.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
    }
    var queuedGroups: [SimilarGroup] { groups.filter { matches($0, filter: .pending) } }
    var potentialRemovalCount: Int { groups.reduce(0) { $0 + max($1.photos.count - 1, 0) } }
    var deletionPhotos: [Photo] {
        let groupRemovals = queuedGroups.flatMap { ReviewRules.deletions(in: $0, decision: decisions[$0.id]) }
        let groupedIDs = Set(groupRemovals.map(\.id))
        return groupRemovals + pendingCleanup.filter { !groupedIDs.contains($0.id) }
    }
    var visibleGroups: [SimilarGroup] {
        if filter == .history { return historyEntries.map(\.group) }
        return groups.filter { matches($0, filter: filter) }
    }
    var highlighted: Photo? { selectedGroup?.photos.first { $0.id == highlightedID } }
    var plannedPhotos: [Photo] { deletionPlan.flatMap(\.removals) }
    var canOpenQueue: Bool { !deletionPhotos.isEmpty && (cleanupMarks.isEmpty || (cleanupReady && !needsRefresh)) }

    func matches(_ group: SimilarGroup, filter: ReviewFilter) -> Bool {
        switch filter {
        case .cleanup: return false
        case .all:
            guard history[group.id] == nil || history[group.id]?.invalidated == true else { return false }
            return !isProcessedKeeperGroup(group)
        case .pending:
            return matches(group, filter: .all) && !ReviewRules.deletions(in: group, decision: decisions[group.id]).isEmpty
        case .history: return history[group.id] != nil
        }
    }
    private func rebuildProcessedKeepers() {
        var retained: [String: [Photo]] = [:]
        for entry in history.values.filter({ $0.deletedAt != nil && $0.manual != true }).sorted(by: { $0.processedAt < $1.processedAt }) {
            let keepers = entry.group.photos.filter { entry.decision.keepers.contains($0.id) }
            for photo in keepers { retained[photo.id] = keepers }
        }
        processedKeepersByAssetID = retained
    }
    private func isProcessedKeeperGroup(_ group: SimilarGroup) -> Bool {
        guard let id = group.photos.first?.id, let retained = processedKeepersByAssetID[id] else { return false }
        // Deletion changes group membership; unchanged surviving keepers are already reviewed.
        return group.photos.allSatisfy { retained.contains($0) }
    }
    func sidebarCount(_ filter: ReviewFilter) -> Int {
        switch filter {
        case .cleanup: return cleanupCatalog.count
        case .all: return groups.filter { matches($0, filter: .all) }.count
        case .pending: return deletionPhotos.count
        case .history: return history.count
        }
    }
    func canApply(_ group: SimilarGroup) -> Bool {
        guard canReview(group), let decision = decisions[group.id], ReviewRules.valid(decision, in: group),
              !ReviewRules.deletions(in: group, decision: decision).isEmpty
                || decision.keepers.count == group.photos.count else { return false }
        return history[group.id]?.decision != decision || history[group.id]?.invalidated == true
    }
    func applyCurrentGroup() {
        guard let group = selectedGroup, canApply(group), let decision = decisions[group.id] else { return }
        if !ReviewRules.deletions(in: group, decision: decision).isEmpty {
            openDeletionReview([ProcessedGroup(group: group, decision: decision, processedAt: .now)], scope: .currentGroup)
            return
        }
        // Keeping everything resolves the group without a destructive confirmation.
        let next = visibleGroups.drop(while: { $0.id != group.id }).dropFirst().first
        history[group.id] = ProcessedGroup(group: group, decision: decision, processedAt: .now)
        saveHistory()
        if filter == .all { select(next ?? visibleGroups.first) }
    }
    func keepPending(_ photo: Photo, group: SimilarGroup) {
        guard queuedGroups.contains(where: { $0.id == group.id }) else { return }
        setKeeper(photo, in: group, keep: true)
    }
    func reviewPendingGroup(_ group: SimilarGroup) {
        filter = .all
        select(group)
    }
    func restoreReviewState() {
        // Migrate the earlier Apply-to-Pending flow without losing any choices.
        for (id, entry) in history where entry.deletedAt == nil && entry.manual != true && !entry.decision.skipped
            && !ReviewRules.deletions(in: entry.group, decision: entry.decision).isEmpty {
            if !entry.invalidated, decisions[id] == nil { decisions[id] = entry.decision }
            history[id] = nil
        }
    }
    func saveHistory() {
        guard persistenceEnabled else { return }
        do { try LocalStore.write(history, name: "history.json") }
        catch { errorMessage = "Review history couldn’t be saved: \(error.localizedDescription)" }
    }
    func start() {
        guard persistenceEnabled else { return }
        guard hasAccess else { return }
        if !registered {
            PHPhotoLibrary.shared().register(self)
            registered = true
            // The analyzer validates cached groups off the main actor before publishing them.
            decisions = LocalStore.read([String: Decision].self, name: "decisions.json") ?? [:]
            history = LocalStore.read([String: ProcessedGroup].self, name: "history.json") ?? [:]
            cleanupMarks = LocalStore.read([String: Photo].self, name: "cleanup-pending.json") ?? [:]
            restoreReviewState()
            refresh()
        }
    }
    func connect() async {
        authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        start()
    }
    func refresh(retryUnavailable: Bool = false) {
        guard persistenceEnabled, hasAccess, !scanning, !deleting, !showQueue, !showScreenshots, !preparingReview else { return }
        scanning = true
        cleanupReady = false
        scanned = 0
        status = "Checking for library changes…"
        scanTask = Task {
            do {
                let result = try await analyzer.scan(retryUnavailable: retryUnavailable) { [self] event in
                    await self.applyScanUpdate(event)
                }
                // Incremental updates already reconciled each completed group. Do not overwrite live choices.
                acceptCompletedGroups(result.library.groups)
                let validIDs = Set(result.library.groups.map(\.id))
                groups.removeAll { !validIDs.contains($0.id) }
                decisions = decisions.filter { validIDs.contains($0.key) }
                for (id, var entry) in history where entry.deletedAt == nil && !validIDs.contains(id) {
                    entry.invalidated = true
                    history[id] = entry
                }
                updateCleanupCatalog(result.cleanupPhotos)
                saveHistory()
                applyProgress(result.progress)
                hasScanned = true
                status = "Library up to date."
                saveDecisions()
                if selectedGroup == nil { ensureSelection() }
            } catch is CancellationError {
                status = "Scan paused. Scan again to resume from cached analysis."
            } catch {
                errorMessage = error.localizedDescription
                status = "The scan couldn’t finish."
            }
            scanning = false
            scanTask = nil
            resumeRefreshIfNeeded()
        }
    }
    func canReview(_ group: SimilarGroup) -> Bool {
        !group.photos.isEmpty && !deleting && !showQueue && !preparingReview && !showScreenshots
            && groups.contains(group) && history[group.id]?.deletedAt == nil
            && !(filter == .history && history[group.id]?.invalidated == true)
            && (!scanning || readyGroupIDs.contains(group.id))
    }
    func applyScanUpdate(_ update: ScanUpdate) {
        switch update {
        case let .prepared(previous, ready, progress):
            comparisonGroups = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
            // Prefer the current view's metadata when a scan is running in an existing session.
            for group in groups { comparisonGroups[group.id] = group }
            groups = []
            readyGroupIDs = []
            acceptCompletedGroups(ready)
            applyProgress(progress)
        case let .completedGroups(completed):
            acceptCompletedGroups(completed)
        case let .progress(progress):
            applyProgress(progress)
        }
    }
    func acceptCompletedGroups(_ completed: [SimilarGroup]) {
        var byID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        var invalidatedDecision = false
        for group in completed {
            if !ReviewRules.unchanged(comparisonGroups[group.id], group), decisions[group.id] != nil {
                decisions[group.id] = nil
                invalidatedDecision = true
            }
            if var applied = history[group.id], applied.deletedAt == nil, !ReviewRules.unchanged(applied.group, group) {
                applied.invalidated = true
                history[group.id] = applied
                saveHistory()
            }
            if history[group.id] == nil, decisions[group.id]?.skipped == true {
                history[group.id] = ProcessedGroup(group: group, decision: Decision(skipped: true), processedAt: .now)
                saveHistory()
            }
            comparisonGroups[group.id] = group
            byID[group.id] = group
            readyGroupIDs.insert(group.id)
        }
        groups = byID.values.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
        // New background results must not move the photo currently being reviewed.
        if selectedGroup == nil { ensureSelection() }
        if invalidatedDecision { saveDecisions() }
    }
    private func applyProgress(_ progress: ScanProgress) {
        scanned = progress.checked
        total = progress.total
        cachedPhotos = progress.cached
        newlyAnalyzed = progress.analyzed
        unavailable = progress.unavailable
    }
    func openQueue() {
        guard canOpenQueue else { return }
        var plan = queuedGroups.compactMap { group in
            decisions[group.id].map { ProcessedGroup(group: group, decision: $0, processedAt: .now) }
        }
        let manual = pendingCleanup
        if !manual.isEmpty {
            plan.append(ProcessedGroup(group: SimilarGroup(photos: manual),
                                       decision: Decision(discards: Set(manual.map(\.id))),
                                       processedAt: .now, manual: true))
        }
        openDeletionReview(plan, scope: .pending)
    }
    private func openDeletionReview(_ plan: [ProcessedGroup], scope: DeletionScope) {
        guard !plan.isEmpty else { return }
        prepareReview {
            guard self.isDeletionPlanCurrent(plan) else {
                self.errorMessage = "This group or its choices changed. Review the updated photos before deleting."
                return
            }
            self.deletionPlan = plan
            self.deletionScope = scope
            self.showQueue = true
        }
    }
    func openScreenshots() { prepareReview { self.showScreenshots = true } }
    private func prepareReview(_ present: @escaping () -> Void) {
        guard !preparingReview, !deleting, !showQueue, !showScreenshots else { return }
        preparingReview = true
        resumeAfterReview = scanning
        if let scanTask {
            Task {
                scanTask.cancel()
                await scanTask.value
                present()
                preparingReview = false
                resumeRefreshIfNeeded()
            }
        } else {
            present()
            preparingReview = false
            resumeRefreshIfNeeded()
        }
    }
    func isDeletionPlanCurrent(_ plan: [ProcessedGroup]) -> Bool {
        !plan.isEmpty && plan.allSatisfy { entry in
            if entry.manual == true {
                return cleanupReady && !needsRefresh && entry.removals == entry.group.photos
                    && entry.group.photos.allSatisfy { cleanupByID[$0.id]?.photo == $0 && cleanupMarks[$0.id] == $0 }
                    && Set(entry.group.photos.map(\.id)) == Set(cleanupMarks.keys)
            }
            guard let current = groups.first(where: { $0.id == entry.id }) else { return false }
            return matches(current, filter: .pending) && ReviewRules.unchanged(entry.group, current)
                && decisions[entry.id] == entry.decision
        }
    }
    private func resumeRefreshIfNeeded() {
        guard !scanning, !deleting, !showQueue, !showScreenshots, !preparingReview, needsRefresh || resumeAfterReview else { return }
        needsRefresh = false
        resumeAfterReview = false
        refresh()
    }
    func cancelScan() { scanTask?.cancel() }
    func ensureSelection() {
        if filter == .history {
            if selectedHistory == nil { selectedID = historyEntries.first?.id }
            return
        }
        guard filter == .all else { return }
        if !visibleGroups.contains(where: { $0.id == selectedID }) { select(visibleGroups.first) }
        else if highlighted == nil { highlightedID = selectedGroup?.suggestedID }
    }
    func select(_ group: SimilarGroup?) {
        selectedID = group?.id
        highlightedID = group?.suggestedID
    }
    func movePhoto(_ delta: Int) {
        guard let group = selectedGroup, !group.photos.isEmpty else { return }
        let index = group.photos.firstIndex { $0.id == highlightedID } ?? 0
        highlightedID = group.photos[(index + delta + group.photos.count) % group.photos.count].id
    }
    func moveGroup(_ delta: Int) {
        if filter == .history {
            let ids = historyEntries.map(\.id)
            guard let index = ids.firstIndex(of: selectedID ?? "") else { return }
            selectedID = ids[min(max(index + delta, 0), ids.count - 1)]
        } else {
            let list = visibleGroups
            guard !list.isEmpty else { return }
            let index = list.firstIndex { $0.id == selectedID } ?? 0
            select(list[min(max(index + delta, 0), list.count - 1)])
        }
    }
    func chooseHighlighted() {
        guard let group = selectedGroup, let highlighted else { return }
        setKeeper(highlighted, in: group, keep: true)
    }

    func markEntireGroup(_ group: SimilarGroup) {
        guard canReview(group) else { return }
        updateDecision(Decision(discards: Set(group.photos.map(\.id))), in: group)
    }

    func setKeeper(_ photo: Photo, in group: SimilarGroup, keep: Bool) {
        guard canReview(group), group.photos.contains(photo) else { return }
        let previous = decisions[group.id].flatMap { ReviewRules.valid($0, in: group) ? $0 : nil }
        var keepers = previous?.keepers ?? []
        var discards = Set(ReviewRules.deletions(in: group, decision: previous).map(\.id))
        if keep {
            // The first tick keeps a single photo and queues its alternatives.
            if keepers.isEmpty && discards.isEmpty {
                discards = Set(group.photos.map(\.id))
            }
            keepers.insert(photo.id)
            discards.remove(photo.id)
        } else {
            keepers.remove(photo.id)
            discards.insert(photo.id)
        }
        updateDecision(Decision(keepers: keepers, discards: discards), in: group)
    }

    private func updateDecision(_ decision: Decision, in group: SimilarGroup) {
        if let processed = history[group.id], processed.decision != decision || processed.invalidated {
            history[group.id] = nil
            saveHistory()
            if filter == .history { filter = .all; selectedID = group.id }
        }
        decisions[group.id] = decision
        saveDecisions()
    }
    func skip() {
        guard let group = selectedGroup, canReview(group) else { return }
        let next = visibleGroups.drop(while: { $0.id != group.id }).dropFirst().first
        decisions[group.id] = Decision(skipped: true)
        history[group.id] = ProcessedGroup(group: group, decision: Decision(skipped: true), processedAt: .now)
        saveHistory()
        saveDecisions()
        select(next ?? visibleGroups.first)
    }
    func reset(_ group: SimilarGroup) {
        guard canReview(group) else { return }
        decisions[group.id] = nil
        history[group.id] = nil
        saveHistory()
        saveDecisions()
        if filter == .history { filter = .all; select(groups.first { $0.id == group.id }) }
    }
    func saveDecisions() {
        guard persistenceEnabled else { return }
        do { try LocalStore.write(decisions, name: "decisions.json") }
        catch { errorMessage = "Your selections couldn’t be saved: \(error.localizedDescription)" }
    }
    func queueClosed() {
        if !deleting { deletionPlan = [] }
        ensureSelection()
        resumeRefreshIfNeeded()
    }
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.needsRefresh = true
            if !self.scanning && !self.deleting && !self.showQueue && !self.showScreenshots {
                self.needsRefresh = false
                self.refresh()
            }
        }
    }
    @discardableResult
    func deleteConfirmedPlan() -> Task<Void, Never>? {
        // SwiftUI may clear the presentation binding during the destructive button action.
        guard !deleting, !scanning, !deletionPlan.isEmpty else { return nil }
        deleting = true
        let plan = deletionPlan
        return Task { await deletePlannedPhotos(plan) }
    }

    private enum DeletionError: LocalizedError {
        case permission, changed, invalidChoices
        var errorDescription: String? {
            switch self {
            case .permission: "Allow Picker to access Photos, then try again."
            case .changed: "The library or your choices changed. Review Pending again."
            case .invalidChoices: "These choices no longer identify a valid deletion. Review Pending again."
            }
        }
    }

    private func deletePlannedPhotos(_ plan: [ProcessedGroup]) async {
        do {
            guard isDeletionPlanCurrent(plan) else { throw DeletionError.changed }
            let photos = plan.flatMap { $0.group.photos }
            let removals = plan.flatMap(\.removals)
            let ids = Set(removals.map(\.id))
            // A photo in overlapping entries must never be deleted on the strength of one entry alone.
            guard !ids.isEmpty, Set(photos.map(\.id)).count == photos.count else {
                throw DeletionError.invalidChoices
            }
            try await deleteAssets(photos, ids)
            recordDeletionSuccess(plan)
            total = max(total - ids.count, 0)
            status = "Moved \(ids.count.formatted()) photos to Recently Deleted."
        } catch {
            errorMessage = "Photos weren’t deleted. Your pending list is saved. \(error.localizedDescription)"
        }
        deleting = false
        showQueue = false
        deletionPlan = []
        if persistenceEnabled { needsRefresh = true }
        resumeRefreshIfNeeded()
    }

    private static func deleteUsingPhotoKit(_ photos: [Photo], ids: Set<String>) async throws {
        let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard authorization == .authorized || authorization == .limited else { throw DeletionError.permission }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: photos.map(\.id), options: nil)
        var current: [String: PHAsset] = [:]
        assets.enumerateObjects { asset, _, _ in current[asset.localIdentifier] = asset }
        guard photos.allSatisfy({ photo in
            guard let asset = current[photo.id] else { return false }
            return asset.mediaType == .image && (asset.creationDate ?? .distantPast) == photo.date
                && asset.modificationDate == photo.modified && asset.isFavorite == photo.favorite
                && asset.pixelWidth == photo.width && asset.pixelHeight == photo.height
                && asset.mediaSubtypes.contains(.photoLive) == photo.live
        }) else { throw DeletionError.changed }

        let removals = ids.compactMap { current[$0] }
        try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(removals as NSArray) }
    }

    func updateCleanupCatalog(_ photos: [CleanupPhoto]) {
        let grouped = Set(groups.flatMap { $0.photos.map(\.id) })
        cleanupCatalog = photos.filter { !grouped.contains($0.id) }
        cleanupByID = Dictionary(uniqueKeysWithValues: cleanupCatalog.map { ($0.id, $0) })
        viewedCleanupPhotos = viewedCleanupPhotos.filter { cleanupByID[$0.key]?.photo == $0.value }
        let validMarks = cleanupMarks.filter { cleanupByID[$0.key]?.photo == $0.value }
        let invalidated = cleanupMarks.count - validMarks.count
        if invalidated > 0 {
            cleanupNotice = "\(invalidated.formatted()) Cleanup marks were cleared because the photos changed, moved into a group, or are no longer available."
            cleanupMarks = validMarks
            saveCleanupMarks()
        }
        cleanupReady = true
    }

    func noteCleanupPreview(_ photo: Photo) {
        guard cleanupReady, cleanupByID[photo.id]?.photo == photo else { return }
        viewedCleanupPhotos[photo.id] = photo
    }

    func isCleanupMarked(_ id: String) -> Bool { cleanupMarks[id] != nil }

    func canMarkCleanup(_ photo: Photo) -> Bool {
        cleanupReady && viewedCleanupPhotos[photo.id] == photo && cleanupMarks[photo.id] == nil
    }

    func markCleanup(_ selection: Set<String>) {
        guard !deleting, !showQueue, !preparingReview, !showScreenshots else { return }
        var changed = false
        for id in selection {
            guard let photo = cleanupByID[id]?.photo, canMarkCleanup(photo) else { continue }
            cleanupMarks[id] = photo
            changed = true
        }
        if changed { saveCleanupMarks() }
    }

    func unmarkCleanup(_ photo: Photo) {
        guard !deleting, !showQueue, !preparingReview,
              cleanupMarks[photo.id] == photo else { return }
        cleanupMarks[photo.id] = nil
        saveCleanupMarks()
    }

    private func saveCleanupMarks() {
        guard persistenceEnabled else { return }
        do { try LocalStore.write(cleanupMarks, name: "cleanup-pending.json") }
        catch { errorMessage = "Your Cleanup selections couldn’t be saved: \(error.localizedDescription)" }
    }

    func recordDeletionSuccess(_ plan: [ProcessedGroup]) {
        let ids = Set(plan.map(\.id))
        let next = visibleGroups.drop(while: { $0.id != selectedID }).dropFirst().first { !ids.contains($0.id) }
        var manualIDs: Set<String> = []
        for var entry in plan {
            entry.deletedAt = .now
            history[entry.id] = entry
            if entry.manual == true {
                manualIDs.formUnion(entry.removals.map(\.id))
            } else {
                decisions[entry.id] = nil
            }
        }
        if !manualIDs.isEmpty {
            for id in manualIDs {
                cleanupMarks[id] = nil
                cleanupByID[id] = nil
                viewedCleanupPhotos[id] = nil
            }
            cleanupCatalog.removeAll { manualIDs.contains($0.id) }
            saveCleanupMarks()
        }
        groups.removeAll { ids.contains($0.id) }
        saveHistory()
        saveDecisions()
        if let selectedID, ids.contains(selectedID), filter != .history { select(next ?? visibleGroups.first) }
        else { ensureSelection() }
    }
}
