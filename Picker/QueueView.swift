import SwiftUI

/// Every red cross appears here immediately; deletion always requires confirmation.
struct QueueView: View {
    @Bindable var model: LibraryModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("\(model.deletionPhotos.count.formatted()) photos waiting for deletion").font(.title2.bold())
                Text("Every photo marked with a cross appears here. Keep a photo to remove it from Pending, or open its group to change your choices.")
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 18)], spacing: 22) {
                    ForEach(model.queuedGroups) { group in
                        ForEach(ReviewRules.deletions(in: group, decision: model.decisions[group.id])) { photo in
                            VStack(alignment: .leading, spacing: 10) {
                                PhotoView(photo: photo).frame(height: 160).clipShape(RoundedRectangle(cornerRadius: 8))
                                HStack {
                                    Text(photo.date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                                    if photo.favorite { Image(systemName: "heart.fill").foregroundStyle(.pink).help("Favorite in Photos") }
                                    Spacer()
                                    Button { model.keepPending(photo, group: group) } label: { Image(systemName: "checkmark") }
                                        .help("Keep this photo and remove it from Pending").accessibilityLabel("Keep photo")
                                }
                                Button("Review Group") { model.reviewPendingGroup(group) }.font(.caption)
                            }
                        }
                    }
                }
                if model.deletionPhotos.isEmpty {
                    ContentUnavailableView("Nothing Pending", systemImage: "tray", description: Text("Mark photos with a cross in Similar Photos to add them here."))
                }
            }.padding(24)
        }
        .disabled(model.deleting || model.preparingReview || model.showQueue)
    }
}
