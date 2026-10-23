import SwiftUI

struct ScreenshotsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var archive = ScreenshotArchive()
    @State private var confirm = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Screenshots").font(.title2.bold())
                    Text("\(archive.photos.count.formatted()) in Photos · \(archive.selected.count.formatted()) selected").foregroundStyle(.secondary)
                    Text("Export originals to a folder, then delete them from your library.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.disabled(archive.busy)
            }.padding(24)
            Divider()
            if archive.photos.isEmpty {
                ContentUnavailableView("No Screenshots", systemImage: "viewfinder", description: Text("Only images Apple Photos identifies as screenshots appear here."))
            } else {
                HStack {
                    Button("Select All") { archive.selected = Set(archive.photos.map(\.id)) }
                    Button("Deselect All") { archive.selected = [] }
                    Spacer()
                    Text("Identified by Apple Photos").foregroundStyle(.secondary)
                }.font(.caption).padding(.horizontal, 24).padding(.top, 12)
                    .disabled(archive.busy || archive.export != nil)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 18) {
                        ForEach(archive.photos) { photo in
                            VStack(alignment: .leading, spacing: 6) {
                                PhotoView(photo: photo).frame(height: 130).clipShape(RoundedRectangle(cornerRadius: 6))
                                Toggle(isOn: Binding(get: { archive.selected.contains(photo.id) }, set: { selected in
                                    if selected { archive.selected.insert(photo.id) } else { archive.selected.remove(photo.id) }
                                })) { Text(photo.date.formatted(date: .abbreviated, time: .omitted)).font(.caption) }
                                if photo.favorite { Label("Favorite", systemImage: "heart.fill").font(.caption).foregroundStyle(.pink) }
                            }
                        }
                    }.padding(24)
                }.disabled(archive.busy || archive.export != nil)
            }
            Spacer(minLength: 0)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if !archive.status.isEmpty { Text(archive.status).font(.callout) }
                HStack {
                    if archive.busy {
                        ProgressView().controlSize(.small)
                        if archive.export == nil { Button("Stop After Current File") { archive.cancel() } }
                    }
                    if let folder = archive.folder {
                        Button("Show Export in Finder", systemImage: "folder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path) }
                    }
                    Spacer()
                    if let export = archive.export {
                        Button("Delete \(export.assets.count) Exported Screenshots…", role: .destructive) { confirm = true }.disabled(archive.busy)
                    } else {
                        Button("Export & Delete…", systemImage: "square.and.arrow.up") { archive.chooseFolder() }
                            .buttonStyle(.glassProminent).disabled(archive.selected.isEmpty || archive.busy)
                    }
                }
                Text("Photos downloads iCloud originals automatically. Nothing is deleted until export succeeds and you confirm.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }
        .frame(width: 850, height: 720)
        .task { archive.load() }
        .onDisappear { archive.releaseAccess() }
        .interactiveDismissDisabled(archive.busy)
        .alert("Screenshots", isPresented: Binding(get: { archive.error != nil }, set: { if !$0 { archive.error = nil } })) {
            Button("OK", role: .cancel) { archive.error = nil }
        } message: { Text(archive.error ?? "") }
        .confirmationDialog("Delete the exported screenshots from Photos?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Delete \(archive.export?.assets.count ?? 0) Screenshots", role: .destructive) { Task { await archive.deleteExported() } }
            Button("Keep in Photos", role: .cancel) {}
        } message: {
            Text("All \(archive.export?.assets.count ?? 0) screenshots have been exported, including any selected favorites. Deletion syncs through iCloud Photos. They remain recoverable in Recently Deleted for 30 days. Your exported files stay in the chosen folder.")
        }
    }
}
