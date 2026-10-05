import Foundation
import Photos
import UIKit
import CoreGraphics

/// All PhotoKit access, in one place.
///
/// Implemented as static methods on a caseless enum rather than an actor: every
/// PhotoKit entry point used here is already thread-safe, and serialising through
/// an actor would destroy the parallelism the fingerprint pass depends on. Nothing
/// here holds mutable state.
enum PhotoLibraryService {

    // MARK: - Authorisation

    static var currentStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    /// Requests full read-write access. OneShot asks for `.readWrite` because it
    /// deletes; `.addOnly` would not be enough.
    static func requestAccess() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    // MARK: - Indexing

    /// Flattens the library into `Sendable` records.
    ///
    /// Runs synchronously — call it from a background task. `byteSize` is an
    /// estimate at this stage; see `enrich(_:)` for why.
    static func fetchRecords(
        kinds: Set<MediaKind>,
        onProgress: (Int, Int) -> Void
    ) -> [AssetRecord] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.includeHiddenAssets = false
        options.includeAllBurstAssets = true
        options.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced]

        let fetched = PHAsset.fetchAssets(with: options)
        let total = fetched.count
        var records: [AssetRecord] = []
        records.reserveCapacity(total)

        for index in 0..<total {
            let asset = fetched.object(at: index)
            if let kind = classify(asset), kinds.contains(kind) {
                records.append(record(from: asset, kind: kind))
            }
            if index % 250 == 0 || index == total - 1 {
                onProgress(index + 1, total)
            }
        }
        return records
    }

    private static func classify(_ asset: PHAsset) -> MediaKind? {
        switch asset.mediaType {
        case .image:
            if asset.mediaSubtypes.contains(.photoScreenshot) { return .screenshot }
            if asset.mediaSubtypes.contains(.photoLive) { return .livePhoto }
            return .photo
        case .video:
            return .video
        default:
            return nil
        }
    }

    private static func record(from asset: PHAsset, kind: MediaKind) -> AssetRecord {
        AssetRecord(
            id: asset.localIdentifier,
            kind: kind,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            creationDate: asset.creationDate,
            modificationDate: asset.modificationDate,
            duration: asset.duration,
            isFavorite: asset.isFavorite,
            burstIdentifier: asset.burstIdentifier,
            // Filled in by `enrich(_:)` once the asset is known to matter.
            isEdited: false,
            isHDR: asset.mediaSubtypes.contains(.photoHDR),
            byteSize: estimatedBytes(kind: kind,
                                     pixelCount: asset.pixelWidth * asset.pixelHeight,
                                     duration: asset.duration)
        )
    }

    /// Rough on-disk size from dimensions alone.
    ///
    /// Reading the true size means loading `PHAssetResource` for every asset, which
    /// costs several seconds on a large library. During indexing an estimate is
    /// enough — sizes only matter once an asset is in a group, and `enrich(_:)`
    /// replaces these with real values for exactly those assets.
    private static func estimatedBytes(kind: MediaKind, pixelCount: Int, duration: TimeInterval) -> Int64 {
        switch kind {
        case .video:
            // ~1.2 MB/s for 1080p30 HEVC, scaled by resolution against 1080p.
            let resolutionScale = max(0.25, Double(pixelCount) / (1920.0 * 1080.0))
            return Int64(duration * 1_200_000 * resolutionScale)
        case .screenshot:
            // Flat UI compresses far better than photographic content.
            return Int64(Double(pixelCount) * 0.15)
        case .livePhoto:
            // Still plus a ~3 s video sidecar.
            return Int64(Double(pixelCount) * 0.30) + 1_800_000
        case .photo:
            return Int64(Double(pixelCount) * 0.30)
        }
    }

    /// Replaces estimated sizes with true ones and detects user edits, for a
    /// specific set of assets.
    ///
    /// Only called for assets that landed in a duplicate group — typically a few
    /// percent of the library — because `PHAssetResource.assetResources(for:)` hits
    /// the Photos database and is far too slow to run across everything.
    static func enrich(_ records: [AssetRecord]) -> [AssetRecord] {
        let ids = records.map(\.id)
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var byID: [String: PHAsset] = [:]
        for index in 0..<fetched.count {
            let asset = fetched.object(at: index)
            byID[asset.localIdentifier] = asset
        }

        return records.map { record in
            guard let asset = byID[record.id] else { return record }
            let resources = PHAssetResource.assetResources(for: asset)

            let isEdited = resources.contains { $0.type == .adjustmentData }
            let bytes = trueByteSize(from: resources) ?? record.byteSize

            var updated = record
            updated.byteSize = bytes
            updated.isEdited = isEdited
            return updated
        }
    }

    /// Sums the primary resources' file sizes.
    ///
    /// `fileSize` is not part of `PHAssetResource`'s public interface but is present
    /// on the underlying object and is the only way to get a true size without
    /// reading the whole file. Returns nil if the key is absent, in which case the
    /// caller keeps its estimate.
    private static func trueByteSize(from resources: [PHAssetResource]) -> Int64? {
        var total: Int64 = 0
        var found = false
        for resource in resources {
            // Adjustment sidecars are tiny metadata, not stored pixels.
            guard resource.type != .adjustmentData else { continue }
            if let size = resource.value(forKey: "fileSize") as? Int64 {
                total += size
                found = true
            } else if let size = resource.value(forKey: "fileSize") as? Int {
                total += Int64(size)
                found = true
            }
        }
        return found && total > 0 ? total : nil
    }

    // MARK: - Pixels

    /// Loads one asset's pixels as a fixed-size square, without touching the network.
    ///
    /// `isNetworkAccessAllowed` is hard-coded to `false`: the whole point of OneShot
    /// is that it works with aeroplane mode on. Assets that live only in iCloud
    /// surface as `.notDownloaded` and are counted, not silently dropped.
    static func loadThumbnail(for id: String, edge: Int) async -> Result<ThumbnailData, ThumbnailFailure> {
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        guard fetched.count > 0 else { return .failure(.missing) }
        let asset = fetched.object(at: 0)

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .highQualityFormat  // guarantees a single callback
        options.resizeMode = .exact
        options.isSynchronous = false
        options.version = .current  // the edited version, which is what the user sees

        let size = CGSize(width: edge, height: edge)

        let image: UIImage? = await withCheckedContinuation { continuation in
            let box = ContinuationBox(continuation)
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: size,
                // `.aspectFit`, not `.aspectFill`. With a square target size,
                // `.aspectFill` makes PhotoKit return a centre-cropped square, which
                // silently discards the left and right quarters of every 4:3 frame —
                // the hash then describes only the middle of the picture. `.aspectFit`
                // returns the whole frame, which `rasterize` then squashes to a
                // square, matching what `ThumbnailData` documents and what the
                // thresholds were calibrated against.
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !degraded else { return }
                box.resume(with: image)
            }
        }

        guard let image else {
            // A nil image with no error almost always means "in iCloud, and we
            // declined to fetch it".
            return .failure(.notDownloaded)
        }
        guard let rgba = rasterize(image, edge: edge) else {
            return .failure(.undecodable)
        }
        return .success(ThumbnailData(rgba: rgba, edge: edge))
    }

    /// Draws a `UIImage` into a fixed-size RGBA buffer.
    ///
    /// Goes via `UIGraphicsImageRenderer` so `imageOrientation` is applied — a
    /// portrait photo whose CGImage is stored landscape must hash the same way the
    /// user sees it, or every rotated asset would fail to match its own copy.
    private static func rasterize(_ image: UIImage, edge: Int) -> [UInt8]? {
        let side = CGFloat(edge)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let normalised = renderer.image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        guard let cgImage = normalised.cgImage else { return nil }
        return ThumbnailData.rasterize(cgImage: cgImage, edge: edge)
    }

    /// Loads a display-sized image for the review UI. Unlike the scanning path this
    /// one *may* use the network, because by then the user has explicitly asked to
    /// look at a specific photo.
    static func loadPreview(for id: String, targetSize: CGSize, allowNetwork: Bool) async -> UIImage? {
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        guard fetched.count > 0 else { return nil }
        let asset = fetched.object(at: 0)

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = allowNetwork
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isSynchronous = false

        return await withCheckedContinuation { continuation in
            let box = ContinuationBox(continuation)
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !degraded else { return }
                box.resume(with: image)
            }
        }
    }

    // MARK: - Deletion

    /// Moves the given assets to Recently Deleted.
    ///
    /// iOS presents its own confirmation sheet for this and the user can cancel it,
    /// which surfaces here as a thrown error. Deleted items remain recoverable in
    /// Recently Deleted for 30 days — OneShot never destroys anything permanently.
    static func delete(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        try await PHPhotoLibrary.shared().performChanges {
            // Fetched inside the closure: `PHFetchResult` is not `Sendable` and
            // must not be captured across the boundary.
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            PHAssetChangeRequest.deleteAssets(assets)
        }
    }
}

/// Guarantees a `CheckedContinuation` is resumed exactly once.
///
/// `PHImageManager` promises a single callback for `.highQualityFormat`, but a
/// cancelled or failed request can still deliver an extra degraded callback in
/// practice, and resuming twice traps. This box makes that impossible.
private final class ContinuationBox: @unchecked Sendable {
    private var continuation: CheckedContinuation<UIImage?, Never>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<UIImage?, Never>) {
        self.continuation = continuation
    }

    func resume(with image: UIImage?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: image)
    }
}
