import AppKit
import Photos
import SwiftUI

enum ReviewFilter: String, CaseIterable, Identifiable {
    case all = "Similar Photos", pending = "Pending", history = "History"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .all: "square.stack"
        case .pending: "tray.full"
        case .history: "clock.arrow.circlepath"
        }
    }
}

enum DeletionScope { case currentGroup, pending }

@MainActor @Observable
final class LibraryModel: NSObject, PHPhotoLibraryChangeObserver {
    var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    var groups: [SimilarGroup] = []
    var decisions: [String: Decision] = [:]
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

    init(persistenceEnabled: Bool = true) {
        self.persistenceEnabled = persistenceEnabled
        super.init()
    }

    // A screenshot sheet may own an export or deletion task. Wait for it to close,
    // and for scan checkpoints and PhotoKit changes to finish, before restarting.
    var blocksUpdateRelaunch: Bool { scanning || preparingReview || deleting || showQueue || showScreenshots }

    var hasAccess: Bool { authorization == .authorized || authorization == .limited }
    var selectedGroup: SimilarGroup? {
        if filter == .pending { return nil }
        if filter == .history { return history.values.first { $0.id == selectedID }?.group }
        return groups.first { $0.id == selectedID }
    }
    var queuedGroups: [SimilarGroup] { groups.filter { matches($0, filter: .pending) } }
    var potentialRemovalCount: Int { groups.reduce(0) { $0 + max($1.photos.count - 1, 0) } }
    var deletionPhotos: [Photo] { queuedGroups.flatMap { ReviewRules.deletions(in: $0, decision: decisions[$0.id]) } }
    var visibleGroups: [SimilarGroup] {
        if filter == .history { return history.values.sorted { $0.processedAt > $1.processedAt }.map(\.group) }
        return groups.filter { matches($0, filter: filter) }
    }
    var highlighted: Photo? { selectedGroup?.photos.first { $0.id == highlightedID } }
    var plannedPhotos: [Photo] { deletionPlan.flatMap { ReviewRules.deletions(in: $0.group, decision: $0.decision) } }

    func matches(_ group: SimilarGroup, filter: ReviewFilter) -> Bool {
        switch filter {
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
        for entry in history.values.filter({ $0.deletedAt != nil }).sorted(by: { $0.processedAt < $1.processedAt }) {
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
        case .all: return groups.filter { matches($0, filter: .all) }.count
        case .pending: return deletionPhotos.count
        case .history: return history.count
        }
    }
    func canApply(_ group: SimilarGroup) -> Bool {
        guard canReview(group), let decision = decisions[group.id], !decision.keepers.isEmpty, !decision.skipped,
              decision.keepers.isSubset(of: Set(group.photos.map(\.id))) else { return false }
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
        for (id, entry) in history where entry.deletedAt == nil && !entry.decision.skipped
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
            restoreReviewState()
            refresh()
        }
    }
    func connect() async {
        authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        start()
    }
    func refresh(retryUnavailable: Bool = false) {
        guard hasAccess, !scanning, !deleting, !showQueue, !showScreenshots, !preparingReview else { return }
        scanning = true
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
        !deleting && !showQueue && !preparingReview && history[group.id]?.deletedAt == nil
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
        if selectedGroup == nil { select(visibleGroups.first) }
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
        let plan = queuedGroups.compactMap { group in
            decisions[group.id].map { ProcessedGroup(group: group, decision: $0, processedAt: .now) }
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
        let list = visibleGroups
        guard !list.isEmpty else { return }
        let index = list.firstIndex { $0.id == selectedID } ?? 0
        select(list[min(max(index + delta, 0), list.count - 1)])
    }
    func chooseHighlighted() {
        guard let group = selectedGroup, let highlightedID, canReview(group) else { return }
        var decision = decisions[group.id] ?? Decision()
        decision.skipped = false
        decision.keepers.insert(highlightedID)
        updateDecision(decision, in: group)
    }
    func setKeeper(_ photo: Photo, in group: SimilarGroup, keep: Bool) {
        guard canReview(group), group.photos.contains(where: { $0.id == photo.id }) else { return }
        var decision = decisions[group.id] ?? Decision()
        if keep {
            decision.skipped = false
            decision.keepers.insert(photo.id)
        } else {
            // Crossing a neutral photo explicitly keeps its alternatives.
            if decision.skipped || decision.keepers.isEmpty {
                decision = Decision(keepers: Set(group.photos.map(\.id)))
            }
            // A group must retain a keeper. Reset is the explicit route back to neutral.
            guard !decision.skipped, !decision.keepers.isEmpty,
                  !decision.keepers.contains(photo.id) || decision.keepers.count > 1 else { return }
            decision.keepers.remove(photo.id)
        }
        updateDecision(decision, in: group)
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
    func deleteConfirmedPlan() {
        guard !deleting, !scanning, !deletionPlan.isEmpty else { return }
        deleting = true
        let plan = deletionPlan
        Task { await deletePlannedPhotos(plan) }
    }
    private func deletePlannedPhotos(_ plan: [ProcessedGroup]) async {
        let photos = plan.flatMap { $0.group.photos }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: photos.map(\.id), options: nil)
        var current: [String: PHAsset] = [:]
        assets.enumerateObjects { asset, _, _ in current[asset.localIdentifier] = asset }
        guard isDeletionPlanCurrent(plan),
              photos.allSatisfy({ photo in
                  guard let asset = current[photo.id] else { return false }
                  return asset.modificationDate == photo.modified && asset.isFavorite == photo.favorite
                      && asset.pixelWidth == photo.width && asset.pixelHeight == photo.height
              }) else {
            errorMessage = "Your library or choices changed. Nothing was deleted. Check the library and review Pending again."
            deleting = false
            showQueue = false
            needsRefresh = true
            resumeRefreshIfNeeded()
            return
        }
        let ids = Set(plan.flatMap { ReviewRules.deletions(in: $0.group, decision: $0.decision).map(\.id) })
        let keepers = Set(plan.flatMap { Array($0.decision.keepers) })
        guard !ids.isEmpty, ids.isDisjoint(with: keepers) else {
            errorMessage = "These choices no longer identify a valid deletion. Review the group again."
            deleting = false
            showQueue = false
            queueClosed()
            return
        }
        let removals = ids.compactMap { current[$0] }
        do {
            try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(removals as NSArray) }
            recordDeletionSuccess(plan)
            total = max(total - ids.count, 0)
            status = "Moved \(ids.count.formatted()) photos to Recently Deleted."
        } catch { errorMessage = "Photos weren’t deleted. Your pending list is saved. \(error.localizedDescription)" }
        deleting = false
        showQueue = false
        deletionPlan = []
        needsRefresh = true
        resumeRefreshIfNeeded()
    }
    func recordDeletionSuccess(_ plan: [ProcessedGroup]) {
        let ids = Set(plan.map(\.id))
        let next = visibleGroups.drop(while: { $0.id != selectedID }).dropFirst().first { !ids.contains($0.id) }
        for var entry in plan {
            entry.deletedAt = .now
            history[entry.id] = entry
            decisions[entry.id] = nil
        }
        groups.removeAll { ids.contains($0.id) }
        saveHistory()
        saveDecisions()
        if let selectedID, ids.contains(selectedID), filter != .history { select(next ?? visibleGroups.first) }
        else { ensureSelection() }
    }
}
