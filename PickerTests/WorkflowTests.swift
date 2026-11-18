import XCTest
@testable import Picker

final class WorkflowTests: XCTestCase {
    func group(_ prefix: String, count: Int = 3) -> SimilarGroup {
        SimilarGroup(photos: (0..<count).map {
            Photo(id: "\(prefix)\($0)", date: Date(timeIntervalSince1970: 1000 + Double($0)), modified: nil,
                  width: 1000, height: 1000, favorite: false, live: false, score: $0 == 0 ? 1 : 0)
        })
    }
    @MainActor func testApplyConfirmsOnlyCurrentGroupAndLeavesOtherPendingChoices() {
        let first = group("a"), second = group("b")
        let model = LibraryModel(persistenceEnabled: false)
        model.groups = [first, second]
        model.select(second)
        model.chooseHighlighted()
        model.select(first)
        model.chooseHighlighted()
        XCTAssertEqual(model.deletionPhotos.map(\.id), ["a1", "a2", "b1", "b2"])
        XCTAssertEqual(model.sidebarCount(.all), 2)
        model.applyCurrentGroup()
        XCTAssertTrue(model.showQueue)
        XCTAssertEqual(model.deletionScope, .currentGroup)
        XCTAssertEqual(model.plannedPhotos.map(\.id), ["a1", "a2"])
        XCTAssertEqual(model.deletionPlan.count, 1)
        XCTAssertTrue(model.history.isEmpty, "Opening a confirmation does not process the group")
        XCTAssertEqual(model.selectedID, first.id)
        // Simulate successful completion; never invoke PhotoKit deletion in a test.
        model.recordDeletionSuccess(model.deletionPlan)
        XCTAssertEqual(model.deletionPhotos.map(\.id), ["b1", "b2"])
        XCTAssertEqual(model.sidebarCount(.all), 1)
        XCTAssertEqual(model.sidebarCount(.history), 1)
        XCTAssertEqual(model.selectedID, second.id)
    }
    @MainActor func testCancelLeavesCrossesPendingAndGroupUnprocessed() {
        let group = group("a")
        let model = LibraryModel(persistenceEnabled: false)
        model.groups = [group]
        model.select(group)
        model.chooseHighlighted()
        model.applyCurrentGroup()
        model.showQueue = false
        model.queueClosed()
        XCTAssertTrue(model.deletionPlan.isEmpty)
        XCTAssertTrue(model.history.isEmpty)
        XCTAssertEqual(model.deletionPhotos.map(\.id), ["a1", "a2"])
        XCTAssertEqual(model.selectedID, group.id)
        XCTAssertTrue(model.canApply(group))
        model.reset(group)
        XCTAssertTrue(model.deletionPhotos.isEmpty)
        XCTAssertEqual(model.sidebarCount(.all), 1)
    }
    @MainActor func testCrossFromNeutralImmediatelyEntersPendingAndTickRestores() {
        let group = group("a")
        let model = LibraryModel(persistenceEnabled: false)
        model.groups = [group]
        model.select(group)
        model.setKeeper(group.photos[1], in: group, keep: false)
        XCTAssertEqual(model.deletionPhotos.map(\.id), ["a1"])
        XCTAssertEqual(model.decisions[group.id]?.keepers, [])
        model.keepPending(group.photos[1], group: group)
        XCTAssertTrue(model.deletionPhotos.isEmpty)
        XCTAssertEqual(model.decisions[group.id]?.keepers, ["a1"])
    }
    @MainActor func testPendingDeleteIncludesAllCrossesWithoutApply() {
        let first = group("a"), second = group("b"), untouched = group("c")
        let model = LibraryModel(persistenceEnabled: false)
        model.groups = [first, second, untouched]
        model.select(first)
        model.chooseHighlighted()
        model.setKeeper(second.photos[1], in: second, keep: false)
        model.filter = .pending
        model.openQueue()
        XCTAssertTrue(model.showQueue)
        XCTAssertEqual(model.deletionScope, .pending)
        XCTAssertEqual(model.plannedPhotos.map(\.id), ["a1", "a2", "b1"])
        XCTAssertEqual(model.deletionPlan.count, 2)
        XCTAssertTrue(model.isDeletionPlanCurrent(model.deletionPlan))
        XCTAssertTrue(model.history.isEmpty)
        // A frozen plan cannot silently follow later choices.
        model.decisions[first.id] = Decision(keepers: ["a0", "a1"])
        XCTAssertFalse(model.isDeletionPlanCurrent(model.deletionPlan))
        XCTAssertEqual(model.plannedPhotos.map(\.id), ["a1", "a2", "b1"])
    }
    @MainActor func testKeepAllIsProcessedWithoutPendingDeletions() {
        let group = group("a")
        let model = LibraryModel(persistenceEnabled: false)
        model.groups = [group]
        model.select(group)
        for photo in group.photos { model.setKeeper(photo, in: group, keep: true) }
        model.applyCurrentGroup()
        XCTAssertEqual(model.sidebarCount(.all), 0)
        XCTAssertEqual(model.sidebarCount(.history), 1)
        XCTAssertTrue(model.deletionPhotos.isEmpty)
        XCTAssertFalse(model.showQueue)
        model.filter = .history
        model.select(group)
        model.setKeeper(group.photos[1], in: group, keep: false)
        XCTAssertEqual(model.filter, .all)
        XCTAssertEqual(model.deletionPhotos.map(\.id), ["a1"])
        XCTAssertTrue(model.history.isEmpty)
    }
    @MainActor func testPendingKeepRestoresPhotoAndHistorySurvivesSuccessfulDeletion() throws {
        let group = group("a")
        let model = LibraryModel(persistenceEnabled: false)
        model.groups = [group]
        model.select(group)
        model.chooseHighlighted()
        model.filter = .pending
        model.keepPending(group.photos[1], group: group)
        XCTAssertEqual(model.deletionPhotos.map(\.id), ["a2"])
        model.reviewPendingGroup(group)
        XCTAssertEqual(model.filter, .all)
        XCTAssertEqual(model.selectedID, group.id)
        model.applyCurrentGroup()
        let plan = try XCTUnwrap(model.deletionPlan.first)
        model.recordDeletionSuccess([plan])
        XCTAssertTrue(model.groups.isEmpty)
        XCTAssertNotNil(model.history[group.id]?.deletedAt)
        XCTAssertEqual(model.sidebarCount(.history), 1)
        XCTAssertTrue(model.deletionPhotos.isEmpty)
        let restored = try JSONDecoder().decode([String: ProcessedGroup].self, from: JSONEncoder().encode(model.history))
        XCTAssertEqual(restored[group.id]?.decision.keepers, ["a0", "a1"])
        XCTAssertNotNil(restored[group.id]?.deletedAt)
    }
    @MainActor func testBackgroundEditInvalidatesPendingChoice() {
        let group = group("a")
        let model = LibraryModel(persistenceEnabled: false)
        model.groups = [group]
        model.select(group)
        model.chooseHighlighted()
        let changed = SimilarGroup(photos: group.photos.map {
            Photo(id: $0.id, date: $0.date, modified: .now, width: $0.width, height: $0.height, favorite: false, live: false, score: $0.score)
        })
        model.scanning = true
        model.applyScanUpdate(.prepared(previous: [group], ready: [], progress: ScanProgress(total: 3)))
        model.acceptCompletedGroups([changed])
        XCTAssertTrue(model.deletionPhotos.isEmpty)
        XCTAssertNil(model.decisions[group.id])
        XCTAssertTrue(model.history.isEmpty)
        XCTAssertEqual(model.sidebarCount(.all), 1)
    }
    @MainActor func testLegacyAppliedChoicesMigrateToPendingWithoutBeingProcessed() {
        let group = group("a")
        let model = LibraryModel(persistenceEnabled: false)
        model.groups = [group]
        model.history[group.id] = ProcessedGroup(group: group, decision: Decision(keepers: ["a0"]), processedAt: .now)
        model.restoreReviewState()
        XCTAssertTrue(model.history.isEmpty)
        XCTAssertEqual(model.deletionPhotos.map(\.id), ["a1", "a2"])
        XCTAssertEqual(model.sidebarCount(.all), 1)
    }
    @MainActor func testMultipleKeepersDoNotReappearAfterDeletionAndRescan() {
        let original = group("a")
        let model = LibraryModel(persistenceEnabled: false)
        model.groups = [original]
        model.select(original)
        model.chooseHighlighted()
        model.setKeeper(original.photos[1], in: original, keep: true)
        model.applyCurrentGroup()
        model.recordDeletionSuccess(model.deletionPlan)
        model.showQueue = false
        let survivors = SimilarGroup(photos: Array(original.photos.prefix(2)))
        model.applyScanUpdate(.prepared(previous: [original], ready: [survivors], progress: ScanProgress(total: 2)))
        XCTAssertEqual(model.sidebarCount(.all), 0)
        XCTAssertEqual(model.sidebarCount(.history), 1)
        XCTAssertTrue(model.deletionPhotos.isEmpty)
        // A newly discovered similar photo makes the group worth reviewing again.
        let extended = SimilarGroup(photos: survivors.photos + [group("new").photos[0]])
        XCTAssertTrue(model.matches(extended, filter: .all))
        // A changed survivor also needs a fresh review.
        let changed = SimilarGroup(photos: survivors.photos.map {
            Photo(id: $0.id, date: $0.date, modified: .now, width: $0.width, height: $0.height, favorite: false, live: false, score: $0.score)
        })
        XCTAssertTrue(model.matches(changed, filter: .all))
    }
    @MainActor func testSkipClearsPendingAndResetReopensGroup() {
        let group = group("a")
        let model = LibraryModel(persistenceEnabled: false)
        model.groups = [group]
        model.select(group)
        model.chooseHighlighted()
        model.skip()
        XCTAssertTrue(model.deletionPhotos.isEmpty)
        XCTAssertEqual(model.sidebarCount(.history), 1)
        model.filter = .history
        model.select(group)
        model.reset(group)
        XCTAssertEqual(model.filter, .all)
        XCTAssertTrue(model.history.isEmpty)
        XCTAssertNil(model.decisions[group.id])
        XCTAssertEqual(model.sidebarCount(.all), 1)
    }


