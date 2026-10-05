import Foundation
import Observation
import Photos
import SwiftUI

/// What the user has decided about one group, as distinct from what OneShot
/// recommended.
///
/// Marking for deletion is the only state a group carries. The scanner's pick lives
/// on `DuplicateGroup.keeperID` and never changes — it is a recommendation, shown as
/// a badge, not a protected slot. That keeps one idea on screen instead of two: a
/// ticked photo is going, an unticked one is staying, including the recommended one
/// if the user decides otherwise.
struct GroupReview: Sendable, Equatable {
    /// Members the user has marked for deletion.
    var deletionIDs: Set<String>

    var isFullyKept: Bool { deletionIDs.isEmpty }
}

/// The app's single source of truth, owned by the scene and shared through the
/// environment.
@MainActor
@Observable
final class LibraryModel {

    // MARK: Observable state

    private(set) var phase: ScanPhase = .idle
    private(set) var result: ScanResult = .empty
    private(set) var authorization: PHAuthorizationStatus = PhotoLibraryService.currentStatus
    private(set) var isDeleting = false
    /// Set when a delete attempt fails or is declined at the system prompt.
    var deletionMessage: String?
    /// Bytes actually reclaimed across this session, for the success screen.
    private(set) var reclaimedThisSession: Int64 = 0

    /// How many assets have a stored fingerprint, and what that costs on disk.
    private(set) var cachedFingerprints: Int = 0
    private(set) var cacheBytes: Int64 = 0

    var settings: ScanSettings {
        didSet {
            settings.save()
            if settings != oldValue { markResultStale() }
        }
    }

    /// True when settings changed after a scan, so the shown results no longer
    /// reflect the current configuration.
    private(set) var resultsAreStale = false

    /// Per-group user decisions, keyed by group id.
    private(set) var reviews: [UUID: GroupReview] = [:]

    /// Which media kinds the results are filtered to in the UI. Independent of
    /// `settings.includedKinds`, which controls what gets scanned at all.
    var visibleKinds: Set<MediaKind> = Set(MediaKind.allCases)

    /// Where the next scan reads from. Changing it invalidates results the way a
    /// settings change does — they were found somewhere else.
    private(set) var source: ScanSource = .photoLibrary

    // MARK: Private

    private let scanner = DuplicateScanner()
    private var scanTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?

    init() {
        settings = ScanSettings.load()
    }

    // MARK: - Analysis cache

    func refreshCacheStatistics() async {
        let statistics = await scanner.cacheStatistics()
        cachedFingerprints = statistics.count
        cacheBytes = statistics.bytes
    }

    /// Empties the analysis cache.
    ///
    /// The displayed figures are zeroed straight away rather than waiting for the
    /// database work to finish and be re-read. Clearing is instantaneous from the
    /// user's point of view, and leaving the old numbers on screen for a beat made it
    /// look as though the button had not worked.
    func clearCache() async {
        cachedFingerprints = 0
        cacheBytes = 0
        await scanner.clearCache()
        await refreshCacheStatistics()
    }

    // MARK: - Authorisation

    func refreshAuthorization() {
        authorization = PhotoLibraryService.currentStatus
    }

    func requestAccess() async {
        authorization = await PhotoLibraryService.requestAccess()
    }

    var hasFullAccess: Bool { authorization == .authorized }

    // MARK: - Scanning

    var isScanning: Bool { phase.isRunning }

    func startScan() {
        guard !isScanning else { return }
        scanTask?.cancel()
        progressTask?.cancel()
        reviews.removeAll()
        resultsAreStale = false
        phase = .indexing(done: 0, total: 0)

        // The scanner reports progress from a background actor far faster than the
        // screen can use it. A stream that buffers only the newest value coalesces
        // those reports, so the UI always shows the latest state without queueing
        // thousands of stale updates behind it.
        let (stream, continuation) = AsyncStream<ScanPhase>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )

        progressTask = Task { @MainActor [weak self] in
            for await update in stream {
                // Terminal phases are published by the completion path below, so the
                // phase and the results can never disagree on screen.
                guard !update.isTerminal else { continue }
                self?.phase = update
            }
        }

