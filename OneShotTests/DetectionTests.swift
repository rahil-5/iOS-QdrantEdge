import XCTest
@testable import OneShot

/// Ground-truth tests for the detection pipeline, run against a real Qdrant Edge
/// shard.
///
/// The first five are the measurements that drove the original iOS build and the
/// Android port — each one caught a real defect. They are re-run here because
/// Qdrant Edge replaced Vision in the verifier, and every one of them must still
/// hold. The last two cover what Qdrant Edge adds.
final class DetectionTests: XCTestCase {

    // MARK: - 1. The seeded library

    /// One photo saved five ways, a three-frame burst, a resized pair, six unrelated
    /// photographs, two blank frames and one white one.
    static func seededLibrary() -> LabelledCorpus {
        var corpus = LabelledCorpus()

        let sunset = SyntheticCorpus.scene(11, width: 3200, height: 2400)
        corpus.add(sunset, "A")
        corpus.add(SyntheticCorpus.resized(sunset, width: 1600, height: 1200), "A")
        corpus.add(SyntheticCorpus.resized(sunset, width: 800, height: 600), "A")
        corpus.add(SyntheticCorpus.jpegRoundTrip(sunset, quality: 0.25), "A")
        corpus.add(SyntheticCorpus.scene(11, width: 3200, height: 2400, brightness: 1.16), "A")

        let harbour = SyntheticCorpus.scene(27, width: 3200, height: 2400)
        corpus.add(harbour, "B")
        corpus.add(SyntheticCorpus.scene(27, width: 3200, height: 2400, blur: 2), "B")
        corpus.add(SyntheticCorpus.jpegRoundTrip(harbour, quality: 0.55), "B")

        let valley = SyntheticCorpus.scene(43, width: 2400, height: 1800)
        corpus.add(valley, "C")
        corpus.add(SyntheticCorpus.resized(valley, width: 1200, height: 900), "C")

        for (index, seed) in [61, 79, 97, 113, 131, 149].enumerated() {
            corpus.add(SyntheticCorpus.scene(seed, width: 2400, height: 1800), "unique-\(index)")
        }

        corpus.add(SyntheticCorpus.solid(0.01), "blank")
        corpus.add(SyntheticCorpus.solid(0.01), "blank")
        corpus.add(SyntheticCorpus.solid(0.99), "white")
        return corpus
    }

    func testSeededLibraryResolvesToItsFourKnownGroups() async {
        let corpus = Self.seededLibrary()

        let result = await runPipeline(corpus.assets, sensitivity: .strict)
        print("seeded library → groups \(sizes(result.groups))")

        assertNoMixedGroups(result.groups, truth: corpus.truth)
        XCTAssertEqual(result.groups.count, 4, "expected exactly four groups")
        XCTAssertEqual(sizes(result.groups), [5, 3, 2, 2])
        XCTAssertEqual(result.groups.reduce(0) { $0 + $1.count - 1 }, 8, "expected eight duplicates")

        // Every sensitivity must stay clean, and the looser ones may only add.
        for sensitivity in Sensitivity.allCases {
            let other = await runPipeline(corpus.assets, sensitivity: sensitivity)
            print("seeded library @ \(sensitivity.title) → groups \(sizes(other.groups))")
            assertNoMixedGroups(other.groups, truth: corpus.truth, sensitivity.title)
        }
    }

    // MARK: - 2. Chaining

