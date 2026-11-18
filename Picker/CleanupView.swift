import AppKit
import SwiftUI

struct CleanupView: View {
    @Bindable var model: LibraryModel
    @State private var screenshotsOnly = false
    @State private var selection: Set<String> = []
    @State private var anchor: String?
    @State private var preview: CleanupPhoto?

    private var visiblePhotos: [CleanupPhoto] {
        screenshotsOnly ? model.cleanupCatalog.filter(\.screenshot) : model.cleanupCatalog
    }

    var body: some View {
        VStack(spacing: 0) {
            if let notice = model.cleanupNotice {
                HStack {
                    Text(notice)
                    Spacer()
                    Button("Dismiss") { model.cleanupNotice = nil }
                }
                .font(.callout)
                .padding(12)
                Divider()
            }
            if !model.cleanupReady {
                ContentUnavailableView("Waiting for Library Scan", systemImage: "photo.on.rectangle",
                    description: Text("Finish the scan to find photos outside similar groups."))
            } else if visiblePhotos.isEmpty {
                ContentUnavailableView(screenshotsOnly ? "No Ungrouped Screenshots" : "No Ungrouped Photos",
                                       systemImage: "photo.on.rectangle")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 156), spacing: 16)], spacing: 16) {
                        ForEach(visiblePhotos) { item in
                            card(item)
                        }
                    }.padding(20)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Cleanup").font(.headline)
            }.sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .secondaryAction) {
                Toggle("Screenshots Only", isOn: $screenshotsOnly)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Mark \(selection.count.formatted()) Selected") {
                    model.markCleanup(selection)
                    clearSelection()
                }
                .disabled(selection.isEmpty || !model.cleanupReady)
                .help("Add the selected photos to Pending")
            }
        }
        .onChange(of: screenshotsOnly) { clearSelection() }
        .onChange(of: model.cleanupReady) { clearSelection() }
        .disabled(model.deleting || model.preparingReview || model.showQueue)
        .sheet(item: $preview) { item in
            VStack(alignment: .leading, spacing: 12) {
                PhotoView(photo: item.photo, large: true, onReadable: model.noteCleanupPreview)
                HStack {
                    Text(item.photo.date.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Done", role: .cancel) { preview = nil }
                    Button("Select Photo") {
                        selection.insert(item.id)
                        anchor = item.id
                        preview = nil
                    }
                    .disabled(!model.canMarkCleanup(item.photo))
                }
            }
            .padding(16)
            .frame(minWidth: 560, idealWidth: 780, minHeight: 380, idealHeight: 560)
        }
    }

    private func card(_ item: CleanupPhoto) -> some View {
        let selected = selection.contains(item.id)
        let marked = model.isCleanupMarked(item.id)
        return VStack(alignment: .leading, spacing: 6) {
            Button { preview = item } label: {
                PhotoView(photo: item.photo, onReadable: model.noteCleanupPreview)
                    .frame(height: 125)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3)
                    }
            }
            .buttonStyle(.plain)
            .help("Preview photo")
            HStack {
                if item.photo.favorite {
                    Image(systemName: "heart.fill").foregroundStyle(.pink).accessibilityLabel("Favorite")
                }
                Text(item.photo.date.formatted(date: .abbreviated, time: .omitted)).lineLimit(1)
                Spacer(minLength: 0)
                if marked {
                    Image(systemName: "tray.full").help("In Pending").accessibilityLabel("In Pending")
                } else {
                    Button {
                        toggleSelection(item, range: NSEvent.modifierFlags.contains(.shift))
                    } label: {
                        Image(systemName: selected ? "checkmark.square.fill" : "square")
                            .imageScale(.large)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!model.canMarkCleanup(item.photo))
                    .accessibilityLabel(selected ? "Deselect photo" : "Select photo")
                    .help("Select photo. Hold Shift to select a range. Open the preview if this photo is in iCloud.")
                }
            }
            .font(.caption)
        }
    }

    private func toggleSelection(_ item: CleanupPhoto, range: Bool) {
        if range, let anchor,
           let start = visiblePhotos.firstIndex(where: { $0.id == anchor }),
           let end = visiblePhotos.firstIndex(where: { $0.id == item.id }) {
            let photos = visiblePhotos[min(start, end)...max(start, end)]
            selection.formUnion(photos.filter { model.canMarkCleanup($0.photo) }.map(\.id))
            return
        }
        if selection.remove(item.id) == nil { selection.insert(item.id) }
        anchor = item.id
    }

    private func clearSelection() {
        selection = []
        anchor = nil
    }
}
