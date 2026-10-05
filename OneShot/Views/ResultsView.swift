import SwiftUI

/// The review screen: what was found, and what will happen if you tap delete.
struct ResultsView: View {
    @Environment(LibraryModel.self) private var library
    @State private var confirmingDelete = false

    var body: some View {
        @Bindable var library = library

        ScrollView {
            LazyVStack(spacing: 14, pinnedViews: []) {
                summary
                    .padding(.horizontal, 16)

                if library.resultsAreStale {
                    staleNotice
                        .padding(.horizontal, 16)
                }

                filters

                ForEach(library.visibleGroups) { group in
                    NavigationLink {
                        GroupDetailView(group: group)
                    } label: {
                        GroupCard(group: group)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                }

                SkippedNotice()
                    .padding(.top, 4)
            }
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .safeAreaInset(edge: .bottom) {
            if library.selectedCount > 0 {
                deleteBar
            }
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

    // MARK: Summary

    private var summary: some View {
        HStack(spacing: 0) {
            statistic("\(library.result.groups.count)", "Groups")
            divider
            statistic("\(library.result.duplicateCount)", "Duplicates")
            divider
            statistic(library.result.reclaimableBytes.formattedBytes, "Reclaimable")
        }
        .padding(.vertical, 16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func statistic(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(width: 1, height: 30)
    }

    private var staleNotice: some View {
        Label(
            "Your settings changed since this scan. Run it again for up-to-date results.",
            systemImage: "arrow.clockwise"
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Filters

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MediaKind.allCases) { kind in
                    let count = library.groupCount(for: kind)
                    if count > 0 {
                        FilterChip(
                            title: kind.displayName,
                            systemImage: kind.symbolName,
                            count: count,
                            isOn: library.visibleKinds.contains(kind)
                        ) {
                            toggle(kind)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func toggle(_ kind: MediaKind) {
        if library.visibleKinds.contains(kind) {
            // Never let the user filter everything away — the screen would look
            // like the scan found nothing.
            guard library.visibleKinds.count > 1 else { return }
            library.visibleKinds.remove(kind)
        } else {
            library.visibleKinds.insert(kind)
        }
    }

    // MARK: Delete bar

    private var deleteBar: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(library.selectedCount) selected")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                    Text("Frees about \(library.selectedBytes.formattedBytes)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Button {
                    confirmingDelete = true
                } label: {
                    if library.isDeleting {
                        ProgressView()
                            .frame(width: 92)
                    } else {
                        Text("Delete")
                            .font(.headline)
                            .frame(width: 92)
                    }
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .tint(.red)
                .disabled(library.isDeleting)
                // Attached to the button rather than the scrolling content so the
                // sheet anchors down here by the Delete button. Hung off the whole
                // view it anchored to the view's centre, putting the confirmation in
                // the middle of the screen and a long thumb-reach from the button
                // that opened it.
                .confirmationDialog(
                    library.deletePromptTitle(count: library.selectedCount),
                    isPresented: $confirmingDelete,
                    titleVisibility: .visible
                ) {
                    Button(library.deleteActionTitle, role: .destructive) {
                        Task { await library.deleteSelected() }
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text(library.deletePromptMessage)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }
}

// MARK: - Group card

/// One duplicate group, previewed as a filmstrip with the keeper first.
struct GroupCard: View {
    @Environment(LibraryModel.self) private var library
    let group: DuplicateGroup

    private static let previewLimit = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(
                    "\(group.members.count) \(group.kind.singularName.lowercased())\(group.members.count == 1 ? "" : "s")",
                    systemImage: group.isBurst ? "square.stack.3d.down.right" : group.kind.symbolName
                )
                .font(.subheadline.weight(.semibold))

                if group.isBurst {
                    Text("Burst")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }

                Spacer()
                ConfidenceBadge(group: group)
            }

            HStack(spacing: 6) {
                ForEach(group.members.prefix(Self.previewLimit)) { member in
                    thumbnail(for: member)
                }
                if group.members.count > Self.previewLimit {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.quaternary)
                        .overlay {
                            Text("+\(group.members.count - Self.previewLimit)")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 66, height: 66)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                let review = library.review(for: group)
                Image(systemName: review.isFullyKept ? "checkmark.circle" : "trash")
                    .font(.caption)
                Text(footerText(for: review))
                    .font(.caption)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// Mirrors the detail screen: a red tick means the copy is going, and the star
    /// marks the one OneShot suggested keeping.
    private func thumbnail(for member: ScoredAsset) -> some View {
        let isRecommended = group.keeperID == member.id
        let isMarked = library.review(for: group).deletionIDs.contains(member.id)

        return AssetImage(assetID: member.id, edge: 200)
            .frame(width: 66, height: 66)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                if isMarked {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.black.opacity(0.35))
                }
            }
            .overlay(alignment: .topLeading) {
                if isRecommended {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(.black.opacity(0.35), in: Circle())
                        .padding(3)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isMarked {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.white, .red)
                        .padding(3)
                }
            }
    }

    private func footerText(for review: GroupReview) -> String {
        if review.isFullyKept { return "Keeping all — nothing will be deleted" }
        let count = review.deletionIDs.count
        let bytes = group.members
            .filter { review.deletionIDs.contains($0.id) }
            .reduce(Int64(0)) { $0 + $1.record.byteSize }
        return "Deleting \(count) · frees \(bytes.formattedBytes)"
    }
}