    /// Union-find merges A–B–C–D into one blob even when A and D are unrelated; on a
    /// real library this produced a group of ~900 photos.
    func testStarClusteringBreaksTransitiveChains() async {
        let length = 40
        let assets = (0..<length).map { step in
            SyntheticCorpus.indexed(step, SyntheticCorpus.morph(5, 88, step: step, of: length),
                                    takenAt: TimeInterval(step * 120))
        }

        let result = await runPipeline(assets, sensitivity: .strict)
        let largestComponent = result.components.map(\.count).max() ?? 0
        let largestRefined = result.groups.map(\.count).max() ?? 0
        print("chain → union-find largest \(largestComponent), refined \(sizes(result.groups))")

        // What the hash and colour routes produce on their own, so a change in group
        // sizes can be attributed to them or to Qdrant.
        let candidates = await CandidateIndex.stillCandidates(in: assets, sensitivity: .strict) { _, _ in }
        let direct = PairVerifier.directRoutes(candidates, in: assets, sensitivity: .strict).confirmed
        var directUnion = UnionFind(count: assets.count)
        for pair in direct { directUnion.union(pair.firstIndex, pair.secondIndex) }
        let directGroups = ClusterRefiner.refine(
            components: directUnion.groups(),
            edges: direct.map { ClusterRefiner.Edge(first: $0.firstIndex, second: $0.secondIndex, confidence: $0.confidence) }
        )
        print("chain, direct routes only → \(direct.count) pairs, refined \(sizes(directGroups)); with Qdrant → \(result.confirmed.count) pairs")

        XCTAssertFalse(result.groups.contains { $0.contains(0) && $0.contains(length - 1) },
                       "first and last frame ended up in the same group — still chaining")
        XCTAssertLessThan(largestRefined, largestComponent, "refinement should shrink the largest group")
        XCTAssertLessThanOrEqual(largestRefined, Tuning.maxGroupSize)

        // Every member must be a direct match to its anchor, not a transitive one.
        let edges = Set(result.confirmed.map { PairKey($0.firstIndex, $0.secondIndex) })
        for group in result.groups {
            let anchor = group[0]
            for member in group.dropFirst() {
                XCTAssertTrue(edges.contains(PairKey(anchor, member)),
                              "member \(member) is not directly matched to anchor \(anchor)")
            }
        }
    }

    // MARK: - 3. `Similar scenes`

    /// Loosening thresholds library-wide once grouped forty unrelated photos. The
    /// mode is `.strict` plus a time-gated route, and the hostile corpus is built so
    /// that every photo shares the same gross composition.
    func testSimilarScenesFindsBurstsWithoutGroupingUnrelatedPhotos() async {
        var corpus = LabelledCorpus()

        // A real burst: six frames of one scene, two seconds apart.
        for frame in 0..<6 {
            corpus.add(SyntheticCorpus.scene(5, brightness: 1.0 + Double(frame) * 0.012, blur: frame == 3 ? 1 : 0),
                       "burst", takenAt: TimeInterval(frame * 2))
        }
        // Two shots of one subject a minute apart.
        for frame in 0..<2 {
            corpus.add(SyntheticCorpus.scene(61, brightness: 1.0 + Double(frame) * 0.02),
                       "reshoot", takenAt: 5_000 + TimeInterval(frame * 55))
        }
        // Twenty-five unrelated photographs, one per day.
        for index in 0..<25 {
            corpus.add(SyntheticCorpus.scene(1000 + index * 37), "unrelated-\(index)",
                       takenAt: 100_000 + TimeInterval(index * 86_400))
        }
        // Ten unrelated photographs thirty seconds apart — proximity in time must not
        // by itself imply duplication.
        for index in 0..<10 {
            corpus.add(SyntheticCorpus.scene(5000 + index * 53), "sameday-\(index)",
                       takenAt: 900_000 + TimeInterval(index * 30))
        }

        for sensitivity in Sensitivity.allCases {
            let result = await runPipeline(corpus.assets, sensitivity: sensitivity)
            print("similar-scenes corpus @ \(sensitivity.title) → groups \(sizes(result.groups))")
            assertNoMixedGroups(result.groups, truth: corpus.truth, sensitivity.title)
        }

        let similar = await runPipeline(corpus.assets, sensitivity: .similar)
        let found = Set(similar.groups.map { corpus.truth[$0[0]] })
        XCTAssertTrue(found.contains("burst"), "the burst should be detected")
        XCTAssertTrue(found.contains("reshoot"), "the reshoot should be detected")
    }

    // MARK: - 4. Exposure

    func testChromaticityHistogramSurvivesBrightnessChange() {
        let original = SyntheticCorpus.indexed(0, SyntheticCorpus.scene(11))
        let brightened = SyntheticCorpus.indexed(1, SyntheticCorpus.scene(11, brightness: 1.16))

        let similarity = original.fingerprint.histogram.similarity(to: brightened.fingerprint.histogram)
        print("brightened copy → histogram \(similarity)")
        // An RGB histogram scored this pair at 0.50.
        XCTAssertGreaterThan(similarity, 0.90)
    }

    // MARK: - 5. Blank frames

