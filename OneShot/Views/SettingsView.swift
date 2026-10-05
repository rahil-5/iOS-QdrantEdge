import SwiftUI

struct SettingsView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var isClearingCache = false

    var body: some View {
        @Bindable var library = library

        NavigationStack {
            Form {
                Section {
                    Picker("Match", selection: $library.settings.sensitivity) {
                        ForEach(Sensitivity.allCases) { level in
                            Label(level.title, systemImage: level.symbolName).tag(level)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("How closely to match")
                } footer: {
                    Text(library.settings.sensitivity.detail)
                }

                Section {
                    ForEach(MediaKind.allCases) { kind in
                        Toggle(isOn: binding(for: kind)) {
                            Label(kind.displayName, systemImage: kind.symbolName)
                        }
                    }
                } header: {
                    Text("What to scan")
                } footer: {
                    Text("Videos are compared by sampling five frames across their length, so scanning them takes noticeably longer than photos.")
                }

                Section {
                    // The cached count, not the last scan's total. Clearing the cache
                    // does not undo a scan, so showing `assetsScanned` here meant the
                    // number sat unchanged after clearing and looked broken.
                    LabeledContent("Analysed items") {
                        Text(library.cachedFingerprints.formatted())
                            .monospacedDigit()
                    }
                    LabeledContent("Cache size") {
                        Text(library.cacheBytes.formattedBytes)
                            .monospacedDigit()
                    }
                    Button(role: .destructive) {
                        isClearingCache = true
                        Task {
                            await library.clearCache()
                            isClearingCache = false
                        }
                    } label: {
                        if isClearingCache {
                            ProgressView()
                        } else {
                            Text("Clear Analysis Cache")
                        }
                    }
                    .disabled(isClearingCache)
                } header: {
                    Text("Storage")
                } footer: {
                    Text("OneShot remembers what it learned about each photo so later scans are quick. Clearing this only forces a full re-analysis — it never touches your photos.")
                }

                Section {
                    row("iphone.gen3", "On device only",
                        "Every image is analysed on this device, and matches are found with Qdrant Edge, a vector search engine that runs inside the app. OneShot has no server and makes no network requests — it works in aeroplane mode.")
                    row("icloud.slash", "iCloud photos are skipped",
                        "Items whose full-resolution copy lives only in iCloud aren't downloaded, so they aren't scanned. The count is shown with your results.")
                    row("arrow.uturn.backward", "Deletion is reversible",
                        library.deletionIsToTrash
                            ? "Anything you delete is moved to the trash of the storage it's on, so it can be put back."
                            : "Anything you delete goes to Recently Deleted in Photos and stays recoverable for 30 days.")
                } header: {
                    Text("Privacy")
                }

                Section {
                    LabeledContent("Version", value: appVersion)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await library.refreshCacheStatistics() }
        }
    }

    private func row(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    /// Keeps at least one media kind selected — an empty set would make the scan
    /// silently find nothing.
    private func binding(for kind: MediaKind) -> Binding<Bool> {
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

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
