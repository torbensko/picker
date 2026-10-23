import SwiftUI
import AppKit

struct ContentView: View {
    @Bindable var model: LibraryModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        Group {
            if model.hasAccess { workspace } else { welcome }
        }
        .background(ReviewKeyboard(model: model))
        .task { model.start() }
        .sheet(isPresented: $model.showScreenshots, onDismiss: model.queueClosed) { ScreenshotsView() }
        .confirmationDialog(deletionTitle, isPresented: $model.showQueue, titleVisibility: .visible) {
            Button("Delete \(model.plannedPhotos.count) Photos", role: .destructive) { model.deleteConfirmedPlan() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deletionMessage)
        }
        .onChange(of: model.showQueue) { _, presented in if !presented { model.queueClosed() } }
        .alert("Picker", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private var deletionTitle: String {
        model.deletionScope == .currentGroup
            ? "Delete \(model.plannedPhotos.count) photos from this group?"
            : "Delete all \(model.plannedPhotos.count) pending photos?"
    }
    private var deletionMessage: String {
        let favorites = model.plannedPhotos.filter(\.favorite).count
        let scope: String
        if model.deletionScope == .currentGroup, let entry = model.deletionPlan.first {
            scope = "Only the group from \(entry.group.date.formatted(date: .abbreviated, time: .shortened)) will be processed. Its \(entry.decision.keepers.count) keepers stay in Photos. Other pending groups are unchanged."
        } else {
            scope = "This deletes the entire Pending list across \(model.deletionPlan.count) groups. All keepers stay in Photos."
        }
        return "\(scope) \(favorites > 0 ? "Includes \(favorites) favorites. " : "")Deletion syncs through iCloud Photos. You can recover deleted photos in Recently Deleted."
    }

    private var welcome: some View {
        VStack(spacing: 24) {
            Image(systemName: "photo.stack").font(.system(size: 64, weight: .light)).foregroundStyle(.tint)
            VStack(spacing: 10) {
                Text("Make room for your favorites.").font(.largeTitle.bold())
                Text("Clean up your Apple Photos library.\nPicker finds similar photos so you can keep the ones you love.")
                    .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Button("Connect to Photos") { Task { await model.connect() } }
                .buttonStyle(.glassProminent).controlSize(.large)
            Text("Allow full Photos access to scan your library automatically.\nThere’s no need to select or import photos.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if model.authorization == .denied || model.authorization == .restricted {
                Text("Allow Photos access in System Settings → Privacy & Security → Photos, then reopen Picker.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Open System Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!)
                }
            }
            Label("On-device analysis. Downloads only when you request them.", systemImage: "lock.shield")
                .font(.callout).foregroundStyle(.secondary)
        }.padding(48).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sidebar: some View {
        List(selection: $model.filter) {
            Section("Library") {
                ForEach(ReviewFilter.allCases) { filter in
                    Label {
                        HStack {
                            Text(filter.rawValue)
                            Spacer()
                            Text(model.sidebarCount(filter).formatted()).foregroundStyle(.secondary).monospacedDigit()
                        }
                    } icon: { Image(systemName: filter.symbol) }
                    .tag(filter)
                }
                Button { model.openScreenshots() } label: {
                    Label("Screenshots", systemImage: "viewfinder")
                }.buttonStyle(.plain).disabled(model.deleting || model.preparingReview)
            }
        }
        .disabled(model.deleting || model.showQueue || model.preparingReview)
        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Analysis on this Mac", systemImage: "lock.shield").font(.caption.weight(.medium))
                    Spacer(minLength: 4)
                    Menu {
                        if model.scanning { Button("Stop Scan") { model.cancelScan() } }
                        else {
                            Button("Check for New or Changed Photos") { model.refresh() }
                            Button("Retry Unavailable Photos") { model.refresh(retryUnavailable: true) }
                        }
                    } label: { Image(systemName: model.scanning ? "stop.circle" : "arrow.clockwise") }
                        .menuStyle(.borderlessButton).fixedSize()
                        .help("Library scan options")
                        .disabled(model.deleting || model.preparingReview || model.showQueue)
                }
                Text("Scanning never downloads photos. You choose when to fetch an iCloud preview.").font(.caption).foregroundStyle(.secondary)
            }.padding()
        }
    }

