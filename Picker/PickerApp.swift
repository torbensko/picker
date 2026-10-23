import SwiftUI

@main
struct PickerApp: App {
    @State private var library: LibraryModel
    @StateObject private var updates: UpdateController

    init() {
        let library = LibraryModel()
        _library = State(initialValue: library)
        _updates = StateObject(wrappedValue: UpdateController(library: library))
    }

    var body: some Scene {
        Window("Picker", id: "main") {
            ContentView(model: library)
                .frame(minWidth: 960, minHeight: 620)
                .onChange(of: library.blocksUpdateRelaunch) { updates.resumeIfIdle() }
        }
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            UpdateCommands(updates: updates)
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Review") {
                Group {
                Button("Previous Photo") { library.movePhoto(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
                Button("Next Photo") { library.movePhoto(1) }.keyboardShortcut(.rightArrow, modifiers: [])
                Divider()
                Button("Previous Group") { library.moveGroup(-1) }.keyboardShortcut(.upArrow, modifiers: .command)
                Button("Next Group") { library.moveGroup(1) }.keyboardShortcut(.downArrow, modifiers: .command)
                Divider()
                Button("Keep Highlighted Photo") { library.chooseHighlighted() }.keyboardShortcut(.return, modifiers: [])
                Button("Apply Current Group") { library.applyCurrentGroup() }.keyboardShortcut(.return, modifiers: .command)
                    .disabled(library.selectedGroup.map { !library.canApply($0) } ?? true)
                Button(library.preview ? "Show Thumbnails" : "Hide Thumbnails") { library.preview.toggle() }.keyboardShortcut(.space, modifiers: [])
                }.disabled(library.showScreenshots || library.showQueue || library.deleting || library.preparingReview || library.selectedGroup == nil)
            }
        }
    }
}
