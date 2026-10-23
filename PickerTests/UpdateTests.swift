import XCTest
@testable import Picker

final class UpdateTests: XCTestCase {
    func testOnlyConfiguredReleaseCanUpdate() {
        let key = Data(repeating: 1, count: 32).base64EncodedString()
        func allowed(_ channel: String? = "Release", _ feed: String? = UpdatePolicy.feed, _ publicKey: String? = nil,
                     _ identifier: String? = "com.local.Picker") -> Bool {
            UpdatePolicy.permitsUpdates(identifier: identifier, channel: channel, feed: feed, publicKey: publicKey ?? key)
        }
        XCTAssertTrue(allowed())
        XCTAssertFalse(allowed("Development"))
        XCTAssertFalse(allowed(nil))
        XCTAssertFalse(allowed("Release", "http://example.com/feed.xml"))
        XCTAssertFalse(allowed("Release", UpdatePolicy.feed, "$(SPARKLE_PUBLIC_KEY)"))
        XCTAssertFalse(allowed("Release", UpdatePolicy.feed, key, "com.local.Picker.Test"))
    }

    @MainActor func testRelaunchWaitsForLibraryOperationsAndResumesOnce() {
        let library = LibraryModel(persistenceEnabled: false)
        let gate = UpdateRelaunchGate(isBusy: { library.blocksUpdateRelaunch })
        var installs = 0
        let busyStates: [ReferenceWritableKeyPath<LibraryModel, Bool>] = [
            \.scanning, \.preparingReview, \.deleting, \.showQueue, \.showScreenshots
        ]
        for state in busyStates {
            library[keyPath: state] = true
            let before = installs
            XCTAssertTrue(gate.postponeIfBusy { installs += 1 })
            gate.resumeIfIdle()
            XCTAssertEqual(installs, before)
            library[keyPath: state] = false
            gate.resumeIfIdle()
            gate.resumeIfIdle()
            XCTAssertEqual(installs, before + 1)
        }
        XCTAssertFalse(gate.postponeIfBusy { installs += 1 })
        gate.resumeIfIdle()
        XCTAssertEqual(installs, busyStates.count)
    }
}
