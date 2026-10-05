import Foundation

/// How aggressively the scanner is willing to call two items duplicates.
///
/// Each level maps to a set of thresholds in `Tuning`. The levels are ordered:
/// everything `.exact` finds is also found by `.strict`, and everything `.strict`
/// finds is also found by `.similar`.
enum Sensitivity: Int, Codable, Sendable, CaseIterable, Identifiable {
    /// Byte-for-byte or visually indistinguishable copies. Re-saves, exports,
    /// AirDropped copies, "save to camera roll" duplicates.
    case exact = 0

    /// Near-identical frames: the same shot resized, recompressed, lightly
    /// filtered, or saved at a different quality.
    case strict = 1

    /// The same moment: burst frames and several shots of one subject taken close
    /// together in time, plus moderate crops. Everything `.strict` finds, and
    /// additionally near-matches from within the same few minutes.
    case similar = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .exact: "Exact"
        case .strict: "Near-identical"
        case .similar: "Similar scenes"
        }
    }

    var detail: String {
        switch self {
        case .exact:
            "Only true copies — the same image saved more than once. Safest, finds the fewest."
        case .strict:
            "Copies that were resized, recompressed or lightly edited. The recommended balance."
        case .similar:
            "Everything above, plus burst frames and repeated shots of one subject taken within a few minutes of each other."
        }
    }

    var symbolName: String {
        switch self {
        case .exact: "equal.square"
        case .strict: "square.on.square"
        case .similar: "square.stack.3d.down.right"
        }
    }
}

/// User-facing scan configuration, persisted in `UserDefaults`.
struct ScanSettings: Codable, Sendable, Equatable {
    var sensitivity: Sensitivity = .strict
    var includedKinds: Set<MediaKind> = [.photo, .screenshot, .livePhoto, .video]

    static let storageKey = "com.rahil.OneShot.scanSettings"

    static func load() -> ScanSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(ScanSettings.self, from: data)
        else { return ScanSettings() }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}

/// Every threshold the detection pipeline depends on, in one place.
///
/// These are calibrated against a seeded test library; see `README.md` for the
/// measurements. They are `static let` rather than user-facing settings because
/// exposing raw Hamming distances to the user would be meaningless — the
/// `Sensitivity` enum is the user-facing control.
enum Tuning {
    /// Edge length of the working thumbnail. Large enough for a meaningful
    /// sharpness comparison, small enough that decoding is not the bottleneck.
    static let thumbnailEdge = 128

    /// dHash is computed from a (hashEdge + 1) × hashEdge luminance grid.
    static let hashEdge = 8  // → 8 × 8 = 64 bits

    /// A group is labelled a burst only when each frame was captured within this
    /// many seconds of the one before it.
    static let burstWindow: TimeInterval = 10

    /// Aspect ratios differing by more than this fraction are never duplicates,
    /// except at `.similar` where crops are expected.
    static let aspectTolerance = 0.06
    static let aspectToleranceSimilar = 0.30

    /// Frames this uniformly dark or bright are excluded from hash matching —
    /// a blank frame matches every other blank frame and produces useless groups.
    static let degenerateLumaLow: Float = 0.03
    static let degenerateLumaHigh: Float = 0.97

    // MARK: Per-sensitivity thresholds

