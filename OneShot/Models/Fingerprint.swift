import Foundation

/// Everything the scanner derives from one asset's pixels, in a form small enough to
/// keep the whole library resident in memory and cheap enough to persist between runs.
///
/// A 30,000-item library costs roughly 40 MB of these, most of it the shape
/// signature, which is what makes the comparison phase fast: after the fingerprint
/// pass, no further image decoding is needed to find duplicates.
struct Fingerprint: Sendable, Hashable {
    /// Matches `AssetRecord.id`.
    let assetID: String

    /// 64-bit difference hash of the luminance channel. Robust to rescaling,
    /// re-compression and small colour shifts; sensitive to crops and rotation.
    let dHash: UInt64

    /// Normalised 8×8 chromaticity histogram (64 bins summing to 1). This is the
    /// "proportion of pixel colours" signal — it catches filtered and
    /// brightness-adjusted copies whose structure is unchanged.
    let histogram: HistogramSignature

    /// Where the edges are, as a unit vector. This is what Qdrant Edge stores and
    /// searches; see `ShapeSignature`.
    let shape: ShapeSignature

    /// Variance of the Laplacian over the luminance channel. Higher is sharper.
    /// Only meaningful relative to other members of the same duplicate group.
    let sharpness: Float

    /// 0…1, where 1 is a well-exposed frame. Penalises clipped highlights and
    /// crushed shadows.
    let exposure: Float

    /// Mean luminance, 0…1. Used to reject the degenerate all-black / all-white
    /// frames that would otherwise match everything.
    let meanLuma: Float

    /// For video only: one dHash per sampled keyframe, in playback order.
    /// Empty for stills.
    let keyframeHashes: [UInt64]

    /// `modificationDate` at the time of fingerprinting, used to invalidate the
    /// on-disk cache when an asset is edited.
    let stamp: Double

    var isVideo: Bool { !keyframeHashes.isEmpty }
}

/// A fixed-size colour histogram with a fast similarity metric.
///
/// Binned over *chromaticity* — r/(r+g+b) and g/(r+g+b) — rather than raw RGB.
/// That choice is what makes the signal survive an exposure change: brightening a
/// photo scales all three channels together, which leaves chromaticity untouched
/// but moves every raw RGB value into a different bin. An RGB histogram scored a
/// brightened copy at 0.50 against its own original; chromaticity scores it ~1.0.
///
/// The cost is that luminance is discarded, so a black frame and a white frame
/// both land in the achromatic centre. `Fingerprint.meanLuma` is compared
/// separately to keep those apart.
///
/// Comparison uses histogram intersection: cheap, bounded to 0…1, and well behaved
/// when one image is a recompressed copy of the other.
struct HistogramSignature: Sendable, Hashable {
    /// Bins along each chromaticity axis.
    static let axisBins = 8
    static let binCount = axisBins * axisBins  // 64

    private(set) var bins: [Float]

    init(bins: [Float]) {
        precondition(bins.count == Self.binCount, "histogram must have \(Self.binCount) bins")
        self.bins = bins
    }

    /// Histogram intersection: 1.0 for identical distributions, 0.0 for disjoint.
    func similarity(to other: HistogramSignature) -> Float {
        var total: Float = 0
        for index in 0..<Self.binCount {
            total += min(bins[index], other.bins[index])
        }
        return total
    }
}

