import Foundation
import UIKit

/// Sends each request to whichever library the item came from.
///
/// The two sources are told apart by the id itself: the photo library's ids are
/// `PHAsset` local identifiers, a folder's are `file://` URLs. Carrying the source
/// alongside every id would have meant threading it through the fingerprinter, the
/// face analyser, the feature-print service and every thumbnail view — for a
/// distinction each of them can make on its own by looking at the id it already has.
///
/// It also means a result can outlive the setting that produced it: a group found in
/// a folder still loads and still deletes correctly after the user switches the
/// source back to the photo library.
enum AssetLoader {

    /// True when this id names a file rather than a photo-library asset.
    static func isFile(_ id: String) -> Bool {
        id.hasPrefix("file:")
    }

    static func fetchRecords(
        source: ScanSource,
        kinds: Set<MediaKind>,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async -> [AssetRecord] {
        switch source {
        case .photoLibrary:
            // Detached: PhotoKit's fetch is synchronous and long enough on a large
            // library to block whatever called this.
            return await Task.detached(priority: .userInitiated) {
                PhotoLibraryService.fetchRecords(kinds: kinds, onProgress: progress)
            }.value
        case .folder(let selection):
            return await FolderLibraryService.fetchRecords(
                in: selection.url, kinds: kinds, progress: progress
            )
        }
    }

    /// Fills in true byte sizes and edit flags for the assets that made it into a
    /// group. Only the photo library needs it — a file's size is known from the
    /// moment it is listed.
    static func enrich(_ records: [AssetRecord]) -> [AssetRecord] {
        let library = records.filter { !isFile($0.id) }
        guard !library.isEmpty else { return records }

        let enriched = PhotoLibraryService.enrich(library)
        let byID = Dictionary(uniqueKeysWithValues: enriched.map { ($0.id, $0) })
        return records.map { byID[$0.id] ?? $0 }
    }

    static func loadThumbnail(for id: String, edge: Int) async -> Result<ThumbnailData, ThumbnailFailure> {
        if isFile(id) {
            return FolderLibraryService.loadThumbnail(for: id, edge: edge)
        }
        return await PhotoLibraryService.loadThumbnail(for: id, edge: edge)
    }

    static func loadPreview(for id: String, targetSize: CGSize, allowNetwork: Bool) async -> UIImage? {
        if isFile(id) {
            return FolderLibraryService.loadPreview(for: id, targetSize: targetSize)
        }
        return await PhotoLibraryService.loadPreview(
            for: id, targetSize: targetSize, allowNetwork: allowNetwork
        )
    }

    /// Deletes across both sources in one call, so a mixed selection cannot half-work.
    static func delete(ids: [String]) async throws {
        let files = ids.filter(isFile)
        let libraryItems = ids.filter { !isFile($0) }

        if !libraryItems.isEmpty {
            try await PhotoLibraryService.delete(ids: libraryItems)
        }
        if !files.isEmpty {
            try FolderLibraryService.delete(ids: files)
        }
    }
}