    /// Two images are accepted as duplicates by either of two routes:
    ///
    /// - **Structure-led** — the hash is within `hashAccept` *and* the colour
    ///   histogram clears `histogramAccept`.
    /// - **Colour-led** — the histogram is at or above `strongHistogram`, which is
    ///   near-perfect, and the hash is within `colourLedHashLimit`.
    ///
    /// The second route exists because measurement showed heavy JPEG recompression
    /// can push a copy of the same photo to Hamming 16 while its colour distribution
    /// stays at 0.97+, whereas genuinely different scenes sat at 0.40–0.52. Colour
    /// turned out to be the more decisive of the two signals, so it gets a route of
    /// its own rather than only ever acting as a veto.
    struct Thresholds: Sendable {
        /// Accept at or below this Hamming distance, given `histogramAccept`.
        let hashAccept: Int
        /// Reject outright above this Hamming distance.
        let hashReject: Int
        /// Minimum histogram intersection for the structure-led accept.
        let histogramAccept: Float
        /// A histogram this strong accepts anything within `colourLedHashLimit`.
        let strongHistogram: Float
        /// Hash ceiling for the colour-led route.
        ///
        /// Bounded separately from `hashReject`, and much more tightly at the looser
        /// sensitivities. Without it, `.similar` merged five unrelated photographs
        /// into one group: its wide `hashReject` of 30 let any pair with a similar
        /// palette through on colour alone.
        let colourLedHashLimit: Int
        /// Below this histogram intersection, reject regardless of hash.
        let histogramFloor: Float
        /// Between accept and reject, ask Qdrant Edge for the pair's shape
        /// similarity and accept only at or above this cosine.
        let shapeAccept: Float
        /// A pair Qdrant Edge finds by nearest-neighbour search alone — including
        /// rotated copies, which the hash cannot see at all — needs a shape
        /// similarity this high *and* `histogramAccept`.
        let neighbourAccept: Float
    }

    static func thresholds(for sensitivity: Sensitivity) -> Thresholds {
        switch sensitivity {
        // `colourLedHashLimit` is held well clear of the 21–29 band where unrelated
        // photographs were measured. It was originally 18 at `.strict`, which sat
        // close enough to 21 that photos merely sharing a palette could link up, and
        // those links chained into very large groups.
        //
        // The shape thresholds sit between two measured bands on the synthetic
        // corpus: every true duplicate scored ≥ 0.995 and no unrelated pair scored
        // above 0.887. `.strict` takes the middle of that gap; `.exact` sits just
        // under the duplicate band. `neighbourAccept` is stricter than
        // `shapeAccept` because those pairs arrive with no hash agreement at all.
        case .exact:
            Thresholds(hashAccept: 4, hashReject: 10, histogramAccept: 0.97,
                       strongHistogram: 0.993, colourLedHashLimit: 8,
                       histogramFloor: 0.95, shapeAccept: 0.98, neighbourAccept: 0.985)
        case .strict:
            Thresholds(hashAccept: 12, hashReject: 20, histogramAccept: 0.90,
                       strongHistogram: 0.985, colourLedHashLimit: 14,
                       histogramFloor: 0.78, shapeAccept: 0.94, neighbourAccept: 0.96)
        // These relaxed values apply ONLY to frames captured within
        // `sameSceneWindow` of each other — see `anytimeThresholds(for:)`.
        case .similar:
            Thresholds(hashAccept: 16, hashReject: 26, histogramAccept: 0.84,
                       strongHistogram: 0.985, colourLedHashLimit: 15,
                       histogramFloor: 0.68, shapeAccept: 0.92, neighbourAccept: 0.96)
        }
    }

    /// The shape similarity every measured true duplicate reached — resized,
    /// recompressed, brightened, blurred and colour-filtered copies alike.
    ///
    /// A grey-zone pair whose colours agree only down at `histogramFloor` must reach
    /// this; one at `histogramAccept` needs only `shapeAccept`; in between, the bar
    /// rises linearly. The less the colours agree, the more exactly the structure has
    /// to match. Without it a flat `shapeAccept` linked frames of a slow cross-fade —
    /// identical layout, drifting colours — and grew the 40-frame chain test's
    /// largest group from 21 to 31.
    static let shapeCopyBand: Float = 0.995

    /// The shape similarity Qdrant Edge must report for a grey-zone pair.
    static func shapeRequired(histogram: Float, thresholds: Thresholds) -> Float {
        guard histogram < thresholds.histogramAccept else { return thresholds.shapeAccept }
        let deficit = (thresholds.histogramAccept - histogram)
            / (thresholds.histogramAccept - thresholds.histogramFloor)
        return thresholds.shapeAccept + min(1, max(0, deficit)) * (shapeCopyBand - thresholds.shapeAccept)
    }

