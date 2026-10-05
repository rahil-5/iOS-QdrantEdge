import Foundation

/// An asset paired with its fingerprint, in one value so the comparison phase can
/// reject on metadata (aspect ratio, timestamp, kind) without a second lookup.
struct IndexedAsset: Sendable {
    let record: AssetRecord
    let fingerprint: Fingerprint
}

/// A pair worth examining closely, with the cheap signals already measured.
struct CandidatePair: Sendable, Hashable {
    let firstIndex: Int
    let secondIndex: Int
    let hashDistance: Int
    let histogramSimilarity: Float
}

/// Finds the pairs worth comparing properly.
///
/// This started out as banded locality-sensitive hashing — splitting each 64-bit
/// dHash into eight 8-bit bands and only comparing assets that collide in a band.
/// Measuring it against a library with known duplicates showed why that was the
/// wrong call: real duplicates land at Hamming distances of 8 to 16, and at those
/// distances banding only surfaces 57–70% of pairs. A five-member group survived
/// because its ten pairs gave it ten chances to collide, but a plain two-photo
/// duplicate had exactly one chance and was silently missed.
///
/// So the comparison is exhaustive instead. That sounds expensive — 30,000 photos
/// is 450 million pairs — but each pair is an XOR, a popcount and a compare over
/// flat arrays that sit in cache, which runs in about a second across cores. The
/// scan already spends minutes decoding images; a second here buys complete recall,
/// which is not a trade worth making the other way.
///
/// The expensive signal, histogram intersection over 64 bins, is only computed for
/// the few pairs that survive the hash test.
enum CandidateIndex {

    /// Builds the candidate set for still images.
    static func stillCandidates(
        in assets: [IndexedAsset],
        sensitivity: Sensitivity,
        onProgress: @escaping @Sendable (Int, Int) -> Void
    ) async -> [CandidatePair] {
        let positions = assets.indices.filter { assets[$0].record.kind.isStill }
        let count = positions.count
        guard count > 1 else { return [] }

        let thresholds = Tuning.thresholds(for: sensitivity)
        let aspectTolerance = sensitivity == .similar
            ? Tuning.aspectToleranceSimilar
            : Tuning.aspectTolerance

        // Flat, contiguous arrays: the inner loop touches these millions of times,
        // and pulling them out of the struct array keeps the hot data in cache.
        let hashes = positions.map { assets[$0].fingerprint.dHash }
        let lumas = positions.map { assets[$0].fingerprint.meanLuma }
        let aspects = positions.map { assets[$0].record.aspectRatio }
        let histograms = positions.map { assets[$0].fingerprint.histogram }

        // Rows early in the matrix do far more work than late ones, so the chunks
        // are kept small enough that the imbalance evens out across cores.
        let cores = max(2, ProcessInfo.processInfo.activeProcessorCount)
        let chunkSize = max(32, count / (cores * 8))
        let chunkCount = (count + chunkSize - 1) / chunkSize

        return await withTaskGroup(of: [CandidatePair].self) { group in
            var start = 0
            while start < count {
                let lower = start
                let upper = min(count, start + chunkSize)
                group.addTask(priority: .userInitiated) {
                    var local: [CandidatePair] = []
                    for outer in lower..<upper {
                        let outerLuma = lumas[outer]
                        let outerAspect = aspects[outer]
                        let outerHash = hashes[outer]

                        for inner in (outer + 1)..<count {
                            // Cheapest rejections first. Luminance and aspect are a
                            // single compare each and throw out the vast majority.
                            if abs(outerLuma - lumas[inner]) > Tuning.lumaTolerance { continue }

                            let innerAspect = aspects[inner]
                            let delta = abs(outerAspect - innerAspect) / max(outerAspect, innerAspect)
                            if delta > aspectTolerance { continue }

                            let distance = outerHash.hammingDistance(to: hashes[inner])
                            if distance > thresholds.hashReject { continue }

                            // Only now is the 64-bin histogram worth touching.
                            let similarity = histograms[outer].similarity(to: histograms[inner])
                            if similarity < thresholds.histogramFloor { continue }

                            local.append(CandidatePair(
                                firstIndex: positions[outer],
                                secondIndex: positions[inner],
                                hashDistance: distance,
                                histogramSimilarity: similarity
                            ))
                        }
                    }
                    return local
                }
                start = upper
            }

            var all: [CandidatePair] = []
            var completed = 0
            for await chunk in group {
                all.append(contentsOf: chunk)
                completed += 1
                onProgress(completed, chunkCount)
            }
            return all
        }
    }

