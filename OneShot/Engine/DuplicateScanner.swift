import Foundation

/// Runs the full detection pipeline.
///
/// Five phases, in order:
///
/// 1. **Index** — flatten the library into `Sendable` records.
/// 2. **Fingerprint** — decode each asset once and extract hash, colour, shape,
///    sharpness and exposure. Cached, so only new or edited assets are re-analysed;
///    shapes are kept in Qdrant Edge alongside.
/// 3. **Compare** — an exhaustive pairwise scan for candidate pairs, then verify
///    each, with Qdrant Edge deciding the ambiguous ones and searching for the
///    pairs the hash cannot see.
/// 4. **Cluster** — union-find to merge pairs, then star clustering to break chains.
/// 5. **Score** — pick a keeper per group.
///
/// Nothing here touches the network. Assets whose pixels live only in iCloud are
/// counted and reported, never silently skipped.
actor DuplicateScanner {

    private let store = FingerprintStore()
    private let vectors = VectorIndex()
    private var isCancelled = false
    /// The same request, readable from the concurrent Qdrant searches.
    private let cancellation = CancellationFlag()

    /// Ceiling on face analyses per scan. Face detection is the most expensive
    /// per-asset operation in the app, and past a few hundred assets it stops
    /// changing the outcome and starts dominating the scan.
    private static let faceAnalysisBudget = 400

    /// How many members of a group are analysed for faces.
    ///
    /// Only the highest scorers can realistically win, and the eye-open bonus is not
    /// large enough to lift a photo that already lost on sharpness and resolution.
    /// Analysing three instead of the whole group is what makes this phase quick on a
    /// library with many large groups.
    private static let faceContenderCount = 3

    func cancel() {
        isCancelled = true
        cancellation.set(true)
    }

    /// Cached fingerprint count and size on disk.
    ///
    /// Routed through the scanner rather than letting the UI open its own
    /// `FingerprintStore`. Two connections to the same WAL-mode database do not see
    /// each other's uncommitted state, so a second store could report stale numbers
    /// straight after a clear.
    func cacheStatistics() async -> (count: Int, bytes: Int64) {
        let count = await store.count()
        let bytes = await store.diskUsage() + vectors.diskUsage()
        return (count, bytes)
    }

    func clearCache() async {
        await store.clear()
        vectors.clear()
    }

    // MARK: - Entry point

    func scan(
        settings: ScanSettings,
        source: ScanSource = .photoLibrary,
        onPhase: @escaping @Sendable (ScanPhase) -> Void
    ) async -> ScanResult {
        isCancelled = false
        cancellation.set(false)
        let started = Date()

        // MARK: 1 — Index
        onPhase(.indexing(done: 0, total: 0))
        let kinds = settings.includedKinds
        let records = await AssetLoader.fetchRecords(source: source, kinds: kinds) { done, total in
            onPhase(.indexing(done: done, total: total))
        }

        guard !isCancelled else { return cancelledResult(settings, started) }
        guard records.count > 1 else {
            onPhase(.finished)
            return ScanResult(groups: [], assetsScanned: records.count, skippedNotDownloaded: 0,
                              skippedUnreadable: 0, duration: Date().timeIntervalSince(started),
                              sensitivity: settings.sensitivity)
        }

        // MARK: 2 — Fingerprint
        let cached = await store.loadAll()
        var fingerprints: [String: Fingerprint] = [:]
        fingerprints.reserveCapacity(records.count)
        var pending: [AssetRecord] = []

        for record in records {
            if let existing = cached[record.id], abs(existing.stamp - Self.stamp(of: record)) < 0.5 {
                fingerprints[record.id] = existing
            } else {
                pending.append(record)
            }
        }

        onPhase(.fingerprinting(done: records.count - pending.count, total: records.count))

        let outcome = await fingerprintAll(
            pending,
            alreadyDone: records.count - pending.count,
            total: records.count,
            onPhase: onPhase
        )
        for fingerprint in outcome.fingerprints {
            fingerprints[fingerprint.assetID] = fingerprint
        }

        guard !isCancelled else { return cancelledResult(settings, started) }

        // Keep the cache tidy so it cannot grow without bound as photos are deleted —
        // but prune only what this scan can vouch for. A folder, or a scan with some
        // kinds left out, never listed the rest of the library: those fingerprints
        // are not stale, and dropping them would make the next full scan start from
        // nothing. Folder entries are left for Settings to clear.
        if case .photoLibrary = source, kinds.isSuperset(of: MediaKind.allCases) {
            let live = Set(records.map(\.id))
            let stale = cached.keys.filter { !AssetLoader.isFile($0) && !live.contains($0) }
            await store.prune(stale)
            vectors.remove(stale)
        }

        // MARK: 3 — Compare
        let indexed: [IndexedAsset] = records.compactMap { record in
            guard let fingerprint = fingerprints[record.id] else { return nil }
            return IndexedAsset(record: record, fingerprint: fingerprint)
        }
        guard indexed.count > 1 else {
            onPhase(.finished)
            return ScanResult(groups: [], assetsScanned: records.count,
                              skippedNotDownloaded: outcome.notDownloaded,
                              skippedUnreadable: outcome.unreadable,
                              duration: Date().timeIntervalSince(started),
                              sensitivity: settings.sensitivity)
        }

        onPhase(.comparing(done: 0, total: 1))
        // Writes only what is new or edited since the last scan, and repairs the
        // index if it fell out of step with the fingerprint cache.
        vectors.sync(indexed.map(\.fingerprint))

        let sensitivity = settings.sensitivity
        var candidates = await CandidateIndex.stillCandidates(
            in: indexed,
            sensitivity: sensitivity
        ) { done, total in
            onPhase(.comparing(done: done, total: max(total, 1)))
        }
        candidates += CandidateIndex.videoCandidates(in: indexed, sensitivity: sensitivity)

        guard !isCancelled else { return cancelledResult(settings, started) }

        let confirmed = await PairVerifier.verify(
            candidates,
            in: indexed,
            sensitivity: sensitivity,
            vectors: vectors,
            cancellation: cancellation
        ) { done, total in
            onPhase(.comparing(done: done, total: max(total, 1)))
        }

        // MARK: 4 — Cluster
        var unionFind = UnionFind(count: indexed.count)
        for pair in confirmed {
            unionFind.union(pair.firstIndex, pair.secondIndex)
        }

        // Union-find only finds connected components, which chain: A–B–C–D become one
        // group even when A and D are unrelated. The refiner breaks each component
        // into groups whose members all matched the same anchor directly.
        let clusters = ClusterRefiner.refine(
            components: unionFind.groups(),
            edges: confirmed.map {
                ClusterRefiner.Edge(first: $0.firstIndex, second: $0.secondIndex,
                                    confidence: $0.confidence)
            }
        )

        // Confidence per confirmed pair, so each refined group can average only the
        // pairs that actually fall inside it.
        var confidenceByPair: [PairKey: Double] = [:]
        for pair in confirmed {
            confidenceByPair[PairKey(pair.firstIndex, pair.secondIndex)] = pair.confidence
        }

        guard !isCancelled else { return cancelledResult(settings, started) }

        // MARK: 5 — Score
        let groups = await buildGroups(
            clusters: clusters,
            in: indexed,
            confidenceByPair: confidenceByPair,
            onPhase: onPhase
        )

        guard !isCancelled else { return cancelledResult(settings, started) }

        onPhase(.finished)
        return ScanResult(
            groups: groups.sorted { $0.reclaimableBytes > $1.reclaimableBytes },
            assetsScanned: records.count,
            skippedNotDownloaded: outcome.notDownloaded,
            skippedUnreadable: outcome.unreadable,
            duration: Date().timeIntervalSince(started),
            sensitivity: settings.sensitivity
        )
    }

    private func cancelledResult(_ settings: ScanSettings, _ started: Date) -> ScanResult {
        ScanResult(groups: [], assetsScanned: 0, skippedNotDownloaded: 0, skippedUnreadable: 0,
                   duration: Date().timeIntervalSince(started), sensitivity: settings.sensitivity)
    }

    private static func stamp(of record: AssetRecord) -> Double {
        (record.modificationDate ?? record.creationDate ?? .distantPast).timeIntervalSince1970
    }

    // MARK: - Fingerprinting

    private struct FingerprintPass: Sendable {
        var fingerprints: [Fingerprint] = []
        var notDownloaded = 0
        var unreadable = 0
    }

    private enum FingerprintOutcome: Sendable {
        case ready(Fingerprint)
        case notDownloaded
        case unreadable
    }

    /// Decodes and fingerprints assets with bounded concurrency.
    ///
    /// The bound matters in both directions: one at a time wastes the cores and the
    /// decode hardware, but an unbounded task group queues thousands of
    /// simultaneous PhotoKit requests and the system starts evicting them.
    private func fingerprintAll(
        _ pending: [AssetRecord],
        alreadyDone: Int,
        total: Int,
        onPhase: @escaping @Sendable (ScanPhase) -> Void
    ) async -> FingerprintPass {
        guard !pending.isEmpty else { return FingerprintPass() }

        let concurrency = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))
        var pass = FingerprintPass()
        var unsaved: [Fingerprint] = []
        var completed = alreadyDone
        var cursor = 0

        await withTaskGroup(of: FingerprintOutcome.self) { group in
            func addNext() {
                guard cursor < pending.count else { return }
                let record = pending[cursor]
                cursor += 1
                group.addTask(priority: .userInitiated) {
                    await Self.fingerprint(record)
                }
            }

            for _ in 0..<min(concurrency, pending.count) { addNext() }

            for await result in group {
                switch result {
                case .ready(let fingerprint):
                    pass.fingerprints.append(fingerprint)
                    unsaved.append(fingerprint)
                case .notDownloaded:
                    pass.notDownloaded += 1
                case .unreadable:
                    pass.unreadable += 1
                }

                completed += 1
                if completed % 25 == 0 || completed == total {
                    onPhase(.fingerprinting(done: completed, total: total))
                }

                // Flush periodically so a scan interrupted halfway still leaves the
                // cache warmer than it found it.
                if unsaved.count >= 250 {
                    let batch = unsaved
                    unsaved.removeAll(keepingCapacity: true)
                    await store.save(batch)
                }

                if isCancelled {
                    group.cancelAll()
                    break
                }
                addNext()
            }
        }

        if !unsaved.isEmpty {
            await store.save(unsaved)
        }
        return pass
    }

    private static func fingerprint(_ record: AssetRecord) async -> FingerprintOutcome {
        let stamp = stamp(of: record)

        if record.kind.isStill {
            switch await AssetLoader.loadThumbnail(for: record.id, edge: Tuning.thumbnailEdge) {
            case .success(let thumbnail):
                return .ready(Fingerprinter.fingerprint(thumbnail, assetID: record.id, stamp: stamp))
            case .failure(.notDownloaded):
                return .notDownloaded
            case .failure:
                return .unreadable
            }
        }

        guard let sample = await VideoFingerprinter.sample(assetID: record.id) else {
            return .notDownloaded
        }
        return .ready(Fingerprinter.fingerprint(
            sample.representativeFrame,
            assetID: record.id,
            stamp: stamp,
            keyframeHashes: sample.keyframeHashes
        ))
    }

    // MARK: - Group construction

    private func buildGroups(
        clusters: [[Int]],
        in assets: [IndexedAsset],
        confidenceByPair: [PairKey: Double],
        onPhase: @escaping @Sendable (ScanPhase) -> Void
    ) async -> [DuplicateGroup] {
        guard !clusters.isEmpty else { return [] }
        onPhase(.scoring(done: 0, total: clusters.count))

        // Real file sizes and edit status, for grouped assets only. Reading
        // `PHAssetResource` is a per-asset hit on the Photos database, so with a few
        // thousand grouped assets doing it on one thread was a large part of why
        // this phase dragged. Chunked across cores instead.
        let groupedRecords = clusters.flatMap { $0 }.map { assets[$0].record }
        let enrichedByID = await Self.enrichConcurrently(groupedRecords)

        var faceBudget = Self.faceAnalysisBudget
        var groups: [DuplicateGroup] = []
        var completed = 0

        for cluster in clusters {
            if isCancelled { break }

            let members: [IndexedAsset] = cluster.map { index in
                let original = assets[index]
                guard let updated = enrichedByID[original.record.id] else { return original }
                return IndexedAsset(record: updated, fingerprint: original.fingerprint)
            }

            // Score once without faces. This is pure arithmetic over data already in
            // memory, and it establishes who is actually in contention.
            var scored = QualityScorer.score(members: members, faces: [:])

            // Face detection is the most expensive operation in the app — a decode
            // plus a Vision request per photo. Running it on every member of every
            // group was the bulk of this phase. Only the top few can realistically
            // win, so only they are worth analysing; the rest are already behind on
            // sharpness and resolution and no eye-open bonus would close the gap.
            if scored.count >= 2,
               Self.warrantsFaceAnalysis(members),
               faceBudget >= Self.faceContenderCount {
                let contenderIDs = Set(scored.prefix(Self.faceContenderCount).map(\.id))
                let contenders = members.filter { contenderIDs.contains($0.record.id) }
                let faces = await Self.analyzeFaces(in: contenders)
                faceBudget -= contenders.count
                scored = QualityScorer.score(members: members, faces: faces)
            }

            guard scored.count >= 2 else { continue }

            groups.append(DuplicateGroup(
                members: scored,
                kind: Self.dominantKind(of: members),
                isBurst: Self.isBurst(members),
                confidence: Self.confidence(of: cluster, using: confidenceByPair)
            ))

            completed += 1
            if completed % 5 == 0 {
                onPhase(.scoring(done: completed, total: clusters.count))
            }
        }

        onPhase(.scoring(done: clusters.count, total: clusters.count))
        return groups
    }

    /// Mean confidence of the confirmed pairs that fall inside one refined group.
    private static func confidence(of cluster: [Int], using pairs: [PairKey: Double]) -> Double {
        var total = 0.0
        var count = 0
        for outer in 0..<cluster.count {
            for inner in (outer + 1)..<cluster.count {
                if let value = pairs[PairKey(cluster[outer], cluster[inner])] {
                    total += value
                    count += 1
                }
            }
        }
        return count == 0 ? 0.8 : total / Double(count)
    }

    /// Loads true file sizes and edit status across cores.
    private static func enrichConcurrently(_ records: [AssetRecord]) async -> [String: AssetRecord] {
        guard !records.isEmpty else { return [:] }

        let cores = max(2, min(6, ProcessInfo.processInfo.activeProcessorCount))
        let chunkSize = max(32, (records.count + cores - 1) / cores)

        return await withTaskGroup(of: [AssetRecord].self) { group in
            var start = 0
            while start < records.count {
                let chunk = Array(records[start..<min(records.count, start + chunkSize)])
                group.addTask(priority: .userInitiated) {
                    AssetLoader.enrich(chunk)
                }
                start += chunkSize
            }

            var result: [String: AssetRecord] = [:]
            result.reserveCapacity(records.count)
            for await enriched in group {
                for record in enriched { result[record.id] = record }
            }
            return result
        }
    }

    /// Face analysis only pays for itself when the frames genuinely differ.
    ///
    /// Exact copies have identical faces, so detecting them changes nothing. A
    /// meaningful spread in sharpness is the signal that these are separate
    /// exposures of the same moment — the burst case, where "who blinked" decides
    /// the pick.
    private static func warrantsFaceAnalysis(_ members: [IndexedAsset]) -> Bool {
        let sharpness = members.map(\.fingerprint.sharpness)
        guard let maximum = sharpness.max(), let minimum = sharpness.min(), maximum > 0 else {
            return false
        }
        return (maximum - minimum) / maximum > 0.15
    }

    private static func analyzeFaces(in members: [IndexedAsset]) async -> [String: FaceInfo] {
        await withTaskGroup(of: (String, FaceInfo).self) { group in
            for member in members {
                group.addTask(priority: .utility) {
                    (member.record.id, await FaceAnalyzer.analyze(assetID: member.record.id))
                }
            }
            var results: [String: FaceInfo] = [:]
            for await (id, info) in group {
                results[id] = info
            }
            return results
        }
    }

    private static func dominantKind(of members: [IndexedAsset]) -> MediaKind {
        var tally: [MediaKind: Int] = [:]
        for member in members {
            tally[member.record.kind, default: 0] += 1
        }
        return tally.max { $0.value < $1.value }?.key ?? .photo
    }

    /// True when the group is a camera burst rather than a set of copies.
    ///
    /// PhotoKit's own burst identifier is authoritative when present. Falling back to
    /// timestamps alone was not enough: a batch of photos imported together all share
    /// an import timestamp, which made every group — including a photo and its
    /// resized copy — claim to be a burst. Real burst frames come off the same sensor
    /// in the same instant, so they are necessarily identical in pixel dimensions,
    /// and requiring that removes the false labels.
    private static func isBurst(_ members: [IndexedAsset]) -> Bool {
        let identifiers = Set(members.compactMap(\.record.burstIdentifier))
        if identifiers.count == 1, identifiers.first != nil { return true }

        // A pair is a pair, not a burst — the label only means something for a run of
        // frames, and calling two copies of one photo a burst is just noise.
        guard members.count >= 3 else { return false }

        let dimensions = Set(members.map { "\($0.record.pixelWidth)x\($0.record.pixelHeight)" })
        guard dimensions.count == 1 else { return false }

        let dates = members.compactMap(\.record.creationDate).sorted()
        guard dates.count == members.count, dates.count >= 2 else { return false }
        for index in 1..<dates.count where
            dates[index].timeIntervalSince(dates[index - 1]) > Tuning.burstWindow {
            return false
        }
        return true
    }
}