    /// Nearest neighbours requested from Qdrant Edge per photo and orientation.
    ///
    /// Only ever adds to what the exhaustive hash scan found, so it does not need
    /// complete recall: a photo with more near-copies than this already has them
    /// linked by the hash. Kept small because it is paid four times per photo.
    static let neighbourLimit = 12

    /// Neighbour lists are stored once and read at every sensitivity, so they are
    /// searched at the loosest bar any sensitivity applies.
    static var neighbourFloor: Float {
        Sensitivity.allCases.map { anytimeThresholds(for: $0).neighbourAccept }.min() ?? 0.96
    }

    /// HNSW search width (`ef`) for the neighbour search. Measured on 20,000 shapes:
    /// 64 found every photo's own shape at half the cost of Qdrant's default; 32
    /// missed 0.5% and 16 missed 4%. The pairs sought score 0.96 or more, far closer
    /// than anything a narrow search would confuse them with.
    static let neighbourSearchWidth = 64

    /// Thresholds that apply regardless of when two frames were captured.
    ///
    /// `.similar` deliberately reuses the `.strict` values here. Its extra reach is
    /// meant for burst frames and re-shoots of one subject, which happen seconds or
    /// minutes apart — applying relaxed visual thresholds across an entire library
    /// instead produced groups of forty unrelated photos. A Hamming distance of 18
    /// out of 64 plus a chromaticity match of 0.78 describes a huge share of ordinary
    /// photographs: anything with bright sky above and dark ground below matches
    /// anything else with the same gross composition.
    ///
    /// So `.similar` is now `.strict` plus a *temporal* route, rather than `.strict`
    /// with the guardrails removed.
    static func anytimeThresholds(for sensitivity: Sensitivity) -> Thresholds {
        sensitivity == .similar ? thresholds(for: .strict) : thresholds(for: sensitivity)
    }

    /// How far apart two frames can be captured and still count as the same scene.
    ///
    /// Bursts are sub-second; deliberately re-taking a shot of the same subject is a
    /// matter of seconds to a couple of minutes. Beyond that the two photographs are
    /// separate moments, and only the anytime thresholds should be able to link them.
    static let sameSceneWindow: TimeInterval = 180

    /// Largest group the refiner will build.
    ///
    /// A group of several hundred photos cannot be reviewed, so past this point the
    /// least similar members are handed to the next anchor instead of being piled
    /// onto one enormous card.
    static let maxGroupSize = 60

    /// Screenshots of the same app share their status bar, navigation chrome and
    /// palette, so the colour histogram says almost nothing about their *content* —
    /// two completely different screens routinely score above 0.98. Comparing a
    /// screenshot to a screenshot therefore ignores the colour-led shortcut entirely
    /// and demands real structural agreement.
    static let screenshotHashAccept = 6
    static let screenshotHistogramAccept: Float = 0.94

    /// Two frames whose mean luminance differs by more than this are never the same
    /// picture, however well their other signals agree.
    ///
    /// This is what keeps a blank white frame apart from a blank black one: both
    /// have an all-zero hash and both land in the achromatic centre of the
    /// chromaticity histogram, so luminance is the only thing that separates them.
    static let lumaTolerance: Float = 0.12

    // MARK: Video

    /// Keyframes sampled per video, spread across its duration.
    static let videoKeyframeCount = 5
    /// Durations must match within this fraction (or `videoDurationAbsolute`,
    /// whichever is more forgiving) before frames are compared at all.
    static let videoDurationTolerance = 0.05
    static let videoDurationAbsolute: TimeInterval = 1.0
    /// Mean per-keyframe Hamming distance below which two videos are duplicates.
    static func videoHashAccept(for sensitivity: Sensitivity) -> Double {
        switch sensitivity {
        case .exact: 3
        case .strict: 8
        case .similar: 14
        }
    }
}
