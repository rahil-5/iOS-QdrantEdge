import Foundation

/// The kinds of library item OneShot knows how to compare.
///
/// These are deliberately coarser than `PHAssetMediaSubtype`: what matters to the
/// scanner is which comparison pipeline an item goes through (still vs. video) and
/// how it should be presented and scored.
enum MediaKind: Int, Codable, Sendable, CaseIterable, Identifiable {
    case photo = 0
    case screenshot = 1
    case livePhoto = 2
    case video = 3

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .photo: "Photos"
        case .screenshot: "Screenshots"
        case .livePhoto: "Live Photos"
        case .video: "Videos"
        }
    }

    var singularName: String {
        switch self {
        case .photo: "Photo"
        case .screenshot: "Screenshot"
        case .livePhoto: "Live Photo"
        case .video: "Video"
        }
    }

    var symbolName: String {
        switch self {
        case .photo: "photo"
        case .screenshot: "iphone"
        case .livePhoto: "livephoto"
        case .video: "video"
        }
    }

    /// Stills share the single-frame fingerprinting path; video samples keyframes.
    var isStill: Bool { self != .video }
}

/// A `Sendable` snapshot of everything the engine needs to know about a library item.
///
/// `PHAsset` is a non-`Sendable` reference type owned by PhotoKit, so the scanner
/// never carries one across a concurrency boundary. It flattens each asset into this
/// value type once, up front, and re-fetches the `PHAsset` by `id` only at the two
/// points where PhotoKit is genuinely required: loading pixels and deleting.
struct AssetRecord: Sendable, Identifiable, Hashable {
    /// `PHAsset.localIdentifier` — stable for the lifetime of the asset on device.
    let id: String
    let kind: MediaKind
    let pixelWidth: Int
    let pixelHeight: Int
    let creationDate: Date?
    let modificationDate: Date?
    /// Seconds. Zero for stills.
    let duration: TimeInterval
    let isFavorite: Bool
    /// Non-nil when the shot came from a burst; all frames of one burst share it.
    let burstIdentifier: String?
    /// True when the user has edited the asset (an adjustment-data resource exists).
    /// Starts `false` and is filled in by `PhotoLibraryService.enrich(_:)` for the
    /// assets that actually land in a group.
    var isEdited: Bool
    /// True for HDR stills.
    let isHDR: Bool
    /// Byte size on disk — an estimate from dimensions during indexing, replaced
    /// with the true size by `PhotoLibraryService.enrich(_:)` for grouped assets.
    var byteSize: Int64

    var pixelCount: Int { pixelWidth * pixelHeight }

    /// Width over height, orientation-normalised so a portrait and landscape copy of
    /// the same crop compare equal.
    var aspectRatio: Double {
        guard pixelWidth > 0, pixelHeight > 0 else { return 1 }
        let ratio = Double(pixelWidth) / Double(pixelHeight)
        return ratio < 1 ? 1 / ratio : ratio
    }

    var resolutionLabel: String {
        "\(pixelWidth) × \(pixelHeight)"
    }
}

extension Int64 {
    /// Human-readable byte count, matching the style iOS uses in Settings.
    var formattedBytes: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