/// Luminance gradients on a 16×16 grid, normalised to a unit vector.
///
/// This replaced Apple's Vision feature print as the signal for pairs the hash and
/// histogram cannot decide, and it is the vector Qdrant Edge indexes. It is a
/// real-valued, finer-grained relative of dHash: dHash keeps one *bit* per cell —
/// "is the right neighbour brighter?" — so in flat regions such as sky, where
/// neighbours are nearly equal, its bits flip on compression noise. That is most of
/// why true duplicates sit at Hamming 8–16. Here a flat region contributes almost
/// nothing to the cosine, so noise barely moves it.
///
/// Measured on the synthetic corpus: true duplicates (resized, JPEG q25,
/// brightened, a blurred burst frame) all score ≥ 0.995, while the closest of
/// ~1,500 unrelated pairs scores 0.887 and the 99th percentile 0.78. A 16×16
/// *luminance* grid, or low DCT coefficients, scored unrelated photos above 0.98 —
/// both are dominated by the shared "bright sky over dark ground" layout, the same
/// trap described for dHash in the README. Gradients cancel that layout out.
///
/// It is invariant to brightness and contrast (gradients drop the offset, the
/// normalisation drops the gain), and it is deliberately *not* mean-centred: that
/// keeps a quarter-turn of the image an exact signed permutation of the vector, so
/// rotated copies can be searched for without decoding anything again.
struct ShapeSignature: Sendable, Hashable {
    static let gridEdge = 16
    /// Horizontal then vertical differences: 16×15 + 15×16.
    static let dimensions = 2 * gridEdge * (gridEdge - 1)  // 480

    /// Unit length, or all zeros for a frame with no structure at all. Half
    /// precision, which moved no measured similarity by more than 0.001 and halves
    /// the memory a large library holds during a scan.
    let components: [Float16]

    init(components: [Float16]) {
        precondition(components.count == Self.dimensions, "shape must have \(Self.dimensions) components")
        self.components = components
    }

    init(vector: [Float]) {
        self.init(components: vector.map { Float16($0) })
    }

    /// Full-precision copy, the form Qdrant Edge takes.
    var vector: [Float] { components.map { Float($0) } }

    /// A blank frame has no gradients to compare. It has its own rules in the
    /// verifier and is never indexed, since a zero vector has no direction.
    var isBlank: Bool { components.allSatisfy { $0 == 0 } }

    /// Cosine similarity: 1 for the same structure, around 0 for unrelated.
    func similarity(to other: ShapeSignature) -> Float {
        var total: Float = 0
        for index in 0..<Self.dimensions {
            total += Float(components[index]) * Float(other.components[index])
        }
        return total
    }

    /// The signature the image would have after `quarterTurns` clockwise
    /// rotations, derived without the pixels.
    ///
    /// The thumbnail is squashed to a square before analysis, and squashing commutes
    /// with a quarter-turn, so a portrait copy of a landscape photo produces exactly
    /// the rotated grid of the original.
    func rotated(quarterTurns: Int) -> [Float] {
        var current = vector
        guard quarterTurns % 4 != 0 else { return current }
        for _ in 0..<(((quarterTurns % 4) + 4) % 4) {
            var next = [Float](repeating: 0, count: Self.dimensions)
            for (target, source) in Self.quarterTurn.enumerated() {
                next[target] = source.negate ? -current[source.index] : current[source.index]
            }
            current = next
        }
        return current
    }

    /// For each component of a quarter-turned signature, which component of the
    /// original it comes from. Rotating the grid by g'[r][c] = g[n−1−c][r] turns
    /// each horizontal difference into a negated vertical one, and each vertical
    /// difference into a horizontal one.
    private static let quarterTurn: [(index: Int, negate: Bool)] = {
        let n = gridEdge
        let verticalBase = n * (n - 1)
        var table: [(index: Int, negate: Bool)] = []
        table.reserveCapacity(dimensions)
        // H'[r][c] = −V[n−2−c][r]
        for row in 0..<n {
            for column in 0..<(n - 1) {
                table.append((verticalBase + (n - 2 - column) * n + row, true))
            }
        }
        // V'[r][c] = H[n−1−c][r]
        for row in 0..<(n - 1) {
            for column in 0..<n {
                table.append(((n - 1 - column) * (n - 1) + row, false))
            }
        }
        return table
    }()
}

// MARK: - Hash distance

extension UInt64 {
    /// Number of differing bits — the Hamming distance between two perceptual
    /// hashes. 0 means the downsampled luminance gradients are identical.
    @inline(__always)
    func hammingDistance(to other: UInt64) -> Int {
        (self ^ other).nonzeroBitCount
    }
}
