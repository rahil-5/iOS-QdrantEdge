import SwiftUI
import UIKit

/// In-memory thumbnail cache for the review UI.
///
/// Scrolling a grid of duplicates re-requests the same assets constantly as cells
/// recycle. `NSCache` handles the eviction under memory pressure, which matters here
/// because the user may be looking at hundreds of full-colour thumbnails.
@MainActor
final class ThumbnailProvider {
    static let shared = ThumbnailProvider()

    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    private init() {
        cache.countLimit = 400
    }

    func image(for assetID: String, edge: CGFloat) async -> UIImage? {
        // Quantise the requested size so a grid and a detail view don't thrash the
        // cache with near-identical entries.
        let bucket = Int((edge / 100).rounded(.up)) * 100
        let key = "\(assetID)@\(bucket)" as NSString

        if let cached = cache.object(forKey: key) { return cached }
        if let existing = inFlight[key as String] { return await existing.value }

        let task = Task<UIImage?, Never> {
            // `allowNetwork: false` throughout: anything in the results was already
            // fingerprinted from local pixels, so the network is never needed.
            await AssetLoader.loadPreview(
                for: assetID,
                targetSize: CGSize(width: bucket, height: bucket),
                allowNetwork: false
            )
        }
        inFlight[key as String] = task
        let image = await task.value
        inFlight[key as String] = nil

        if let image { cache.setObject(image, forKey: key) }
        return image
    }
}

/// A photo library asset rendered as a square, filling its frame.
struct AssetImage: View {
    let assetID: String
    var edge: CGFloat = 240

    @State private var image: UIImage?
    @State private var didFail = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Rectangle()
                    .fill(.quaternary)

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else if didFail {
                    Image(systemName: "photo")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .task(id: assetID) {
                let loaded = await ThumbnailProvider.shared.image(
                    for: assetID,
                    edge: max(edge, proxy.size.width * 2)
                )
                withAnimation(.easeOut(duration: 0.18)) {
                    image = loaded
                    didFail = loaded == nil
                }
            }
        }
    }
}

/// Small overlay badges shown on a thumbnail — duration for video, the Live Photo
/// mark, a favourite heart.
struct AssetBadges: View {
    let record: AssetRecord

    /// An ordinary photo has nothing to say here. Without this check the capsule
    /// still rendered, leaving a small empty pill floating on the image.
    private var hasAnything: Bool {
        record.isFavorite || record.kind == .livePhoto || record.kind == .video
    }

    var body: some View {
        if hasAnything {
            HStack(spacing: 4) {
                if record.isFavorite {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.pink)
                }
                if record.kind == .livePhoto {
                    Image(systemName: "livephoto")
                }
                if record.kind == .video {
                    Image(systemName: "video.fill")
                    Text(Self.durationText(record.duration))
                }
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.black.opacity(0.45), in: Capsule())
        }
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