    func testBlankFramesDoNotMergeWithEachOtherByBrightness() async {
        let assets = [
            SyntheticCorpus.indexed(0, SyntheticCorpus.solid(0.01)),
            SyntheticCorpus.indexed(1, SyntheticCorpus.solid(0.01)),
            SyntheticCorpus.indexed(2, SyntheticCorpus.solid(0.99)),
        ]
        let result = await runPipeline(assets, sensitivity: .strict)

        XCTAssertEqual(result.groups.count, 1, "the two black frames should form one group")
        XCTAssertEqual(result.groups.first?.count, 2)
        XCTAssertFalse(result.groups.first?.contains(2) ?? true, "the white frame must not join the black ones")
    }

    // MARK: - 6. Rotated copies (new with Qdrant Edge)

    /// A rotated copy shares almost none of the original's hash bits — measured at
    /// Hamming 23–39, past every reject threshold — so the hash scan cannot find it
    /// at all. Qdrant Edge's neighbour search over rotated signatures can.
    func testRotatedCopiesAreFoundByNeighbourSearch() async {
        var corpus = LabelledCorpus()
        let sunset = SyntheticCorpus.scene(11, width: 3200, height: 2400)
        corpus.add(sunset, "sunset")
        for turns in 1...3 {
            corpus.add(SyntheticCorpus.rotated(sunset, quarterTurns: turns), "sunset")
        }
        // Rotations of an unrelated photo, so a rotation match cannot be satisfied
        // by "anything rotated looks alike".
        let valley = SyntheticCorpus.scene(43, width: 2400, height: 1800)
        corpus.add(valley, "valley")
        corpus.add(SyntheticCorpus.rotated(valley, quarterTurns: 1), "valley")
        for (index, seed) in [61, 79, 97, 113, 131, 149].enumerated() {
            corpus.add(SyntheticCorpus.rotated(SyntheticCorpus.scene(seed, width: 2400, height: 1800),
                                               quarterTurns: index % 4), "unique-\(index)")
        }

        // The hash routes alone never link a photo to its rotation.
        let candidates = await CandidateIndex.stillCandidates(in: corpus.assets, sensitivity: .strict) { _, _ in }
        let direct = PairVerifier.directRoutes(candidates, in: corpus.assets, sensitivity: .strict)
        for pair in direct.confirmed {
            let a = corpus.assets[pair.firstIndex].fingerprint
            let b = corpus.assets[pair.secondIndex].fingerprint
            print("direct: \(pair.firstIndex)–\(pair.secondIndex) hash \(a.dHash.hammingDistance(to: b.dHash)) hist \(a.histogram.similarity(to: b.histogram))")
        }
        XCTAssertFalse(direct.confirmed.contains { $0.firstIndex == 0 || $0.secondIndex == 0 },
                       "the hash should not link the original to any of its rotations")

        for sensitivity in Sensitivity.allCases {
            let result = await runPipeline(corpus.assets, sensitivity: sensitivity)
            print("rotations @ \(sensitivity.title) → groups \(sizes(result.groups))")
            assertNoMixedGroups(result.groups, truth: corpus.truth, sensitivity.title)
            XCTAssertEqual(sizes(result.groups), [4, 2], "\(sensitivity.title): both rotation sets should be found")
        }
    }

    /// Neighbour lists are stored on the Qdrant points and reused by the next scan;
    /// an edit must invalidate them, from both ends of every pair.
    func testStoredNeighboursAreReusedAndInvalidatedByEdits() async {
        let (vectors, directory) = makeVectorIndex()
        defer { vectors.clear(); try? FileManager.default.removeItem(at: directory) }

        let sunset = SyntheticCorpus.scene(11, width: 1600, height: 1200)
        let unrelated = (0..<4).map { SyntheticCorpus.indexed(2 + $0, SyntheticCorpus.scene(1000 + $0 * 37)) }
        var assets = [
            SyntheticCorpus.indexed(0, sunset),
            SyntheticCorpus.indexed(1, SyntheticCorpus.rotated(sunset, quarterTurns: 1)),
        ] + unrelated

        func rotationPairFound() async -> Bool {
            vectors.sync(assets.map(\.fingerprint))
            let pairs = await PairVerifier.neighbours(in: assets, sensitivity: .strict, vectors: vectors, excluding: [])
            return pairs.contains { PairKey($0.firstIndex, $0.secondIndex) == PairKey(0, 1) }
        }

        // First scan searches and stores.
        let firstFound = await rotationPairFound()
        XCTAssertTrue(firstFound)
        let stored = vectors.storedPoints(for: assets.map(\.record.id))
        XCTAssertTrue(stored.values.allSatisfy { $0.neighbours != nil }, "every photo's search should be stored")
        XCTAssertEqual(stored["asset-0"]?.neighbours?.map(\.assetID), ["asset-1"])

        // A rescan with nothing changed is answered from the stored lists.
        let secondFound = await rotationPairFound()
        XCTAssertTrue(secondFound)

        // The rotated copy is edited into a different picture. The original's list
        // still names it, at its old stamp, and must not be believed.
        assets[1] = SyntheticCorpus.indexed(1, SyntheticCorpus.scene(4242), stamp: 50)
        let afterEdit = await rotationPairFound()
        XCTAssertFalse(afterEdit, "a stale neighbour entry produced a pair")

        // And edited back, the pair is found again from the edited photo's side.
        assets[1] = SyntheticCorpus.indexed(1, SyntheticCorpus.rotated(sunset, quarterTurns: 3), stamp: 60)
        let afterRestore = await rotationPairFound()
        XCTAssertTrue(afterRestore)
    }

