import SwiftUI
import AppKit

/// Keep review keys consistent even when a list or a button owns keyboard focus.
struct ReviewKeyboard: NSViewRepresentable {
    let model: LibraryModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(view: view)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.remove() }

    @MainActor final class Coordinator {
        let model: LibraryModel
        var monitor: Any?
        init(model: LibraryModel) { self.model = model }
        func install(view: NSView) {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak view] event in
                guard let self, let window = view?.window, event.window === window,
                      window.attachedSheet == nil, self.model.hasAccess,
                      !self.model.showQueue, !self.model.showScreenshots, !self.model.deleting, !self.model.preparingReview, self.model.selectedGroup != nil,
                      !(window.firstResponder is NSTextView) else { return event }
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
                if flags == .command {
                    switch event.keyCode {
                    case 125: self.model.moveGroup(1)
                    case 126: self.model.moveGroup(-1)
                    case 36, 76: self.model.applyCurrentGroup()
                    default: return event
                    }
                } else if flags.isEmpty {
                    switch event.keyCode {
                    case 123: self.model.movePhoto(-1)
                    case 124: self.model.movePhoto(1)
                    case 49: self.model.preview.toggle()
                    case 36, 76: self.model.chooseHighlighted()
                    case 53 where self.model.preview: self.model.preview = false
                    default: return event
                    }
                } else { return event }
                return nil
            }
        }
        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
