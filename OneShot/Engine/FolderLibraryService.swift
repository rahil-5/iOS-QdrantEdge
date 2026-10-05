import Foundation
import CoreGraphics
import ImageIO
import UIKit
import UniformTypeIdentifiers
import AVFoundation

/// The folder equivalent of `PhotoLibraryService`.
///
/// Same job, different shelf: list what is there, hand the engine pixels, and delete
/// what the user ticks. Items are identified by their `file://` URL, which is what
/// lets one id type serve both sources — see `AssetLoader`.
///
/// Like everything else in OneShot this touches no network. A folder in iCloud Drive
/// whose contents have not been downloaded is reported as such rather than fetched,
/// exactly as an iCloud-only photo is.
enum FolderLibraryService {

    // MARK: Indexing

    /// Walks `folder` and its subfolders, one record per image or video.
    static func fetchRecords(
        in folder: URL,
        kinds: Set<MediaKind>,
        progress: (Int, Int) -> Void
    ) async -> [AssetRecord] {
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .contentTypeKey, .fileSizeKey,
            .creationDateKey, .contentModificationDateKey, .isUbiquitousItemKey
        ]
        let manager = FileManager.default
        guard let walker = manager.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        // Counted first so the progress bar has a denominator. Walking a folder twice
        // is cheap next to reading the pixels of everything in it.
        let urls = walker.compactMap { $0 as? URL }
        var records: [AssetRecord] = []
        records.reserveCapacity(urls.count)

        for (index, url) in urls.enumerated() {
            progress(index, urls.count)
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let type = values.contentType else { continue }

            let kind: MediaKind
            if type.conforms(to: .image) {
                kind = .photo
            } else if type.conforms(to: .movie) {
                kind = .video
            } else {
                continue
            }
            guard kinds.contains(kind) else { continue }

            let size: (width: Int, height: Int)
            let duration: TimeInterval
            if kind == .video {
                // Read from the clip itself. Left as placeholders these disable two
                // cheap rejections the video path leans on — clips of different
                // lengths or shapes are never the same clip — which would leave every
                // pair of videos to be settled by keyframes alone.
                let measured = await videoProperties(of: url)
                size = measured.size
                duration = measured.duration
            } else {
                size = dimensions(of: url)
                duration = 0
            }
            guard size.width > 0, size.height > 0 else { continue }

            records.append(
                AssetRecord(
                    id: url.absoluteString,
                    kind: kind,
                    pixelWidth: size.width,
                    pixelHeight: size.height,
                    creationDate: values.creationDate,
                    modificationDate: values.contentModificationDate,
                    duration: duration,
                    // A file carries no favourite flag and no burst grouping; both
                    // are photo-library ideas. The scorer already treats them as
                    // optional signals rather than requirements.
                    isFavorite: false,
                    burstIdentifier: nil,
                    isEdited: false,
                    isHDR: false,
                    // Unlike the photo library, the true size is known up front, so
                    // there is nothing for `enrich` to go back for.
                    byteSize: Int64(values.fileSize ?? 0)
                )
            )
        }
        progress(urls.count, urls.count)
        return records
    }

    /// Pixel dimensions from the file's header, without decoding it.
    private static func dimensions(of url: URL) -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return (0, 0) }
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        return (width, height)
    }

    /// Length and frame size of a clip, orientation applied.
    private static func videoProperties(of url: URL) async -> (size: (width: Int, height: Int), duration: TimeInterval) {
        let asset = AVURLAsset(url: url)
        guard let seconds = try? await CMTimeGetSeconds(asset.load(.duration)),
              seconds.isFinite, seconds > 0 else {
            return ((0, 0), 0)
        }
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let natural = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else {
            return ((0, 0), seconds)
        }
        // A portrait clip is stored landscape with a rotation on it, so the raw
        // natural size would describe a shape the frames are never shown in.
        let presented = natural.applying(transform)
        return ((Int(abs(presented.width)), Int(abs(presented.height))), seconds)
    }

    // MARK: Pixels

    /// The square thumbnail the fingerprinter works from.
    static func loadThumbnail(for id: String, edge: Int) -> Result<ThumbnailData, ThumbnailFailure> {
        guard let url = URL(string: id) else { return .failure(.missing) }
        guard FileManager.default.fileExists(atPath: url.path) else { return .failure(.missing) }

        // `kCGImageSourceCreateThumbnailFromImageAlways` decodes at the size asked
        // for rather than in full, which is the same saving PhotoKit's target size
        // gives on the library path.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: edge * 2,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return .failure(.undecodable) }

        guard let data = ThumbnailData(cgImage: image, edge: edge) else {
            return .failure(.undecodable)
        }
        return .success(data)
    }

    /// A display-sized image for the review screen.
    static func loadPreview(for id: String, targetSize: CGSize) -> UIImage? {
        guard let url = URL(string: id),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let maxPixel = Int(max(targetSize.width, targetSize.height))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixel, 1)
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: image)
    }

    // MARK: Deleting

    /// Moves files to the volume's trash.
    ///
    /// The counterpart of `PHAssetChangeRequest.deleteAssets`, and recoverable for
    /// the same reason: nothing is unlinked, it is moved. Where a volume has no trash
    /// — some external drives — `trashItem` fails, and the caller is told rather than
    /// the file being deleted outright behind the user's back.
    static func delete(ids: [String]) throws {
        let manager = FileManager.default
        var failures: [String] = []

        for id in ids {
            guard let url = URL(string: id) else { continue }
            guard manager.fileExists(atPath: url.path) else { continue }
            do {
                try manager.trashItem(at: url, resultingItemURL: nil)
            } catch {
                failures.append(url.lastPathComponent)
            }
        }

        if !failures.isEmpty {
            throw FolderDeletionError.couldNotTrash(names: failures)
        }
    }
}

enum FolderDeletionError: LocalizedError {
    case couldNotTrash(names: [String])

    var errorDescription: String? {
        switch self {
        case .couldNotTrash(let names):
            let subject = names.count == 1 ? "1 item" : "\(names.count) items"
            return "\(subject) could not be moved to the trash. This can happen on storage that has no trash of its own."
        }
    }
}