    /// Cancelling stops the Qdrant searches; nothing half-finished is reported.
    func testCancelledScanSkipsTheNeighbourSearch() async {
        let (vectors, directory) = makeVectorIndex()
        defer { vectors.clear(); try? FileManager.default.removeItem(at: directory) }

        let sunset = SyntheticCorpus.scene(11, width: 1600, height: 1200)
        let assets = [SyntheticCorpus.indexed(0, sunset),
                      SyntheticCorpus.indexed(1, SyntheticCorpus.rotated(sunset, quarterTurns: 1))]
        vectors.sync(assets.map(\.fingerprint))

        let cancelled = CancellationFlag()
        cancelled.set(true)
        let pairs = await PairVerifier.neighbours(in: assets, sensitivity: .strict, vectors: vectors,
                                                  excluding: [], cancellation: cancelled)
        XCTAssertTrue(pairs.isEmpty)
        XCTAssertTrue(vectors.storedPoints(for: assets.map(\.record.id)).values.allSatisfy { $0.neighbours == nil },
                      "no search should have run")
    }

    // MARK: - 7. The grey zone (Qdrant Edge replaces Vision here)

    /// A colour-filtered copy keeps its structure but moves its colours. Measured:
    /// hash 3, histogram 0.86 — below `.strict`'s 0.90 histogram accept and its 0.985
    /// colour-led route, so neither direct route takes it, and it escalates. Its
    /// shape similarity is 0.9996, which is Qdrant's call to make.
    func testColourFilteredCopyIsDecidedByQdrantInTheGreyZone() async {
        var corpus = LabelledCorpus()
        let sunset = SyntheticCorpus.scene(11, width: 3200, height: 2400)
        corpus.add(sunset, "sunset")
        corpus.add(SyntheticCorpus.tinted(sunset, red: 0.85, green: 0.95, blue: 1.0), "sunset")
        for index in 0..<25 {
            corpus.add(SyntheticCorpus.scene(1000 + index * 37), "unrelated-\(index)")
        }

        let candidates = await CandidateIndex.stillCandidates(in: corpus.assets, sensitivity: .strict) { _, _ in }
        let direct = PairVerifier.directRoutes(candidates, in: corpus.assets, sensitivity: .strict)
        XCTAssertFalse(direct.confirmed.contains { PairKey($0.firstIndex, $0.secondIndex) == PairKey(0, 1) },
                       "the filtered copy should not be decided by the direct routes")
        XCTAssertTrue(direct.greyZone.contains { PairKey($0.pair.firstIndex, $0.pair.secondIndex) == PairKey(0, 1) },
                      "the filtered copy should escalate to Qdrant")
        let unrelatedInGreyZone = direct.greyZone.filter { corpus.truth[$0.pair.firstIndex] != corpus.truth[$0.pair.secondIndex] }
        print("grey zone: \(direct.greyZone.count) pairs, \(unrelatedInGreyZone.count) of them unrelated")

        let result = await runPipeline(corpus.assets, sensitivity: .strict)
        assertNoMixedGroups(result.groups, truth: corpus.truth)
        XCTAssertEqual(result.groups.map { Set($0) }, [Set([0, 1])], "Qdrant should confirm exactly the filtered copy")
    }
}