    @MainActor func testRouterBothWaysAndConfirmedDeletion() async throws {
        let router = group("router", count: 2)
        for markEntireGroup in [false, true] {
            var deleted: Set<String> = []
            let model = LibraryModel(persistenceEnabled: false) { snapshots, ids in
                XCTAssertEqual(snapshots, router.photos)
                deleted = ids
            }
            model.groups = [router]
            model.select(router)
            if markEntireGroup {
                model.markEntireGroup(router)
            } else {
                model.setKeeper(router.photos[0], in: router, keep: false)
                XCTAssertEqual(model.deletionPhotos, [router.photos[0]])
                model.setKeeper(router.photos[1], in: router, keep: false)
            }
            XCTAssertEqual(model.decisions[router.id]?.keepers, [])
            XCTAssertEqual(model.deletionPhotos, router.photos)
            model.applyCurrentGroup()
            XCTAssertTrue(deleted.isEmpty)
            XCTAssertEqual(model.plannedPhotos, router.photos)
            let task = try XCTUnwrap(model.deleteConfirmedPlan())
            await task.value
            XCTAssertEqual(deleted, ["router0", "router1"])
            XCTAssertTrue(model.deletionPhotos.isEmpty)
            let persistedHistory = try JSONEncoder().encode(model.history)
            let restored = try JSONDecoder().decode([String: ProcessedGroup].self, from: persistedHistory)
            XCTAssertEqual(restored[router.id]?.deletionSummary, "0 kept · 2 deleted")
            XCTAssertNotNil(restored[router.id]?.deletedAt)
            model.applyScanUpdate(.prepared(previous: [router], ready: [], progress: ScanProgress()))
            XCTAssertEqual(model.sidebarCount(.all), 0)
            XCTAssertEqual(model.sidebarCount(.pending), 0)
            XCTAssertEqual(model.sidebarCount(.history), 1)
        }
    }