    // MARK: - Video

    /// Builds candidate pairs for video.
    ///
    /// Video libraries are orders of magnitude smaller than photo libraries, so this
    /// buckets by duration — two clips of different lengths are never the same clip
    /// — and compares within buckets. The comparison itself is the mean per-keyframe
    /// Hamming distance, which is far more discriminating than a single frame.
    static func videoCandidates(
        in assets: [IndexedAsset],
        sensitivity: Sensitivity
    ) -> [CandidatePair] {
        let videoIndices = assets.indices.filter { !assets[$0].record.kind.isStill }
        guard videoIndices.count > 1 else { return [] }

        let accept = Tuning.videoHashAccept(for: sensitivity)
        var results: [CandidatePair] = []

        // Duration buckets one second wide, checking the neighbouring bucket too so
        // a clip on a boundary still meets its counterpart.
        var buckets: [Int: [Int]] = [:]
        for index in videoIndices {
            buckets[Int(assets[index].record.duration), default: []].append(index)
        }

        var seen = Set<IndexPair>()
        for (bucket, members) in buckets {
            var pool = members
            if let neighbours = buckets[bucket + 1] { pool += neighbours }
            guard pool.count > 1 else { continue }

            for outer in 0..<(pool.count - 1) {
                for inner in (outer + 1)..<pool.count {
                    let key = IndexPair(pool[outer], pool[inner])
                    guard !seen.contains(key) else { continue }
                    seen.insert(key)

                    let first = assets[pool[outer]]
                    let second = assets[pool[inner]]
                    guard durationsMatch(first.record.duration, second.record.duration) else { continue }

                    guard let meanDistance = meanKeyframeDistance(
                        first.fingerprint.keyframeHashes,
                        second.fingerprint.keyframeHashes
                    ), meanDistance <= accept else { continue }

                    let similarity = first.fingerprint.histogram.similarity(to: second.fingerprint.histogram)
                    results.append(CandidatePair(
                        firstIndex: pool[outer],
                        secondIndex: pool[inner],
                        hashDistance: Int(meanDistance.rounded()),
                        histogramSimilarity: similarity
                    ))
                }
            }
        }
        return results
    }

    private struct IndexPair: Hashable {
        let low: Int
        let high: Int
        init(_ a: Int, _ b: Int) {
            if a < b { low = a; high = b } else { low = b; high = a }
        }
    }

    private static func durationsMatch(_ first: TimeInterval, _ second: TimeInterval) -> Bool {
        let delta = abs(first - second)
        let relative = delta / max(first, second, 0.001)
        return delta <= Tuning.videoDurationAbsolute || relative <= Tuning.videoDurationTolerance
    }

    /// Mean Hamming distance across aligned keyframes.
    ///
    /// Compares position by position because both videos were sampled at the same
    /// fractions of their duration, so frame *i* of one corresponds to frame *i* of
    /// the other even when the clips are different absolute lengths.
    private static func meanKeyframeDistance(_ first: [UInt64], _ second: [UInt64]) -> Double? {
        let count = min(first.count, second.count)
        guard count > 0 else { return nil }
        var total = 0
        for index in 0..<count {
            total += first[index].hammingDistance(to: second[index])
        }
        return Double(total) / Double(count)
    }
}