        let currentSettings = settings
        let currentSource = source
        let scanner = self.scanner
        scanTask = Task { @MainActor [weak self] in
            let outcome = await scanner.scan(settings: currentSettings, source: currentSource) { update in
                continuation.yield(update)
            }
            continuation.finish()
            self?.apply(outcome)
        }
    }

    // MARK: Source

    /// Picks up a folder chosen in the document picker.
    ///
    /// The security scope is opened here and stays open while that folder is the
    /// active source, because everything downstream — indexing, decoding, trashing —
    /// reads through it from background work.
    func useFolder(_ url: URL) {
        guard FolderAccess.begin(url) else {
            deletionMessage = "That folder could not be opened. Try choosing it again."
            return
        }
        setSource(.folder(FolderSelection(url: url)))
    }

    func usePhotoLibrary() {
        FolderAccess.end()
        setSource(.photoLibrary)
    }

    /// Reopens the folder from the last launch, if there was one.
    func restoreSource() {
        guard case .photoLibrary = source, let selection = FolderAccess.restore() else { return }
        source = .folder(selection)
    }

    private func setSource(_ newValue: ScanSource) {
        guard newValue != source else { return }
        source = newValue
        // Results found in one place say nothing about another, and the fingerprint
        // cache is keyed by id, so nothing has to be thrown away — only the results
        // on screen, which are now about somewhere else.
        result = .empty
        reviews.removeAll()
        resultsAreStale = false
        phase = .idle
    }

    /// How deleting is described, which differs by where the items live.
    ///
    /// Photo-library items go to Recently Deleted and iOS asks its own question
    /// first. Files are moved to the folder's trash by the app itself, with no second
    /// prompt — so promising one, or naming Photos, would be wrong on both counts.
    var deletionIsToTrash: Bool {
        if case .folder = source { return true }
        return false
    }

    var deleteActionTitle: String {
        deletionIsToTrash ? "Move to Trash" : "Move to Recently Deleted"
    }

    func deletePromptTitle(count: Int) -> String {
        let subject = count == 1 ? "item" : "items"
        return deletionIsToTrash
            ? "Move \(count) \(subject) to the Trash?"
            : "Move \(count) \(subject) to Recently Deleted?"
    }

    var deletePromptMessage: String {
        deletionIsToTrash
            ? "They are moved to the trash of the storage they are on, so they can be put back."
            : "They stay recoverable in Photos for 30 days. iOS will ask you to confirm as well."
    }

    /// True when the source is a folder that has gone away — ejected drive, deleted
    /// folder, or a bookmark iOS has stopped honouring.
    var folderIsMissing: Bool {
        guard case .folder(let selection) = source else { return false }
        return !FileManager.default.fileExists(atPath: selection.url.path)
    }

    /// Returns to the start screen without scanning.
    ///
    /// "Scan Again" and the rescan button used to kick off a scan immediately, which
    /// gave no chance to change the sensitivity or what gets included first. They now
    /// land here, so the scan is always something the user starts deliberately from
    /// the same screen.
    func returnToStart() {
        scanTask?.cancel()
        progressTask?.cancel()
        let scanner = self.scanner
        Task { await scanner.cancel() }

        result = .empty
        reviews.removeAll()
        resultsAreStale = false
        phase = .idle
    }

    func cancelScan() {
        let scanner = self.scanner
        Task { await scanner.cancel() }
        scanTask?.cancel()
        progressTask?.cancel()
        phase = .cancelled
    }

    private func apply(_ outcome: ScanResult) {
        result = outcome
        reviews = Dictionary(uniqueKeysWithValues: outcome.groups.map { group in
            // Default: everything except the recommended pick arrives ticked. The
            // user reviews this before anything happens.
            (group.id, GroupReview(deletionIDs: Set(group.duplicates.map(\.id))))
        })
        phase = .finished
    }

    private func markResultStale() {
        guard !result.groups.isEmpty else { return }
        resultsAreStale = true
    }

    // MARK: - Review

    func review(for group: DuplicateGroup) -> GroupReview {
        reviews[group.id] ?? GroupReview(deletionIDs: Set(group.duplicates.map(\.id)))
    }

    /// Ticks or unticks one photo. Any photo, including the recommended one — the
    /// recommendation is advice, not a lock.
    func toggleDeletion(of assetID: String, in group: DuplicateGroup) {
        var current = review(for: group)
        if current.deletionIDs.contains(assetID) {
            current.deletionIDs.remove(assetID)
        } else {
            current.deletionIDs.insert(assetID)
        }
        reviews[group.id] = current
    }

    /// Ticks everything except this one.
    func keepOnly(_ assetID: String, in group: DuplicateGroup) {
        reviews[group.id] = GroupReview(
            deletionIDs: Set(group.members.map(\.id)).subtracting([assetID])
        )
    }

    func keepAll(in group: DuplicateGroup) {
        reviews[group.id] = GroupReview(deletionIDs: [])
    }

    /// Back to what OneShot suggested: everything but the recommended pick.
    func resetToRecommendation(in group: DuplicateGroup) {
        reviews[group.id] = GroupReview(deletionIDs: Set(group.duplicates.map(\.id)))
    }

    /// True when the user has ticked every member, so the group would leave nothing
    /// behind. Allowed — they may genuinely want the whole set gone — but surfaced.
    func keepsNothing(in group: DuplicateGroup) -> Bool {
        review(for: group).deletionIDs.count == group.members.count
    }

    // MARK: - Aggregates

    var visibleGroups: [DuplicateGroup] {
        result.groups.filter { visibleKinds.contains($0.kind) }
    }

    var selectedIDs: Set<String> {
        var all: Set<String> = []
        for group in visibleGroups {
            all.formUnion(review(for: group).deletionIDs)
        }
        return all
    }

    var selectedCount: Int { selectedIDs.count }

    var selectedBytes: Int64 {
        var total: Int64 = 0
        for group in visibleGroups {
            let deletions = review(for: group).deletionIDs
            for member in group.members where deletions.contains(member.id) {
                total += member.record.byteSize
            }
        }
        return total
    }

    func groupCount(for kind: MediaKind) -> Int {
        result.groups.filter { $0.kind == kind }.count
    }

    // MARK: - Deletion

    /// Moves everything the user selected to Recently Deleted.
    ///
    /// iOS shows its own confirmation sheet on top of this; declining it surfaces as
    /// a thrown error and nothing changes. Items remain recoverable for 30 days.
    func deleteSelected() async {
        await delete(ids: selectedIDs, bytes: selectedBytes)
    }

    /// Deletes only what is ticked inside one group, so a group can be dealt with
    /// and dismissed without going back out to the whole-library bar.
    ///
    /// Returns whether the deletion happened, because the caller has to close the
    /// group afterwards: `removeDeleted` rebuilds every `DuplicateGroup`, so a detail
    /// screen still holding the old value would show photos that no longer exist and
    /// happily offer to delete them a second time.
    @discardableResult
    func deleteMarked(in group: DuplicateGroup) async -> Bool {
        let ids = review(for: group).deletionIDs
        let bytes = group.members
            .filter { ids.contains($0.id) }
            .reduce(Int64(0)) { $0 + $1.record.byteSize }
        return await delete(ids: ids, bytes: bytes)
    }

    @discardableResult
    private func delete(ids: Set<String>, bytes: Int64) async -> Bool {
        guard !ids.isEmpty else { return false }
        isDeleting = true
        defer { isDeleting = false }

        do {
            try await AssetLoader.delete(ids: Array(ids))
            reclaimedThisSession += bytes
            removeDeleted(ids)
            return true
        } catch {
            deletionMessage = "Nothing was deleted. \(error.localizedDescription)"
            return false
        }
    }

    /// Rebuilds the result set without the deleted assets, dropping any group that
    /// no longer has at least two members.
    private func removeDeleted(_ deleted: Set<String>) {
        var remaining: [DuplicateGroup] = []
        var updatedReviews: [UUID: GroupReview] = [:]

        for group in result.groups {
            let survivors = group.members.filter { !deleted.contains($0.id) }
            guard survivors.count >= 2 else { continue }

            let rebuilt = DuplicateGroup(members: survivors, kind: group.kind,
                                         isBurst: group.isBurst, confidence: group.confidence)
            remaining.append(rebuilt)
            updatedReviews[rebuilt.id] = GroupReview(
                deletionIDs: Set(rebuilt.duplicates.map(\.id))
            )
        }

        result = ScanResult(
            groups: remaining,
            assetsScanned: result.assetsScanned,
            skippedNotDownloaded: result.skippedNotDownloaded,
            skippedUnreadable: result.skippedUnreadable,
            duration: result.duration,
            sensitivity: result.sensitivity
        )
        reviews = updatedReviews
    }
}
