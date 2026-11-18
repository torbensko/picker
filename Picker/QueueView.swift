import SwiftUI

/// Every red cross appears here immediately; deletion always requires confirmation.
struct QueueView: View {
    @Bindable var model: LibraryModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("\(model.deletionPhotos.count.formatted()) photos waiting for deletion").font(.title2.bold())
                Text("Keep or unmark any photo to remove it from Pending.")
                    .foregroundStyle(.secondary)
                if !model.pendingCleanup.isEmpty && !model.cleanupReady {
                    Text("Finish the library scan to verify your Cleanup selections before deleting.")
                        .foregroundStyle(.secondary)
                }
                if let notice = model.cleanupNotice {
                    HStack {
                        Text(notice)
                        Button("Dismiss") { model.cleanupNotice = nil }
                    }.font(.callout)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 18)], spacing: 22) {
                    ForEach(model.queuedGroups) { group in
                        ForEach(ReviewRules.deletions(in: group, decision: model.decisions[group.id])) { photo in
                            tile(photo, group: group)
                        }
                    }
                    ForEach(model.pendingCleanup) { photo in
                        tile(photo, group: nil)
                    }
                }
                if model.deletionPhotos.isEmpty {
                    ContentUnavailableView("Nothing Pending", systemImage: "tray", description: Text("Mark photos in Similar Photos or Cleanup to add them here."))
                }
            }.padding(24)
        }
        .disabled(model.deleting || model.preparingReview || model.showQueue)
    }

    private func tile(_ photo: Photo, group: SimilarGroup?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            PhotoView(photo: photo).frame(height: 160).clipShape(RoundedRectangle(cornerRadius: 8))
            HStack {
                Text(photo.date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                if photo.favorite { Image(systemName: "heart.fill").foregroundStyle(.pink).help("Favorite in Photos") }
                Spacer()
                Button {
                    if let group { model.keepPending(photo, group: group) }
                    else { model.unmarkCleanup(photo) }
                } label: { Image(systemName: "checkmark") }
                    .help("Remove this photo from Pending").accessibilityLabel("Remove photo from Pending")
            }
            if let group {
                Button("Review Group") { model.reviewPendingGroup(group) }.font(.caption)
            } else {
                Text("Cleanup").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