    private var workspace: some View {
        VStack(spacing: 0) {
            Group {
                if model.filter == .pending {
                    NavigationSplitView(columnVisibility: $columnVisibility) { sidebar } detail: {
                        QueueView(model: model)
                            .toolbar { pendingToolbar }
                    }
                } else {
                    NavigationSplitView(columnVisibility: $columnVisibility) { sidebar } content: { groupList } detail: {
                        if let group = model.selectedGroup {
                            Group {
                                if let entry = model.history[group.id], entry.deletedAt != nil || (model.filter == .history && entry.invalidated) {
                                    historyDetail(entry)
                                } else { review(group) }
                            }
                            .toolbar { groupToolbar(group) }
                        } else {
                            ContentUnavailableView(model.filter == .history ? "No History Yet" : "Choose a Group", systemImage: model.filter.symbol,
                                description: Text(model.filter == .history ? "Groups appear here when you apply your choices." : "Completed groups appear as the scan continues."))
                        }
                    }
                }
            }
            .onChange(of: model.filter) { model.ensureSelection() }
            .onChange(of: model.selectedID) { _, _ in model.highlightedID = model.selectedGroup?.suggestedID }
            .toolbar(removing: .title)
            .overlay {
                if model.preparingReview || model.deleting {
                    ProgressView(model.deleting ? "Deleting confirmed photos…" : "Preparing confirmation…")
                        .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            footer
        }
    }

    private var groupList: some View {
        List(selection: $model.selectedID) {
            ForEach(model.visibleGroups) { group in
                GroupRow(group: group, decision: model.decisions[group.id], history: model.history[group.id]).tag(group.id)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(model.filter.rawValue).font(.headline)
            }.sharedBackgroundVisibility(.hidden)
        }
        .disabled(model.deleting || model.preparingReview || model.showQueue)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        .overlay {
            if model.visibleGroups.isEmpty {
                ContentUnavailableView(model.scanning && model.filter == .all ? "Finding Similar Photos" : "All Caught Up",
                    systemImage: model.filter.symbol, description: Text(model.filter == .history ? "Processed groups will appear here." : "New completed groups appear while you review."))
            }
        }
    }

    // Automatic placement keeps this group at the detail column’s leading edge.
    // Principal would center it; navigation would move it ahead of the column title.
    // The native flexible spacer keeps Reset and Apply at the trailing edge.
    @ToolbarContentBuilder private func groupToolbar(_ group: SimilarGroup) -> some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            HStack(spacing: 12) {
                groupNavigation
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.date.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                    Text(groupSummary(group)).font(.caption).foregroundStyle(.secondary)
                }.lineLimit(1)
            }
        }.sharedBackgroundVisibility(.hidden)
        ToolbarSpacer(.flexible, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Button("Reset") { model.reset(group) }
                .disabled(!model.canReview(group) || (model.decisions[group.id] == nil && model.history[group.id] == nil))
                .help("Clear this group’s choices")
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Apply") { model.applyCurrentGroup() }
                .buttonStyle(.glassProminent).disabled(!model.canApply(group))
                .help("Confirm deletion of this group’s crossed photos, then move the group to History")
        }
    }

    @ToolbarContentBuilder private var pendingToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) { Text("Pending").font(.headline) }
            .sharedBackgroundVisibility(.hidden)
        ToolbarSpacer(.flexible, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Button("Delete All \(model.deletionPhotos.count.formatted()) Pending Photos…", role: .destructive) { model.openQueue() }
                .disabled(model.deletionPhotos.isEmpty || model.deleting || model.preparingReview || model.showQueue)
                .help("Delete every crossed photo across all pending groups, after confirmation")
        }
    }

    private var groupNavigation: some View {
        HStack(spacing: 0) {
            Button { model.moveGroup(-1) } label: {
                Image(systemName: "chevron.left").frame(width: 32, height: 32).contentShape(Rectangle())
            }
            .help("Previous group (⌘↑)").accessibilityLabel("Previous Group")
            .disabled(model.visibleGroups.first?.id == model.selectedID || model.visibleGroups.isEmpty)
            Button { model.moveGroup(1) } label: {
                Image(systemName: "chevron.right").frame(width: 32, height: 32).contentShape(Rectangle())
            }
            .help("Next group (⌘↓)").accessibilityLabel("Next Group")
            .disabled(model.visibleGroups.last?.id == model.selectedID || model.visibleGroups.isEmpty)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: Capsule())
        .disabled(model.deleting || model.preparingReview || model.showQueue)
    }

    private func groupSummary(_ group: SimilarGroup) -> String {
        if let entry = model.history[group.id], entry.deletedAt != nil {
            return "\(entry.decision.keepers.count) kept · \(group.photos.count - entry.decision.keepers.count) deleted"
        }
        let count = model.decisions[group.id]?.keepers.count ?? 0
        guard count > 0 else { return "\(group.photos.count) photos · choose your keepers" }
        return "\(count) kept · \(group.photos.count - count) to remove"
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 14) {
                if model.scanning {
                    ProgressView(value: Double(model.scanned), total: Double(max(model.total, 1))).frame(width: 70)
                    Text("Checked \(model.scanned.formatted()) / \(model.total.formatted())")
                        .help("\(model.cachedPhotos.formatted()) cached · \(model.newlyAnalyzed.formatted()) newly analyzed")
                }
                Text("\(model.total.formatted()) photos")
                Text("\(model.groups.count.formatted()) groups")
                Text("\(model.potentialRemovalCount.formatted()) potential removals")
                    .help("Assumes keeping one photo in each detected group; independent of your choices.")
                Spacer(minLength: 0)
                Label("\(model.deletionPhotos.count.formatted()) marked for deletion", systemImage: "trash")
                Spacer(minLength: 0)
                if model.unavailable > 0 { Text("\(model.unavailable.formatted()) unavailable locally") }
            }.font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8).padding(12)
        }.background(.bar)
    }

    private func review(_ group: SimilarGroup) -> some View {
        VStack(spacing: 0) {
            if let photo = model.highlighted {
                PhotoView(photo: photo, large: true)
                    .frame(minHeight: 0, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .topTrailing) {
                        Button { model.preview.toggle() } label: {
                            Image(systemName: model.preview ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.glass).buttonBorderShape(.circle)
                        .help(model.preview ? "Show Thumbnails (Space)" : "Hide Thumbnails (Space)")
                        .accessibilityLabel(model.preview ? "Show Thumbnails" : "Hide Thumbnails")
                        .disabled(model.deleting || model.preparingReview || model.showQueue)
                        .padding(12)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if model.preview { DecisionControls(model: model, photo: photo, group: group).padding(12) }
                    }
                    .padding(10)
            }
            if !model.preview {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 14) {
                            ForEach(group.photos) { photo in
                                VStack(spacing: 7) {
                                    Button { model.highlightedID = photo.id } label: {
                                        PhotoView(photo: photo).frame(width: 190, height: 112)
                                            .clipShape(RoundedRectangle(cornerRadius: 6))
                                            .overlay(alignment: .topLeading) {
                                                if photo.id == group.suggestedID {
                                                    Text("Recommended").font(.system(size: 9, weight: .semibold))
                                                        .foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 3)
                                                        .background(.orange, in: RoundedRectangle(cornerRadius: 3)).padding(5)
                                                }
                                            }
                                            .overlay {
                                                RoundedRectangle(cornerRadius: 6).stroke(photo.id == model.highlightedID ? Color.accentColor : .clear, lineWidth: 3)
                                            }
                                    }.buttonStyle(.plain)
                                        .accessibilityLabel("Preview photo \(group.photos.firstIndex(of: photo).map { $0 + 1 } ?? 1)")
                                        .accessibilityAddTraits(photo.id == model.highlightedID ? .isSelected : [])
                                    DecisionControls(model: model, photo: photo, group: group)
                                }.frame(width: 190).padding(4).id(photo.id)
                            }
                        }.padding(.horizontal, 12).padding(.vertical, 6)
                    }.frame(height: 176).fixedSize(horizontal: false, vertical: true)
                    .onAppear { if let id = model.highlightedID { proxy.scrollTo(id, anchor: .center) } }
                    .onChange(of: model.highlightedID) { _, id in
                        if let id { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) } }
                    }
                }.transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }.animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: model.preview)
    }

    private func historyDetail(_ entry: ProcessedGroup) -> some View {
        VStack(spacing: 20) {
            Label(entry.invalidated ? "Library Changed" : "Cleanup Complete", systemImage: entry.invalidated ? "arrow.clockwise" : "checkmark.circle.fill")
                .font(.title2).foregroundStyle(entry.invalidated ? Color.secondary : Color.green)
            Text(entry.invalidated ? "These photos changed after review. Review the updated group in Similar Photos before applying it again." : "\(entry.decision.keepers.count) kept · \(entry.group.photos.count - entry.decision.keepers.count) deleted")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            if !entry.invalidated {
                Text("Processed \(entry.processedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(entry.group.photos.filter { entry.decision.keepers.contains($0.id) }) { photo in
                            PhotoView(photo: photo).frame(width: 200, height: 160).clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                Text("Deleted photos can be recovered from Recently Deleted in Apple Photos.").font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Review Updated Group") { model.filter = .all; model.select(model.groups.first { $0.id == entry.id }) }
            }
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct GroupRow: View {
    let group: SimilarGroup
    let decision: Decision?
    let history: ProcessedGroup?
    var body: some View {
        HStack(spacing: 12) {
            if let photo = group.photos.first(where: { history?.deletedAt == nil || history?.decision.keepers.contains($0.id) == true }) {
                PhotoView(photo: photo).frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 5))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(group.date.formatted(date: .abbreviated, time: .omitted)).font(.headline)
                Text("\(group.photos.count) photos · \(group.date.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                if let history {
                    Label(history.deletedAt != nil ? "Cleaned up" : history.invalidated ? "Needs review" : history.decision.skipped ? "Reviewed without deletion" : "Kept all", systemImage: history.deletedAt != nil ? "checkmark.circle.fill" : "clock")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let decision, !decision.keepers.isEmpty {
                    Text("\(decision.keepers.count) kept · \(group.photos.count - decision.keepers.count) pending").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(.vertical, 5)
    }
}
