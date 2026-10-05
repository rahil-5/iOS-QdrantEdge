import SwiftUI

/// Routes between the four states the app can be in once it has access:
/// ready to scan, scanning, results, or nothing found.
struct ScanFlowView: View {
    @Environment(LibraryModel.self) private var library
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("OneShot")
                .navigationBarTitleDisplayMode(library.phase.isRunning ? .inline : .large)
                .toolbar {
                    // Without this there is no way back to a fresh scan once results
                    // are on screen — the only route was to quit and relaunch.
                    if case .finished = library.phase, !library.result.groups.isEmpty {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                // Back to the start screen rather than straight into
                                // a scan, so settings can be changed first.
                                library.returnToStart()
                            } label: {
                                Label("Scan Again", systemImage: "arrow.clockwise")
                            }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingSettings = true
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                        }
                        .disabled(library.isScanning)
                    }
                }
                .sheet(isPresented: $showingSettings) {
                    SettingsView()
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch library.phase {
        case .idle, .cancelled:
            ScanStartView()
        case .indexing, .fingerprinting, .comparing, .scoring:
            ScanProgressView()
        case .finished:
            if library.result.groups.isEmpty {
                NothingFoundView()
            } else {
                ResultsView()
            }
        case .failed(let message):
            ScanFailedView(message: message)
        }
    }
}

// MARK: - Ready to scan

struct ScanStartView: View {
    @Environment(LibraryModel.self) private var library
    @State private var isChoosingFolder = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 10) {
                    Image(systemName: "square.stack.3d.down.right.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.tint)
                        .padding(.top, 24)

                    Text("Ready to scan")
                        .font(.title2.weight(.semibold))

                    Text(library.source.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                }

                // Everything the scan depends on, set from the screen that starts it.
                // These were read-only summaries of what Settings held, which meant
                // leaving this screen to change either of them and coming back.
                settingsCard

                if library.folderIsMissing {
                    Label(
                        "That folder can't be reached. If it was on a drive, reconnect it — or choose another.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 28)
                }

                Button {
                    library.startScan()
                } label: {
                    Label(library.source.scanButtonTitle, systemImage: "sparkle.magnifyingglass")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 14))
                .controlSize(.large)
                .disabled(library.folderIsMissing)
                .padding(.horizontal, 20)

                Text("The first scan reads every photo, so it takes the longest. After that OneShot only looks at what changed.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
            }
            .padding(.bottom, 40)
        }
        .fileImporter(
            isPresented: $isChoosingFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { outcome in
            if case .success(let urls) = outcome, let url = urls.first {
                library.useFolder(url)
            }
        }
    }

    private var settingsCard: some View {
        VStack(spacing: 0) {
            sourceRow
            Divider().padding(.leading, 52)
            sensitivityRow
            Divider().padding(.leading, 52)
            kindsRow
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 20)
    }

    /// The photo library, or any folder the Files app can reach — which includes a
    /// USB drive or SD card plugged into the device.
    private var sourceRow: some View {
        Menu {
            Button {
                library.usePhotoLibrary()
            } label: {
                Label("Photo Library", systemImage: "photo.on.rectangle.angled")
            }
            Button {
                isChoosingFolder = true
            } label: {
                Label("Choose Folder…", systemImage: "folder.badge.plus")
            }
            if case .folder = library.source {
                Divider()
                Button {
                    isChoosingFolder = true
                } label: {
                    Label("Change Folder…", systemImage: "folder")
                }
            }
        } label: {
            row("Source", library.source.title, library.source.symbolName)
        }
        .buttonStyle(.plain)
    }

    private var sensitivityRow: some View {
        Menu {
            Picker("Looking for", selection: sensitivityBinding) {
                ForEach(Sensitivity.allCases) { level in
                    Label(level.title, systemImage: level.symbolName).tag(level)
                }
            }
            .pickerStyle(.inline)
        } label: {
            row("Looking for", library.settings.sensitivity.title,
                library.settings.sensitivity.symbolName)
        }
        .buttonStyle(.plain)
    }

    private var kindsRow: some View {
        Menu {
            ForEach(MediaKind.allCases) { kind in
                Toggle(isOn: kindBinding(kind)) {
                    Label(kind.displayName, systemImage: kind.symbolName)
                }
            }
        } label: {
            row("Including", kindSummary, "photo.stack")
        }
        .buttonStyle(.plain)
    }

    private var sensitivityBinding: Binding<Sensitivity> {
        Binding(
            get: { library.settings.sensitivity },
            set: { library.settings.sensitivity = $0 }
        )
    }

    /// Keeps at least one kind selected — an empty set would make the scan silently
    /// find nothing, which reads as a broken app rather than a chosen filter.
    private func kindBinding(_ kind: MediaKind) -> Binding<Bool> {
        Binding(
            get: { library.settings.includedKinds.contains(kind) },
            set: { isOn in
                var kinds = library.settings.includedKinds
                if isOn {
                    kinds.insert(kind)
                } else {
                    guard kinds.count > 1 else { return }
                    kinds.remove(kind)
                }
                library.settings.includedKinds = kinds
            }
        )
    }

    private func row(_ title: String, _ value: String, _ symbol: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(.tint)
                .frame(width: 24)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.primary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }

    private var kindSummary: String {
        let included = MediaKind.allCases.filter { library.settings.includedKinds.contains($0) }
        if included.count == MediaKind.allCases.count { return "Everything" }
        if included.isEmpty { return "Nothing" }
        return included.map(\.displayName).joined(separator: ", ")
    }
}

// MARK: - Nothing found

struct NothingFoundView: View {
    @Environment(LibraryModel.self) private var library

    /// Reaching an empty list after deleting is a success, not an empty state.
    private var didClean: Bool { library.reclaimedThisSession > 0 }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: didClean ? "sparkles" : "checkmark.seal.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(didClean ? AnyShapeStyle(.tint) : AnyShapeStyle(.green))
                    .padding(.top, 48)

                Text(didClean ? "All cleaned up" : "No duplicates found")
                    .font(.title2.weight(.semibold))

                Text(didClean
                     ? "You freed about \(library.reclaimedThisSession.formattedBytes). Those items are in \(library.deletionIsToTrash ? "the trash" : "Recently Deleted") for the next 30 days if you change your mind."
                     : "OneShot checked \(library.result.assetsScanned.formatted()) items and didn't find any copies at the \(library.result.sensitivity.title.lowercased()) setting.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                if !didClean, library.result.sensitivity != .similar {
                    Text("Try a looser setting to catch burst frames and near-matches.")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                SkippedNotice()

                Button("Scan Again") { library.returnToStart() }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .padding(.top, 8)
            }
            .padding(.bottom, 40)
        }
    }
}

// MARK: - Failure

struct ScanFailedView: View {
    @Environment(LibraryModel.self) private var library
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.orange)
            Text("Scan didn't finish")
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Try Again") { library.startScan() }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
        }
    }
}

/// Reports assets that could not be read, so the totals are never quietly wrong.
struct SkippedNotice: View {
    @Environment(LibraryModel.self) private var library

    var body: some View {
        let cloud = library.result.skippedNotDownloaded
        let unreadable = library.result.skippedUnreadable

        if cloud > 0 || unreadable > 0 {
            VStack(spacing: 6) {
                if cloud > 0 {
                    Label(
                        "\(cloud.formatted()) items are stored in iCloud and weren't scanned. OneShot never uses the network, so it only reads what's on this device.",
                        systemImage: "icloud.slash"
                    )
                }
                if unreadable > 0 {
                    Label("\(unreadable.formatted()) items couldn't be read.", systemImage: "questionmark.folder")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
    }
}
