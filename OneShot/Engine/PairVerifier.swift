import Foundation
import Synchronization

/// A cancel request that concurrent work can poll without awaiting an actor.
final class CancellationFlag: Sendable {
    private let state = Mutex(false)
    var isSet: Bool { state.withLock { $0 } }
    func set(_ value: Bool) { state.withLock { $0 = value } }
}

/// A pair accepted as duplicates, with how sure the verifier is.
struct ConfirmedPair: Sendable {
    let firstIndex: Int
    let secondIndex: Int
    let confidence: Double
}

/// Identifies a pair of asset indices regardless of order.
struct PairKey: Hashable, Sendable {
    let low: Int
    let high: Int
    init(_ a: Int, _ b: Int) {
        if a < b { low = a; high = b } else { low = b; high = a }
    }
}

/// Turns candidate pairs into confirmed ones.
///
/// Three stages, cheapest first:
///
/// 1. **Direct** — the hash and histogram routes. Most pairs are decided here, by
///    arithmetic over values already in memory.
/// 2. **Grey zone** — pairs structurally close but not certain are scored by Qdrant
///    Edge on their shape signatures.
/// 3. **Neighbours** — Qdrant Edge searches the whole library for each photo's
///    nearest shapes, in all four orientations, finding pairs the hash scan cannot:
///    rotated copies, and copies whose hash bits were scattered by noise.
///
/// Kept apart from the scanner so tests run exactly the code the app runs, against a
/// real Qdrant Edge shard.
enum PairVerifier {

    static func verify(
        _ candidates: [CandidatePair],
        in assets: [IndexedAsset],
        sensitivity: Sensitivity,
        vectors: VectorIndex,
        cancellation: CancellationFlag? = nil,
        onProgress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) async -> [ConfirmedPair] {
        let direct = directRoutes(candidates, in: assets, sensitivity: sensitivity)
        var confirmed = direct.confirmed
        confirmed += await resolveGreyZone(direct.greyZone, in: assets, vectors: vectors,
                                           cancellation: cancellation, onProgress: onProgress)

        let known = Set(confirmed.map { PairKey($0.firstIndex, $0.secondIndex) })
        confirmed += await neighbours(in: assets, sensitivity: sensitivity, vectors: vectors, excluding: known,
                                      cancellation: cancellation, onProgress: onProgress)
        return confirmed
    }

    // MARK: - Direct routes

    /// A pair awaiting Qdrant's shape score, with the threshold its route allows.
    struct Escalation: Sendable {
        let pair: CandidatePair
        let accept: Float
    }