    @MainActor func testMarkEntireGroupCanRestoreSeveralOrReset() {
        let group = group("a", count: 7)
        let model = LibraryModel(persistenceEnabled: false)
        model.groups = [group]
        model.select(group)
        model.chooseHighlighted()
        model.setKeeper(group.photos[1], in: group, keep: true)
        model.setKeeper(group.photos[2], in: group, keep: true)
        XCTAssertEqual(model.decisions[group.id]?.keepers.count, 3)
        XCTAssertEqual(model.deletionPhotos.count, 4)

        model.markEntireGroup(group)
        model.keepPending(group.photos[1], group: group)
        model.setKeeper(group.photos[2], in: group, keep: true)
        XCTAssertEqual(model.decisions[group.id]?.keepers, ["a1", "a2"])
        XCTAssertEqual(model.deletionPhotos.count, 5)
        model.reset(group)
        XCTAssertNil(model.decisions[group.id])
        XCTAssertTrue(model.deletionPhotos.isEmpty)
    }

    @MainActor func testCancelledAllDiscardKeepsPending() {
        let group = group("a")
        let model = LibraryModel(persistenceEnabled: false) { _, _ in XCTFail("Unexpected deletion") }
        model.groups = [group]
        model.select(group)
        model.markEntireGroup(group)
        model.applyCurrentGroup()
        model.showQueue = false
        model.queueClosed()
        XCTAssertNil(model.deleteConfirmedPlan())
        XCTAssertEqual(model.deletionPhotos, group.photos)
        XCTAssertTrue(model.history.isEmpty)
    }

