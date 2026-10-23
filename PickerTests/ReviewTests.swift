import XCTest
@testable import Picker

final class ReviewTests: XCTestCase {
    func photo(_ id: String, score: Float = 0, modified: Date? = nil) -> Photo {
        Photo(id: id, date: Date(timeIntervalSince1970: 1000), modified: modified,
              width: 3000, height: 2000, favorite: false, live: false, score: score)
    }
    var group: SimilarGroup { SimilarGroup(photos: [photo("a"), photo("b", score: 0.8), photo("c")]) }

    func testNoDeletionWithoutAnExplicitValidKeeper() {
        XCTAssertTrue(ReviewRules.deletions(in: group, decision: nil).isEmpty)
        XCTAssertTrue(ReviewRules.deletions(in: group, decision: Decision()).isEmpty)
        XCTAssertTrue(ReviewRules.deletions(in: group, decision: Decision(keepers: ["missing"])).isEmpty)
        XCTAssertTrue(ReviewRules.deletions(in: group, decision: Decision(keepers: ["a", "missing"])).isEmpty)
    }
    func testMultipleKeepersAreExcludedFromDeletion() {
        XCTAssertEqual(ReviewRules.deletions(in: group, decision: Decision(keepers: ["a", "c"])).map(\.id), ["b"])
    }
    func testSkippingOrKeepingEverythingDeletesNothing() {
        XCTAssertTrue(ReviewRules.deletions(in: group, decision: Decision(keepers: ["a"], skipped: true)).isEmpty)
        XCTAssertTrue(ReviewRules.deletions(in: group, decision: Decision(keepers: ["a", "b", "c"])).isEmpty)
    }
    func testRecommendationDoesNotImplicitlyChooseKeeper() {
        XCTAssertEqual(group.suggestedID, "b")
        XCTAssertTrue(ReviewRules.deletions(in: group, decision: nil).isEmpty)
    }
    func testChangedMembershipInvalidatesDecisions() {
        let changed = SimilarGroup(photos: [photo("a"), photo("b", score: 0.8)])
        XCTAssertTrue(ReviewRules.reconciled([group.id: Decision(keepers: ["a"])], old: [group], new: [changed]).isEmpty)
    }
    func testEditedPhotoInvalidatesDecisionButUnchangedGroupPersists() {
        let decisions = [group.id: Decision(keepers: ["a"])]
        XCTAssertEqual(ReviewRules.reconciled(decisions, old: [group], new: [group]), decisions)
        let changed = SimilarGroup(photos: [photo("a", modified: .now), photo("b", score: 0.8), photo("c")])
        XCTAssertTrue(ReviewRules.reconciled(decisions, old: [group], new: [changed]).isEmpty)
    }
    func testDecisionsRoundTrip() throws {
        let decisions = [group.id: Decision(keepers: ["a", "c"])]
        XCTAssertEqual(try JSONDecoder().decode([String: Decision].self, from: JSONEncoder().encode(decisions)), decisions)
    }
    @MainActor func testHighlightRecommendationAndKeepersRemainIndependent() {
        let model = LibraryModel(persistenceEnabled: false)
        model.groups = [group]
        model.select(group)
        XCTAssertEqual(model.highlightedID, "b")
        model.highlightedID = "a"
        XCTAssertEqual(model.selectedGroup?.suggestedID, "b")
        XCTAssertTrue(model.queuedGroups.isEmpty)
        model.chooseHighlighted()
        model.movePhoto(1)
        XCTAssertEqual(model.highlightedID, "b")
        XCTAssertEqual(model.decisions[group.id]?.keepers, ["a"])
        model.chooseHighlighted()
        XCTAssertEqual(model.decisions[group.id]?.keepers, ["a", "b"])
        XCTAssertEqual(ReviewRules.deletions(in: group, decision: model.decisions[group.id]).map(\.id), ["c"])
        model.setKeeper(group.photos[0], in: group, keep: false)
        XCTAssertEqual(model.decisions[group.id]?.keepers, ["b"])
        model.reset(group)
        XCTAssertTrue(model.queuedGroups.isEmpty)
    }
    @MainActor func testPotentialRemovalsRemainIndependentOfQueueAndFilters() {
        let model = LibraryModel(persistenceEnabled: false)
        let second = SimilarGroup(photos: [photo("d"), photo("e")])
        model.groups = [group, second]
        model.total = 100
        XCTAssertEqual(model.potentialRemovalCount, 3)
        XCTAssertTrue(model.deletionPhotos.isEmpty)
        model.select(group)
        model.highlightedID = "a"
        model.chooseHighlighted()
        XCTAssertEqual(ReviewRules.deletions(in: group, decision: model.decisions[group.id]).map(\.id), ["b", "c"])
        model.movePhoto(1)
        model.chooseHighlighted()
        XCTAssertEqual(ReviewRules.deletions(in: group, decision: model.decisions[group.id]).map(\.id), ["c"])
        XCTAssertEqual(model.potentialRemovalCount, 3)
        model.select(second)
        model.skip()
        model.filter = .pending
        XCTAssertEqual(model.visibleGroups.count, 1)
        XCTAssertEqual(model.potentialRemovalCount, 3)
        XCTAssertEqual(model.total, 100)
        model.reset(group)
        XCTAssertTrue(model.deletionPhotos.isEmpty)
        XCTAssertEqual(model.potentialRemovalCount, 3)
        model.groups = []
        XCTAssertEqual(model.potentialRemovalCount, 0)
    }
    @MainActor func testOpeningGroupHighlightsSuggestionWithoutQueuingUntilConfirmed() {
        let model = LibraryModel(persistenceEnabled: false)
        let second = SimilarGroup(photos: [photo("d"), photo("e", score: 1)])
        model.groups = [group, second]
        model.select(group)
        XCTAssertEqual(model.highlightedID, "b")
        XCTAssertTrue(model.queuedGroups.isEmpty)
        model.chooseHighlighted()
        XCTAssertEqual(model.decisions[group.id]?.keepers, ["b"])
        XCTAssertEqual(ReviewRules.deletions(in: group, decision: model.decisions[group.id]).map(\.id), ["a", "c"])
        model.moveGroup(1)
        XCTAssertEqual(model.highlightedID, "e")
        XCTAssertNil(model.decisions[second.id])
        model.moveGroup(-1)
        XCTAssertEqual(model.highlightedID, "b")
        XCTAssertEqual(model.decisions[group.id]?.keepers, ["b"])
    }
    @MainActor func testTickCrossDecisionsAndReset() {
        let model = LibraryModel(persistenceEnabled: false)
        model.groups = [group]
        model.select(group)
        model.setKeeper(group.photos[0], in: group, keep: false)
        XCTAssertEqual(model.deletionPhotos.map(\.id), ["a"], "A cross immediately enters Pending")
        model.reset(group)
        model.setKeeper(group.photos[0], in: group, keep: true)
        XCTAssertEqual(ReviewRules.deletions(in: group, decision: model.decisions[group.id]).map(\.id), ["b", "c"])
        model.setKeeper(group.photos[0], in: group, keep: true)
        XCTAssertEqual(model.decisions[group.id]?.keepers, ["a"], "Tick is idempotent")
        model.setKeeper(group.photos[1], in: group, keep: true)
        XCTAssertEqual(ReviewRules.deletions(in: group, decision: model.decisions[group.id]).map(\.id), ["c"])
        model.setKeeper(group.photos[0], in: group, keep: false)
        XCTAssertEqual(ReviewRules.deletions(in: group, decision: model.decisions[group.id]).map(\.id), ["a", "c"])
        model.setKeeper(group.photos[1], in: group, keep: false)
        XCTAssertEqual(model.decisions[group.id]?.keepers, ["b"], "Last keeper must be retained until reset")
        model.reset(group)
        XCTAssertNil(model.decisions[group.id])
        XCTAssertTrue(model.queuedGroups.isEmpty)
        XCTAssertTrue(model.deletionPhotos.isEmpty)
        XCTAssertEqual(model.highlightedID, group.suggestedID, "Reset doesn't change the photo being viewed")
        model.skip()
        model.reset(group)
        XCTAssertNil(model.decisions[group.id])
    }
    @MainActor func testPreviewNavigationAndSkipping() {
        let model = LibraryModel(persistenceEnabled: false)
        let second = SimilarGroup(photos: [photo("d"), photo("e")])
        model.groups = [group, second]
        model.select(group)
        model.preview = true
        model.movePhoto(-1)
        XCTAssertEqual(model.highlightedID, "a")
        model.moveGroup(1)
        XCTAssertEqual(model.selectedID, second.id)
        XCTAssertEqual(model.highlightedID, second.suggestedID)
        XCTAssertTrue(model.preview)
        model.moveGroup(-1)
        model.skip()
        XCTAssertEqual(model.decisions[group.id]?.skipped, true)
        XCTAssertEqual(model.selectedID, second.id)
    }
}