    static func directRoutes(
        _ candidates: [CandidatePair],
        in assets: [IndexedAsset],
        sensitivity: Sensitivity
    ) -> (confirmed: [ConfirmedPair], greyZone: [Escalation]) {
        let thresholds = Tuning.thresholds(for: sensitivity)
        // `.similar` reaches further than `.strict`, but only for frames from the
        // same moment. Everything else is judged by the anytime thresholds.
        let anytime = Tuning.anytimeThresholds(for: sensitivity)
        let hasTemporalRoute = sensitivity == .similar

        var confirmed: [ConfirmedPair] = []
        var greyZone: [Escalation] = []

        for pair in candidates {
            let first = assets[pair.firstIndex].fingerprint
            let second = assets[pair.secondIndex].fingerprint

            // A blank or blown-out frame matches every other blank frame. Without
            // this guard, a library with thirty accidental black photos produces one
            // enormous bogus group. Such frames must match essentially exactly, and
            // at the same brightness — the candidate stage has already checked that
            // their mean luminance agrees.
            if isDegenerate(first) || isDegenerate(second) {
                if pair.hashDistance == 0 && pair.histogramSimilarity >= 0.98 {
                    confirmed.append(ConfirmedPair(firstIndex: pair.firstIndex,
                                                   secondIndex: pair.secondIndex,
                                                   confidence: 0.95))
                }
                continue
            }

            // Two screenshots are judged on structure alone. Their colour histograms
            // are dominated by shared app chrome rather than content, so the
            // colour-led shortcut would link unrelated screens — and a library with
            // hundreds of screenshots is exactly where that becomes a runaway group.
            let bothScreenshots = assets[pair.firstIndex].record.kind == .screenshot
                && assets[pair.secondIndex].record.kind == .screenshot

            let comparable = !first.isVideo && !second.isVideo

            // Route 1 — holds whatever the timestamps say.
            if accepts(pair, using: anytime, bothScreenshots: bothScreenshots) {
                confirmed.append(ConfirmedPair(
                    firstIndex: pair.firstIndex,
                    secondIndex: pair.secondIndex,
                    confidence: confidence(hashDistance: pair.hashDistance,
                                           histogram: pair.histogramSimilarity)
                ))
                continue
            }

            // Route 2 — the relaxed thresholds, for frames from the same moment only.
            let sameMoment = hasTemporalRoute && isSameMoment(
                assets[pair.firstIndex].record,
                assets[pair.secondIndex].record
            )

            if sameMoment,
               accepts(pair, using: thresholds, bothScreenshots: bothScreenshots) {
                confirmed.append(ConfirmedPair(
                    firstIndex: pair.firstIndex,
                    secondIndex: pair.secondIndex,
                    // A same-moment near-match is a weaker claim than an outright
                    // one, and the badge should say so.
                    confidence: min(0.80, confidence(hashDistance: pair.hashDistance,
                                                     histogram: pair.histogramSimilarity))
                ))
                continue
            }

            // Route 3 — Qdrant decides, but only within the band that route's
            // thresholds cover. Gating escalation on the same-moment test also keeps
            // `.similar` from sending pairs it was never going to accept.
            guard comparable else { continue }
            if sameMoment {
                greyZone.append(Escalation(
                    pair: pair,
                    accept: Tuning.shapeRequired(histogram: pair.histogramSimilarity, thresholds: thresholds)
                ))
            } else if pair.hashDistance <= anytime.hashReject {
                greyZone.append(Escalation(
                    pair: pair,
                    accept: Tuning.shapeRequired(histogram: pair.histogramSimilarity, thresholds: anytime)
                ))
            }
            // Video pairs that fail the direct test are dropped: the keyframe
            // sequence test is already strong enough that a near miss is a real miss.
        }
        return (confirmed, greyZone)
    }

    // MARK: - Grey zone

    /// Scores grey-zone pairs with Qdrant Edge — one exact lookup per photo, covering
    /// all of that photo's grey-zone partners at once.
    static func resolveGreyZone(
        _ escalations: [Escalation],
        in assets: [IndexedAsset],
        vectors: VectorIndex,
        cancellation: CancellationFlag? = nil,
        onProgress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) async -> [ConfirmedPair] {
        guard !escalations.isEmpty else { return [] }

        let byFirst = Dictionary(grouping: escalations.filter { escalation in
            VectorIndex.isIndexable(assets[escalation.pair.firstIndex].fingerprint)
                && VectorIndex.isIndexable(assets[escalation.pair.secondIndex].fingerprint)
        }, by: \.pair.firstIndex)
        let anchors = Array(byFirst.keys)
        let total = anchors.count
        onProgress(0, total)

        return await concurrentMap(anchors, cancellation: cancellation) { anchor in
            let pending = byFirst[anchor] ?? []
            let partners = pending.map { assets[$0.pair.secondIndex].record.id }
            let scores = vectors.scores(of: assets[anchor].fingerprint.shape.vector, against: partners)
            let scoreByPoint = Dictionary(scores.map { ($0.pointID, $0.score) },
                                          uniquingKeysWith: { max($0, $1) })

            return pending.compactMap { escalation -> ConfirmedPair? in
                let pair = escalation.pair
                let partnerPoint = VectorIndex.pointID(for: assets[pair.secondIndex].record.id)
                guard let score = scoreByPoint[partnerPoint], score >= escalation.accept else { return nil }
                return ConfirmedPair(
                    firstIndex: pair.firstIndex,
                    secondIndex: pair.secondIndex,
                    // Capped below the direct-match ceiling: a pair that needed the
                    // shape score to decide is genuinely less certain than one the
                    // hash agreed on outright.
                    confidence: min(0.85, confidence(hashDistance: pair.hashDistance,
                                                     histogram: pair.histogramSimilarity))
                )
            }
        } progress: { done in
            onProgress(done, total)
        }
    }

    // MARK: - Neighbours

