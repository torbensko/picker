import XCTest
@testable import Picker

final class ScanTests: XCTestCase {
    func stamp(_ id: String, time: Double, modified: Date? = nil, favorite: Bool = false) -> AssetStamp {
        AssetStamp(id: id, date: Date(timeIntervalSince1970: time), modified: modified,
                   width: 2000, height: 1000, favorite: favorite, live: false)
    }
    func testWindowDoesNotCloseUntilBeyondTenMinutes() {
        let first = Date(timeIntervalSince1970: 1000)
        XCTAssertFalse(ScanPlanner.isClosed(representative: first, next: first.addingTimeInterval(599)))
        XCTAssertFalse(ScanPlanner.isClosed(representative: first, next: first.addingTimeInterval(600)))
        XCTAssertTrue(ScanPlanner.isClosed(representative: first, next: first.addingTimeInterval(601)))
    }
    func testSessionsIncludeAllPotentiallyRelatedNeighborsAndHaveStableKeys() {
        let items = [stamp("c", time: 1200), stamp("a", time: 0), stamp("b", time: 600), stamp("d", time: 1801)]
        let sessions = ScanPlanner.sessions(items)
        XCTAssertEqual(sessions.map { $0.assets.map(\.id) }, [["a", "b", "c"], ["d"]])
        XCTAssertEqual(sessions[0].key, ScanPlanner.sessions(items.reversed())[0].key)
        XCTAssertEqual(sessions[0].key, sessions[0].key)
        let changed = ScanPlanner.sessions([stamp("a", time: 0), stamp("b", time: 600, modified: .now), stamp("c", time: 1200)])
        XCTAssertNotEqual(sessions[0].key, changed[0].key)
        let added = ScanPlanner.sessions(items + [stamp("new", time: 300)])
        XCTAssertNotEqual(sessions[0].key, added[0].key)
    }
    func testPhotoOrderingDoesNotInvalidateAnUnchangedDecision() {
        let photos = [stamp("a", time: 0).photo(score: 1), stamp("b", time: 0).photo(score: 0)]
        XCTAssertTrue(ReviewRules.unchanged(SimilarGroup(photos: photos), SimilarGroup(photos: photos.reversed())))
    }
    func testMetadataOnlyChangeReusesFeatureButImageEditDoesNot() {
        let original = stamp("a", time: 0)
        let record = AnalysisRecord(photo: original.photo(score: 1), feature: Data())
        XCTAssertTrue(stamp("a", time: 30, favorite: true).canReuseFeature(record))
        XCTAssertFalse(stamp("a", time: 0, modified: .now).canReuseFeature(record))
    }
    func testLegacyCacheDecodesAndNewSessionCacheRoundTrips() throws {
        let old = Data("{\"version\":1,\"records\":{},\"groups\":[]}".utf8)
        let legacy = try JSONDecoder().decode(SavedLibrary.self, from: old)
        XCTAssertNil(legacy.sessions)
        var cache = legacy
        cache.sessions = ["session": CachedSession(groups: [], unavailable: 3, count: 5)]
        let restored = try JSONDecoder().decode(SavedLibrary.self, from: JSONEncoder().encode(cache))
        XCTAssertEqual(restored.sessions?["session"]?.unavailable, 3)
        XCTAssertEqual(restored.sessions?["session"]?.count, 5)
    }
    @MainActor func testCompletedGroupsAreEditableDuringScanAndLaterResultsPreserveChoices() {
        let a = SimilarGroup(photos: [stamp("a", time: 0).photo(score: 1), stamp("b", time: 1).photo(score: 0)])
        let b = SimilarGroup(photos: [stamp("c", time: 1000).photo(score: 1), stamp("d", time: 1001).photo(score: 0)])
        let model = LibraryModel(persistenceEnabled: false)
        model.scanning = true
        model.applyScanUpdate(.prepared(previous: [a], ready: [a], progress: ScanProgress(total: 100)))
        XCTAssertTrue(model.canReview(a))
        model.select(a)
        model.chooseHighlighted()
        model.movePhoto(1)
        model.applyScanUpdate(.completedGroups([b]))
        XCTAssertEqual(model.decisions[a.id]?.keepers, ["a"])
        XCTAssertEqual(model.selectedID, a.id)
        XCTAssertEqual(model.highlightedID, "b")
        model.acceptCompletedGroups([a, b])
        XCTAssertEqual(model.decisions[a.id]?.keepers, ["a"])
        model.reset(a)
        XCTAssertNil(model.decisions[a.id])
        model.skip()
        XCTAssertTrue(model.decisions[a.id]?.skipped == true)
    }
    @MainActor func testRecheckingLibraryPreservesUnchangedQueueAndInvalidatesEditedGroup() {
        let a = SimilarGroup(photos: [stamp("a", time: 0).photo(score: 1), stamp("b", time: 1).photo(score: 0)])
        let changed = SimilarGroup(photos: [stamp("a", time: 0, modified: .now).photo(score: 1), stamp("b", time: 1).photo(score: 0)])
        let model = LibraryModel(persistenceEnabled: false)
        model.groups = [a]
        model.select(a)
        model.chooseHighlighted()
        model.scanning = true
        model.applyScanUpdate(.prepared(previous: [a], ready: [a], progress: ScanProgress(total: 2)))
        XCTAssertEqual(model.decisions[a.id]?.keepers, ["a"])
        model.applyScanUpdate(.prepared(previous: [a], ready: [], progress: ScanProgress(total: 2)))
        XCTAssertTrue(model.groups.isEmpty)
        model.applyScanUpdate(.completedGroups([changed]))
        XCTAssertNil(model.decisions[a.id])
        model.chooseHighlighted()
        model.acceptCompletedGroups([changed])
        XCTAssertFalse(model.queuedGroups.isEmpty)
    }
}
