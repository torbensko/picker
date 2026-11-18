import SwiftUI

/// The blue preview ring is independent of these keep/remove choices.
struct DecisionControls: View {
    @Bindable var model: LibraryModel
    let photo: Photo
    let group: SimilarGroup
    var large = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var decision: Decision? { model.decisions[group.id] }
    private var kept: Bool { decision?.skipped == false && decision?.keepers.contains(photo.id) == true }
    private var discarded: Bool { ReviewRules.deletions(in: group, decision: decision).contains { $0.id == photo.id } }
    var body: some View {
        HStack(spacing: 4) {
            choice(symbol: "checkmark", color: .green, selected: kept, enabled: true,
                   label: "Keep photo", help: decision == nil ? "Keep this photo and mark the others for deletion. You can keep more afterward." : "Keep this photo. You can keep more than one.") {
                model.setKeeper(photo, in: group, keep: true)
            }
            choice(symbol: "xmark", color: .red, selected: discarded, enabled: true,
                   label: "Mark photo for deletion",
                   help: "Mark only this photo for deletion and add it to Pending.") {
                model.setKeeper(photo, in: group, keep: false)
            }
        }
        .padding(4)
        .background(.quaternary.opacity(0.45), in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.06), lineWidth: 1))
        .disabled(!model.canReview(group))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: decision)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Photo decision")
        .accessibilityValue(kept ? "Keeping" : discarded ? "Marked for deletion" : "No choice")
    }
    private func choice(symbol: String, color: Color, selected: Bool, enabled: Bool,
                        label: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: large ? 17 : 13, weight: .bold))
                .foregroundStyle(selected ? Color.white : Color.secondary.opacity(enabled ? 1 : 0.45))
                .frame(width: large ? 55 : 45, height: large ? 34 : 27)
                .background(selected ? color : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
