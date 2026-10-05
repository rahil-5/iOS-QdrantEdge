import Foundation
import Photos
import AVFoundation
import CoreGraphics

/// Fingerprints video by sampling keyframes and hashing each one.
///
/// A video's "shape" over time is what distinguishes it: two clips of the same
/// length whose frames at 10%, 30%, 50%, 70% and 90% all hash alike are the same
/// clip, even if one was re-encoded at a different bitrate. Sampling by *fraction*
/// rather than absolute time means a trimmed-and-re-exported copy still lines up.
enum VideoFingerprinter {

    struct VideoSample: Sendable {
        let keyframeHashes: [UInt64]
        /// The middle frame, reused for the colour histogram and quality metrics so
        /// video gets the same scoring treatment as stills.
        let representativeFrame: ThumbnailData
    }

    /// Samples and hashes a video's keyframes. Returns nil if the video is not
    /// present on this device or cannot be read.
    static func sample(assetID: String, frameCount: Int = Tuning.videoKeyframeCount) async -> VideoSample? {
        // Unwrapped here and never passed on: the `AVAsset` stays local to this
        // function, so it never crosses an isolation boundary.
        guard let avAsset = await loadAVAsset(for: assetID).value else { return nil }

        let duration: TimeInterval
        do {
            duration = try await CMTimeGetSeconds(avAsset.load(.duration))
        } catch {
            return nil
        }
        guard duration.isFinite, duration > 0 else { return nil }

        let generator = AVAssetImageGenerator(asset: avAsset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 512, height: 512)
        // A quarter-second of slop lets the generator snap to a nearby sync sample
        // instead of decoding forward to an exact frame, which is an order of
        // magnitude faster and does not meaningfully change the hash.
        let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        var hashes: [UInt64] = []
        var middleFrame: ThumbnailData?
        var firstFrame: ThumbnailData?

        for index in 0..<frameCount {
            // Evenly spaced across the interior, avoiding the very first and last
            // frames which are often black or a fade.
            let fraction = Double(index + 1) / Double(frameCount + 1)
            let time = CMTime(seconds: duration * fraction, preferredTimescale: 600)

            guard let cgImage = try? await generator.image(at: time).image,
                  let thumbnail = ThumbnailData(cgImage: cgImage, edge: Tuning.thumbnailEdge)
            else { continue }
            let luma = Fingerprinter.luminance(from: thumbnail)
            hashes.append(Fingerprinter.differenceHash(from: luma, edge: thumbnail.edge))

            if index == frameCount / 2 {
                middleFrame = thumbnail
            }
            if firstFrame == nil {
                firstFrame = thumbnail
            }
        }

        // Prefer the middle frame, but any successfully decoded frame is better
        // than discarding the video entirely when one seek happens to fail.
        guard !hashes.isEmpty, let representative = middleFrame ?? firstFrame else { return nil }
        return VideoSample(keyframeHashes: hashes, representativeFrame: representative)
    }

    /// Bridges PhotoKit's callback API to async, without letting a non-`Sendable`
    /// `AVAsset` escape unguarded.
    ///
    /// Returns the box rather than the asset: the return value crosses back out of an
    /// async call, which Swift 6 requires to be `Sendable`. The caller unwraps it
    /// immediately and keeps the asset local.
    private static func loadAVAsset(for assetID: String) async -> UncheckedBox<AVAsset?> {
        // A clip in a folder is already a file: no PhotoKit round trip, and no
        // question of whether its pixels are still in iCloud.
        if AssetLoader.isFile(assetID), let url = URL(string: assetID) {
            return UncheckedBox(AVURLAsset(url: url))
        }

        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
        guard fetched.count > 0 else { return UncheckedBox(nil) }
        let asset = fetched.object(at: 0)

        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .fastFormat
        options.version = .current

        return await withCheckedContinuation { continuation in
            let guarded = ResumeGuard(continuation)
            PHImageManager.default().requestAVAsset(
                forVideo: asset,
                options: options
            ) { avAsset, _, _ in
                guarded.resume(UncheckedBox(avAsset))
            }
        }
    }
}

/// Carries a non-`Sendable` value across a continuation.
///
/// `AVAsset` is documented as safe to read from any thread — `AVAssetImageGenerator`
/// exists specifically to be driven off the main thread — but it is not marked
/// `Sendable`. The box is unwrapped immediately by a single consumer and never
/// shared, so the guarantee holds.
struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Ensures a continuation resumes exactly once even if PhotoKit calls back twice.
private final class ResumeGuard<T: Sendable>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, Never>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
