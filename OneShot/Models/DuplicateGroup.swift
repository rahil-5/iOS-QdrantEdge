import Foundation

/// A single reason one asset beat the others in its group, shown as a chip under
/// the keeper so the pick is never a black box.
enum QualityHighlight: String, Sendable, Hashable, CaseIterable {
    case sharpest = "Sharpest"
    case highestResolution = "Highest resolution"
    case bestExposure = "Best exposure"
    case eyesOpen = "Eyes open"
    case mostFaces = "Most faces"
    case favourite = "Favourite"
    case largestFile = "Largest file"
    case edited = "Your edit"
    case livePhoto = "Live Photo"
    case highDynamicRange = "HDR"
    case original = "Original, not a copy"

    var symbolName: String {
        switch self {
        case .sharpest: "camera.aperture"
        case .highestResolution: "arrow.up.left.and.arrow.down.right"
        case .bestExposure: "sun.max"
        case .eyesOpen: "eye"
        case .mostFaces: "person.2"
        case .favourite: "heart.fill"
        case .largestFile: "internaldrive"
        case .edited: "slider.horizontal.3"
        case .livePhoto: "livephoto"
        case .highDynamicRange: "sparkles"
        case .original: "checkmark.seal"
        }
    }
}

/// An asset together with the quality score that decided its rank inside a group.
struct ScoredAsset: Sendable, Identifiable, Hashable {
    let record: AssetRecord
    /// Higher is better. Only comparable within the same group — the scorer
    /// normalises each component against that group's own range.
    let score: Double
    /// Why this asset scored well. Empty for assets that won nothing.
    let highlights: [QualityHighlight]

    var id: String { record.id }
}

/// A set of items the scanner believes are the same picture, with one nominated
/// keeper.
///
/// The keeper is a recommendation, not a decision: `GroupReview` tracks what the
/// user has actually chosen and nothing is deleted without their confirmation.
struct DuplicateGroup: Sendable, Identifiable, Hashable {
    let id: UUID
    /// Sorted best-first. Always at least two members.
    let members: [ScoredAsset]
    /// `members.first` — the recommended keep.
    let keeperID: String
    /// The dominant kind in the group, used for filtering and section headers.
    let kind: MediaKind
    /// True for a camera burst rather than a set of copies — see
    /// `DuplicateScanner.isBurst(_:)` for what that requires.
    let isBurst: Bool
    /// Mean pairwise confidence, 0…1. Drives the "how sure is it" badge.
    let confidence: Double

    init(members: [ScoredAsset], kind: MediaKind, isBurst: Bool, confidence: Double) {
        precondition(members.count >= 2, "a duplicate group needs at least two members")
        let ordered = members.sorted { $0.score > $1.score }
        self.id = UUID()
        self.members = ordered
        self.keeperID = ordered[0].id
        self.kind = kind
        self.isBurst = isBurst
        self.confidence = confidence
    }

    var keeper: ScoredAsset {
        // Safe: `init` guarantees a non-empty, ordered `members`.
        members[0]
    }

    var duplicates: [ScoredAsset] {
        Array(members.dropFirst())
    }

    /// Bytes freed if every member except the keeper is deleted.
    var reclaimableBytes: Int64 {
        duplicates.reduce(0) { $0 + $1.record.byteSize }
    }

    var confidenceLabel: String {
        switch confidence {
        case 0.92...: "Certain"
        case 0.75..<0.92: "Very likely"
        default: "Possible"
        }
    }
}

/// The complete result of one scan.
struct ScanResult: Sendable {
    let groups: [DuplicateGroup]
    /// Total items examined.
    let assetsScanned: Int
    /// Items skipped because their pixels live only in iCloud and OneShot never
    /// uses the network. Surfaced to the user so the count is never silently wrong.
    let skippedNotDownloaded: Int
    /// Items skipped because they failed to decode.
    let skippedUnreadable: Int
    let duration: TimeInterval
    let sensitivity: Sensitivity

    static let empty = ScanResult(groups: [], assetsScanned: 0, skippedNotDownloaded: 0,
                                  skippedUnreadable: 0, duration: 0, sensitivity: .strict)

    var duplicateCount: Int {
        groups.reduce(0) { $0 + $1.duplicates.count }
    }

    var reclaimableBytes: Int64 {
        groups.reduce(0) { $0 + $1.reclaimableBytes }
    }
}