    /// Pairs found by Qdrant Edge's nearest-neighbour search rather than the hash.
    ///
    /// Each photo is searched for in all four orientations. A rotated copy shares
    /// none of the original's hash bits, so before this route it could only ever
    /// be missed. Every pair still has to agree on colour and brightness and sit
    /// within the aspect tolerance — orientation-normalised, so a portrait copy of
    /// a landscape shot passes — and screenshot pairs are left to the structural
    /// rule above, since two screens of one app share most of their edges.
    ///
    /// The search is incremental. A photo's neighbours are stored on its Qdrant
    /// point the first time they are found, and only photos that are new, edited,
    /// or were never searched pay for a search; every pair is found from whichever
    /// of its two photos was searched later. At 20,000 photos the full search costs
    /// seconds, so paying it on every rescan would have made the route the slowest
    /// part of a rescan.
    ///
    /// Uses the anytime thresholds at every sensitivity: these pairs come with no
    /// hash agreement, so the same-moment relaxation does not extend to them.
    static func neighbours(
        in assets: [IndexedAsset],
        sensitivity: Sensitivity,
        vectors: VectorIndex,
        excluding known: Set<PairKey>,
        cancellation: CancellationFlag? = nil,
        onProgress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) async -> [ConfirmedPair] {
        let thresholds = Tuning.anytimeThresholds(for: sensitivity)
        let eligible = assets.indices.filter { index in
            let fingerprint = assets[index].fingerprint
            return VectorIndex.isIndexable(fingerprint) && !isDegenerate(fingerprint)
        }
        guard eligible.count > 1 else { return [] }

        let indexByAsset = Dictionary(eligible.map { (assets[$0].record.id, $0) },
                                      uniquingKeysWith: { first, _ in first })

        // What Qdrant already knows, then a search for whatever it does not.
        let stored = vectors.storedPoints(for: eligible.map { assets[$0].record.id })
        let pending = eligible.filter { index in
            guard let point = stored[assets[index].record.id], point.neighbours != nil else { return true }
            return abs(point.stamp - assets[index].fingerprint.stamp) >= 0.5
        }
        // Only a first scan, or a large import, has much to search; a rescan
        // typically has nothing pending at all.
        let total = pending.count
        if total > 0 { onProgress(0, total) }
        let searched = await concurrentMap(pending, cancellation: cancellation, transform: { index -> [(Int, [VectorIndex.StoredNeighbour])] in
            let fingerprint = assets[index].fingerprint
            var best: [String: VectorIndex.StoredNeighbour] = [:]
            for quarterTurns in 0..<4 {
                let hits = vectors.nearest(
                    to: fingerprint.shape.rotated(quarterTurns: quarterTurns),
                    // One extra, since a photo is its own nearest neighbour.
                    limit: Tuning.neighbourLimit + 1,
                    minimumScore: Tuning.neighbourFloor,
                    searchWidth: Tuning.neighbourSearchWidth
                )
                for hit in hits {
                    guard let asset = hit.assetID, let stamp = hit.stamp, asset != fingerprint.assetID else { continue }
                    if hit.score > best[asset]?.score ?? -1 {
                        best[asset] = VectorIndex.StoredNeighbour(assetID: asset, score: hit.score, stamp: stamp)
                    }
                }
            }
            let list = Array(best.values)
            vectors.storeNeighbours(list, assetID: fingerprint.assetID, stamp: fingerprint.stamp)
            return [(index, list)]
        }, progress: { done in
            onProgress(done, total)
        })
        if cancellation?.isSet == true { return [] }
        let fresh = Dictionary(searched, uniquingKeysWith: { first, _ in first })

        // Each pair is usually listed from both ends; keep its best orientation. An
        // entry counts only while its neighbour is unchanged since it was measured.
        var best: [PairKey: Float] = [:]
        for index in eligible {
            guard let list = fresh[index] ?? stored[assets[index].record.id]?.neighbours else { continue }
            for entry in list where entry.score >= thresholds.neighbourAccept {
                guard let other = indexByAsset[entry.assetID], other != index,
                      abs(assets[other].fingerprint.stamp - entry.stamp) < 0.5
                else { continue }
                let key = PairKey(index, other)
                if known.contains(key) { continue }
                best[key] = max(best[key] ?? -1, entry.score)
            }
        }

        var confirmed: [ConfirmedPair] = []
        for (key, score) in best {
            let first = assets[key.low]
            let second = assets[key.high]
            if first.record.kind == .screenshot && second.record.kind == .screenshot { continue }
            if abs(first.fingerprint.meanLuma - second.fingerprint.meanLuma) > Tuning.lumaTolerance { continue }

            let aspectDelta = abs(first.record.aspectRatio - second.record.aspectRatio)
                / max(first.record.aspectRatio, second.record.aspectRatio)
            if aspectDelta > Tuning.aspectTolerance { continue }

            let histogram = first.fingerprint.histogram.similarity(to: second.fingerprint.histogram)
            if histogram < thresholds.histogramAccept { continue }

            confirmed.append(ConfirmedPair(
                firstIndex: key.low,
                secondIndex: key.high,
                // The shape score stands in for the hash term, which says nothing
                // about a rotated pair. Capped like every model-decided match.
                confidence: min(0.85, 0.35 * Double(score) + 0.65 * Double(histogram))
            ))
        }
        return confirmed
    }