    @MainActor func testDeletionErrorsPreservePendingAndPassEveryGroupMemberForValidation() async throws {
        enum PhotosFailure: Error { case permissions, missingPhoto, cancelled }
        for failure in [PhotosFailure.permissions, .missingPhoto, .cancelled] {
            let group = group("a")
            let model = LibraryModel(persistenceEnabled: false) { snapshots, ids in
                XCTAssertEqual(snapshots, group.photos, "The adapter checks keepers and neutral members too")
                XCTAssertEqual(ids, ["a1"])
                throw failure
            }
            model.groups = [group]
            model.select(group)
            model.setKeeper(group.photos[1], in: group, keep: false)
            model.applyCurrentGroup()
            let task = try XCTUnwrap(model.deleteConfirmedPlan())
            await task.value
            XCTAssertNotNil(model.errorMessage)
            XCTAssertEqual(model.deletionPhotos, [group.photos[1]])
            XCTAssertTrue(model.history.isEmpty)
        }
    }

    @MainActor func testChangedGroupStopsConfirmedDeletionBeforePhotoKit() async throws {
        let group = group("a")
        let model = LibraryModel(persistenceEnabled: false) { _, _ in XCTFail("Stale plan reached PhotoKit") }
        model.groups = [group]
        model.select(group)
        model.markEntireGroup(group)
        model.applyCurrentGroup()
        model.groups = [SimilarGroup(photos: Array(group.photos.dropLast()))]
        let task = try XCTUnwrap(model.deleteConfirmedPlan())
        await task.value
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.history.isEmpty)
    }

    @MainActor func testMixedPendingBatchKeepsAnIndependentManualHistoryEntry() async throws {
        let allDiscarded = group("a", count: 2)
        let partial = group("b")
        let manual = group("c")
        let model = LibraryModel(persistenceEnabled: false) { snapshots, ids in
            XCTAssertEqual(Set(snapshots), Set(allDiscarded.photos + partial.photos + [manual.photos[0]]))
            XCTAssertEqual(ids, ["a0", "a1", "b1", "b2", "c0"])
        }
        model.groups = [allDiscarded, partial]
        model.markEntireGroup(allDiscarded)
        model.select(partial)
        model.chooseHighlighted()
        model.updateCleanupCatalog((manual.photos + partial.photos).map { CleanupPhoto(photo: $0, screenshot: true) })
        XCTAssertEqual(model.cleanupCatalog.map(\.id), ["c0", "c1", "c2"])
        model.noteCleanupPreview(manual.photos[0])
        model.noteCleanupPreview(manual.photos[2])
        model.markCleanup(["c0", "c1", "c2"])
        XCTAssertEqual(model.pendingCleanup.map(\.id), ["c2", "c0"], "Unpreviewed photos cannot be marked")
        model.unmarkCleanup(manual.photos[2])
        model.openQueue()
        XCTAssertEqual(model.plannedPhotos.count, 5)
        let task = try XCTUnwrap(model.deleteConfirmedPlan())
        await task.value
        XCTAssertTrue(model.deletionPhotos.isEmpty)
        XCTAssertEqual(model.cleanupCatalog.map(\.id), ["c1", "c2"])
        let restored = try JSONDecoder().decode([String: ProcessedGroup].self, from: JSONEncoder().encode(model.history))
        XCTAssertEqual(restored.values.first { $0.manual == true }?.deletionSummary, "1 deleted")
        XCTAssertEqual(restored[allDiscarded.id]?.deletionSummary, "0 kept · 2 deleted")
        XCTAssertEqual(restored[partial.id]?.deletionSummary, "1 kept · 2 deleted")
    }

    @MainActor func testCleanupReconcilesEditedAndNewlyGroupedPhotos() {
        let group = group("a")
        let photos = group.photos.map { CleanupPhoto(photo: $0, screenshot: false) }
        let model = LibraryModel(persistenceEnabled: false)
        model.updateCleanupCatalog(photos)
        group.photos.forEach(model.noteCleanupPreview)
        model.markCleanup(Set(photos.map(\.id)))
        let changed = Photo(id: "a0", date: group.photos[0].date, modified: .now, width: 1000, height: 1000,
                            favorite: false, live: false, score: 0)
        model.groups = [SimilarGroup(photos: Array(group.photos.dropFirst()))]
        model.updateCleanupCatalog([CleanupPhoto(photo: changed, screenshot: false)] + photos.dropFirst())
        XCTAssertTrue(model.pendingCleanup.isEmpty)
        XCTAssertFalse(model.canMarkCleanup(changed))
        XCTAssertNotNil(model.cleanupNotice)
    }
}
