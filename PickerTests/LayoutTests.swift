import XCTest
import SwiftUI
import AppKit
@testable import Picker

final class LayoutTests: XCTestCase {
    @MainActor func testReviewFitsSmallWindowDuringScan() throws {
        let model = LibraryModel(persistenceEnabled: false)
        model.authorization = .authorized
        let photos = (0..<5).map { index in
            Photo(id: "layout-fixture-\(index)", date: Date(timeIntervalSince1970: 1000 + Double(index)), modified: nil,
                  width: 3000, height: 2000, favorite: false, live: false, score: index == 2 ? 1 : 0)
        }
        let group = SimilarGroup(photos: photos)
        model.scanning = true
        model.applyScanUpdate(.prepared(previous: [], ready: [group], progress: ScanProgress(checked: 300, total: 30000, cached: 280, analyzed: 20)))
        model.chooseHighlighted()
        let host = NSHostingView(rootView: ContentView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 620), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 960, height: 620)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(host.fittingSize.height, 620, "Review must fit without clipping decision controls")
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Picker-layout-check.png")
            try bitmap.representation(using: .png, properties: [:])?.write(to: url)
            print("Layout preview: \(url.path)")
        }
        window.orderOut(nil)
    }
}
