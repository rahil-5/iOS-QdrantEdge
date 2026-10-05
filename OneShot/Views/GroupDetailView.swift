import SwiftUI

/// Review one group up close: look at any copy, tick the ones to remove, and delete
/// them without leaving the group.
///
/// Two separate gestures, deliberately: tapping a photo *looks* at it, and tapping
/// its checkbox *marks* it. An earlier version overloaded a second tap on the same
/// photo to mean "toggle", which made viewing and deleting the same gesture.
///
/// A tick means the photo is going. The recommended keeper simply arrives unticked,
/// so the one thing on screen to understand is "ticked leaves, unticked stays".
struct GroupDetailView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(\.dismiss) private var dismiss
    let group: DuplicateGroup

    @State private var focusedID: String?
    @State private var confirmingDelete = false

    private var review: GroupReview { library.review(for: group) }

    private var focused: ScoredAsset {
        group.members.first { $0.id == focusedID } ?? group.keeper
    }

    private var markedCount: Int { review.deletionIDs.count }

    private var markedBytes: Int64 {
        group.members
            .filter { review.deletionIDs.contains($0.id) }
            .reduce(Int64(0)) { $0 + $1.record.byteSize }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                hero
                highlights
                actionRow
                if library.keepsNothing(in: group) { keepsNothingWarning }
                grid
                explanation
            }
            .padding(.bottom, 24)
        }
        .navigationTitle("\(group.members.count) copies")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if markedCount > 0 { deleteBar }
        }
        .onAppear {
            if focusedID == nil { focusedID = group.keeperID }
        }
        .alert(
            "Couldn't delete",
            isPresented: Binding(
                get: { library.deletionMessage != nil },
                set: { if !$0 { library.deletionMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { library.deletionMessage = nil }
        } message: {
            Text(library.deletionMessage ?? "")
        }
    }

    // MARK: Hero

    private var hero: some View {
        let isMarked = review.deletionIDs.contains(focused.id)

        return AssetImage(assetID: focused.id, edge: 900)
            .aspectRatio(
                CGSize(width: focused.record.pixelWidth, height: focused.record.pixelHeight),
                contentMode: .fit
            )
            .frame(maxWidth: .infinity)
            .frame(maxHeight: 380)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(alignment: .topTrailing) {
                SelectionCheckbox(isMarked: isMarked, size: 34) {
                    library.toggleDeletion(of: focused.id, in: group)
                }
                .padding(10)
            }
            .overlay(alignment: .topLeading) {
                if focused.id == group.keeperID {
                    Label("Best", systemImage: "star.fill")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(10)
                }
            }
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 8) {
                    AssetBadges(record: focused.record)
                    Text(isMarked ? "Will be deleted" : "Keeping")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(isMarked ? .red : .primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .padding(10)
            }
            .padding(.horizontal, 16)
            .animation(.smooth(duration: 0.2), value: focused.id)
            .animation(.smooth(duration: 0.2), value: isMarked)
    }

    private var highlights: some View {
        VStack(spacing: 8) {
            if !focused.highlights.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(focused.highlights, id: \.self) { highlight in
                            HighlightChip(highlight: highlight)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }

            HStack(spacing: 14) {
                metadata(focused.record.resolutionLabel, "aspectratio")
                metadata(focused.record.byteSize.formattedBytes, "internaldrive")
                if let date = focused.record.creationDate {
                    metadata(date.formatted(date: .abbreviated, time: .shortened), "calendar")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func metadata(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .labelStyle(.titleAndIcon)
    }

    // MARK: Actions

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button {
                library.keepOnly(focused.id, in: group)
            } label: {
                Label("Keep Only This", systemImage: "star")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)

            Button {
                if review.isFullyKept {
                    library.resetToRecommendation(in: group)
                } else {
                    library.keepAll(in: group)
                }
            } label: {
                Label(
                    review.isFullyKept ? "Use Suggestion" : "Untick All",
                    systemImage: review.isFullyKept ? "wand.and.stars" : "circle"
                )
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
        }
        .padding(.horizontal, 16)
    }

    private var keepsNothingWarning: some View {
        Label(
            "Every copy is ticked, so nothing from this group will be kept.",
            systemImage: "exclamationmark.triangle.fill"
        )
        .font(.footnote)
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
    }

    // MARK: Grid

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
            ForEach(group.members) { member in
                cell(for: member)
            }
        }
        .padding(.horizontal, 16)
    }

    private func cell(for member: ScoredAsset) -> some View {
        let isMarked = review.deletionIDs.contains(member.id)
        let isFocused = member.id == focused.id

        return AssetImage(assetID: member.id, edge: 320)
            .aspectRatio(1, contentMode: .fill)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                if isMarked {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.black.opacity(0.35))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isFocused ? Color.accentColor : .clear, lineWidth: 3)
            }
            .overlay(alignment: .topLeading) {
                if member.id == group.keeperID {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.black.opacity(0.35), in: Circle())
                        .padding(5)
                }
            }
            // Tapping the picture only ever means "show me this one".
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture {
                focusedID = member.id
            }
            // The checkbox sits on top and takes its own taps, so marking is never
            // something the user does by accident while browsing.
            .overlay(alignment: .topTrailing) {
                SelectionCheckbox(isMarked: isMarked, size: 26) {
                    library.toggleDeletion(of: member.id, in: group)
                }
                .padding(5)
            }
            .animation(.smooth(duration: 0.18), value: isMarked)
    }

    // MARK: Delete bar

    private var deleteBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(markedCount) ticked")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Text("Frees about \(markedBytes.formattedBytes)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Button {
                confirmingDelete = true
            } label: {
                if library.isDeleting {
                    ProgressView().frame(width: 108)
                } else {
                    Text("Delete These")
                        .font(.headline)
                        .frame(width: 108)
                }
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(.red)
            .disabled(library.isDeleting)
            // Attached to the button rather than the scrolling content so the sheet
            // anchors down here by the Delete button. Hung off the whole view it
            // anchored to the view's centre, putting the confirmation in the middle
            // of the screen and a long thumb-reach from the button that opened it.
            .confirmationDialog(
                library.deletePromptTitle(count: markedCount),
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button(library.deleteActionTitle, role: .destructive) {
                    Task {
                        // Close on success: this screen's `group` is a snapshot, and
                        // the model rebuilds every group after a deletion. Staying
                        // here would show deleted photos and offer to delete again.
                        if await library.deleteMarked(in: group) { dismiss() }
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text(library.deletePromptMessage)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: Explanation

    /// A single line explaining the two gestures.
    ///
    /// The "Why this one" panel that used to sit here restated what the chips above
    /// already show — the keeper's reasons are visible as `Sharpest`,
    /// `Highest resolution` and so on — so it was a paragraph of duplication in a
    /// screen about removing duplicates.
    private var explanation: some View {
        Text("Tap a photo to look at it. Tap its checkbox to tick it for deletion — ticked photos go, unticked ones stay.")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
    }

}

/// The tick that decides whether a photo is deleted.
///
/// Red and filled when set, because what it commits to is destructive; a hollow
/// outline when clear. Sized with enough padding to be a comfortable target without
/// covering the thumbnail it sits on.
struct SelectionCheckbox: View {
    let isMarked: Bool
    var size: CGFloat = 26
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isMarked ? AnyShapeStyle(.red) : AnyShapeStyle(.black.opacity(0.38)))
                    .overlay {
                        Circle().strokeBorder(.white.opacity(0.95), lineWidth: 1.5)
                    }
                    // A photo can be any colour under this, so the control carries
                    // its own separation rather than relying on the image behind it.
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                if isMarked {
                    Image(systemName: "checkmark")
                        .font(.system(size: size * 0.52, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: size, height: size)
            // Keeps the tap target usable even at the small grid size.
            .padding(6)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isMarked ? "Marked for deletion" : "Not marked")
        .accessibilityAddTraits(isMarked ? [.isSelected, .isButton] : .isButton)
    }
}