    // MARK: - Rules

    /// The structure-led and colour-led tests against one set of thresholds.
    static func accepts(
        _ pair: CandidatePair,
        using thresholds: Tuning.Thresholds,
        bothScreenshots: Bool
    ) -> Bool {
        if bothScreenshots {
            // Colour describes the app chrome, not the content, so structure alone.
            return pair.hashDistance <= Tuning.screenshotHashAccept
                && pair.histogramSimilarity >= Tuning.screenshotHistogramAccept
        }
        let structureLed = pair.hashDistance <= thresholds.hashAccept
            && pair.histogramSimilarity >= thresholds.histogramAccept
        let colourLed = pair.histogramSimilarity >= thresholds.strongHistogram
            && pair.hashDistance <= thresholds.colourLedHashLimit
        return structureLed || colourLed
    }

    /// Whether two frames were captured close enough together to be one scene.
    ///
    /// A missing capture date counts as *not* the same moment: without a timestamp
    /// there is no evidence for the temporal route, and assuming otherwise would let
    /// undated assets match everything.
    static func isSameMoment(_ first: AssetRecord, _ second: AssetRecord) -> Bool {
        guard let a = first.creationDate, let b = second.creationDate else { return false }
        return abs(a.timeIntervalSince(b)) <= Tuning.sameSceneWindow
    }

    static func isDegenerate(_ fingerprint: Fingerprint) -> Bool {
        fingerprint.meanLuma < Tuning.degenerateLumaLow
            || fingerprint.meanLuma > Tuning.degenerateLumaHigh
    }

    /// How sure we are that a pair really is one picture.
    ///
    /// Weighted towards colour because that is what the measurements showed to be
    /// decisive: across a library with known duplicates, true pairs held a histogram
    /// intersection above 0.97 even when heavy recompression pushed their hash
    /// distance to 16, while unrelated photographs sat below 0.90. Scoring the hash
    /// harshly made genuine duplicate groups read as merely "Possible", which
    /// understated the result to the user.
    static func confidence(hashDistance: Int, histogram: Float) -> Double {
        let hashScore = max(0, 1 - Double(hashDistance) / 32)
        return min(1, 0.35 * hashScore + 0.65 * Double(histogram))
    }

    // MARK: - Concurrency

    /// Maps `items` across cores in chunks, flattening the results.
    ///
    /// Qdrant Edge serves concurrent reads in parallel, so the per-photo searches
    /// are spread out the same way the exhaustive hash scan is. Once `cancellation`
    /// is set, remaining items are skipped.
    private static func concurrentMap<Item: Sendable, Output: Sendable>(
        _ items: [Item],
        cancellation: CancellationFlag? = nil,
        transform: @escaping @Sendable (Item) -> [Output],
        progress: @escaping @Sendable (Int) -> Void = { _ in }
    ) async -> [Output] {
        let cores = max(2, ProcessInfo.processInfo.activeProcessorCount)
        let chunks = items.chunked(into: max(16, items.count / (cores * 4)))

        return await withTaskGroup(of: (Int, [Output]).self) { group in
            for chunk in chunks {
                let work = Array(chunk)
                group.addTask(priority: .userInitiated) {
                    var results: [Output] = []
                    for item in work {
                        if cancellation?.isSet == true { break }
                        results.append(contentsOf: transform(item))
                    }
                    return (work.count, results)
                }
            }
            var all: [Output] = []
            var done = 0
            for await (count, results) in group {
                all.append(contentsOf: results)
                done += count
                progress(done)
            }
            return all
        }
    }
}
