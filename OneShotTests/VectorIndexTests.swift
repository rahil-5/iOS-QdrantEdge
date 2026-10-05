import XCTest
@testable import OneShot

/// The Qdrant Edge wrapper, exercised against a real on-disk shard.
final class VectorIndexTests: XCTestCase {

    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories {
            try? FileManager.default.removeItem(at: directory)
        }
        directories.removeAll()
        super.tearDown()
    }

    private func freshIndex() -> (VectorIndex, URL) {
        let (index, directory) = makeVectorIndex()
        directories.append(directory)
        return (index, directory)
    }

    private func fingerprint(_ seed: Int, id: String, stamp: Double = 0) -> Fingerprint {
        let thumbnail = ThumbnailData(cgImage: SyntheticCorpus.scene(seed), edge: Tuning.thumbnailEdge)!
        return Fingerprinter.fingerprint(thumbnail, assetID: id, stamp: stamp)
    }

    /// The shard survives being closed and reopened, and a resync writes only what
    /// changed — the property that lets a rescan skip unchanged photos.
    func testShapesPersistAndResyncWritesOnlyWhatChanged() {
        let (index, directory) = freshIndex()
        let prints = [fingerprint(11, id: "a"), fingerprint(27, id: "b"), fingerprint(43, id: "c")]

        XCTAssertEqual(index.sync(prints), 3)
        XCTAssertEqual(index.count(), 3)
        XCTAssertEqual(index.sync(prints), 0, "nothing changed, so nothing should be written")

        // A fresh instance over the same directory sees the same points.
        index.close()
        let reopened = VectorIndex(directory: directory)
        XCTAssertEqual(reopened.count(), 3)
        let nearest = reopened.nearest(to: prints[1].shape.vector, limit: 1, minimumScore: 0.5)
        XCTAssertEqual(nearest.first?.pointID, VectorIndex.pointID(for: "b"))
        XCTAssertEqual(nearest.first?.score ?? 0, 1, accuracy: 0.002)

        // An edit changes the stamp; only that photo is rewritten.
        let edited = [prints[0], fingerprint(27, id: "b", stamp: 99), prints[2]]
        XCTAssertEqual(reopened.sync(edited), 1)

        reopened.remove(["a"])
        XCTAssertEqual(reopened.count(), 2)

        reopened.clear()
        XCTAssertEqual(reopened.count(), 0)
    }

    /// The grey-zone lookup: an exact search restricted by `HasId` must return
    /// exactly the requested points, scored as plain cosine similarity.
    func testHasIdScoringMatchesCosineSimilarity() {
        let (index, _) = freshIndex()
        let prints = (0..<6).map { fingerprint(100 + $0 * 17, id: "p\($0)") }
        index.sync(prints)

        let scores = index.scores(of: prints[0].shape.vector, against: ["p2", "p4"])
        XCTAssertEqual(Set(scores.map(\.pointID)), [VectorIndex.pointID(for: "p2"), VectorIndex.pointID(for: "p4")])
        for score in scores {
            let other = score.pointID == VectorIndex.pointID(for: "p2") ? prints[2] : prints[4]
            // Qdrant stores half precision, as the signature does.
            XCTAssertEqual(score.score, prints[0].shape.similarity(to: other.shape), accuracy: 0.003)
        }
    }

    /// A quarter-turn of the image is a signed permutation of its signature, so the
    /// rotated query finds the rotated copy without decoding anything again.
    func testRotatedSignatureMatchesTheRotatedImage() {
        let original = SyntheticCorpus.scene(11, width: 1600, height: 1200)
        let base = fingerprint(11, id: "base")
        for turns in 1...3 {
            let rotatedImage = SyntheticCorpus.rotated(original, quarterTurns: turns)
            let rotated = Fingerprinter.fingerprint(
                ThumbnailData(cgImage: rotatedImage, edge: Tuning.thumbnailEdge)!, assetID: "r", stamp: 0)
            let best = (0..<4).map { quarter in
                zip(base.shape.rotated(quarterTurns: quarter), rotated.shape.vector).reduce(Float(0)) { $0 + $1.0 * $1.1 }
            }.max() ?? 0
            XCTAssertGreaterThan(best, 0.99, "rotation by \(turns) quarter-turns")
            // Past the most permissive hash accept of any route, so no hash route
            // could have linked this pair — otherwise the test proves nothing.
            XCTAssertGreaterThan(base.dHash.hammingDistance(to: rotated.dHash), Tuning.thresholds(for: .similar).hashAccept,
                                 "rotation by \(turns) quarter-turns")
        }
    }

    /// An unreadable shard costs a re-index, never a failed scan.
    func testUnreadableShardIsRebuilt() throws {
        let (_, directory) = freshIndex()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not a shard".utf8).write(to: directory.appendingPathComponent("edge_config.json"))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("segments"),
                                                withIntermediateDirectories: true)
        try Data([0xde, 0xad]).write(to: directory.appendingPathComponent("segments/garbage"))

        let index = VectorIndex(directory: directory)
        XCTAssertEqual(index.sync([fingerprint(11, id: "a")]), 1)
        XCTAssertEqual(index.count(), 1)
    }

    /// Cost of Qdrant Edge at library scale: 20,000 shapes is past Qdrant's indexing
    /// threshold, so this exercises the HNSW graph rather than a brute-force scan.
    /// It times what a scan actually pays — writing and indexing, the neighbour route
    /// on a first scan (every photo searched) and on a rescan (every list stored).
    ///
    /// Random unit vectors are the worst case for a graph index — nothing is near
    /// anything — so real libraries should do better. On the simulator this measures
    /// the Mac's CPU, not a phone's, so it is reported rather than asserted tightly.
    func testLibraryScaleCost() async {
        let (index, _) = freshIndex()
        let count = 20_000
        var generator = SplitMix(seed: 42)
        let assets: [IndexedAsset] = (0..<count).map { item in
            var vector = (0..<ShapeSignature.dimensions).map { _ in Float(generator.nextGaussian()) }
            let length = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
            vector = vector.map { $0 / length }
            let record = AssetRecord(id: "v\(item)", kind: .photo, pixelWidth: 4032, pixelHeight: 3024,
                                     creationDate: nil, modificationDate: nil, duration: 0, isFavorite: false,
                                     burstIdentifier: nil, isEdited: false, isHDR: false, byteSize: 3_000_000)
            let fingerprint = Fingerprint(assetID: record.id, dHash: 0,
                                          histogram: HistogramSignature(bins: [Float](repeating: 1.0 / 64, count: 64)),
                                          shape: ShapeSignature(vector: vector), sharpness: 0, exposure: 0,
                                          meanLuma: 0.5, keyframeHashes: [], stamp: 0)
            return IndexedAsset(record: record, fingerprint: fingerprint)
        }

        var clock = Date()
        func lap() -> TimeInterval {
            defer { clock = Date() }
            return Date().timeIntervalSince(clock)
        }

        index.sync(assets.map(\.fingerprint))
        let writeTime = lap()
        let stats = index.statistics()
        XCTAssertEqual(stats.points, count)

        // Recall check at the configured search width: every photo finds itself.
        let probes = Array(assets.prefix(2_000))
        let selfHits = probes.filter { asset in
            index.nearest(to: asset.fingerprint.shape.vector, limit: Tuning.neighbourLimit + 1,
                          minimumScore: Tuning.neighbourFloor, searchWidth: Tuning.neighbourSearchWidth)
                .contains { $0.pointID == VectorIndex.pointID(for: asset.record.id) }
        }.count
        _ = lap()

        _ = await PairVerifier.neighbours(in: assets, sensitivity: .strict, vectors: index, excluding: [])
        let firstScan = lap()
        _ = index.sync(assets.map(\.fingerprint))
        _ = await PairVerifier.neighbours(in: assets, sensitivity: .strict, vectors: index, excluding: [])
        let rescan = lap()

        print(String(format: "Qdrant Edge @ %d photos: %d in the HNSW graph across %d segments; write + index %.1f s; "
                     + "neighbour route first scan %.1f s, rescan %.2f s; self-recall %d/%d",
                     count, stats.indexed, stats.segments, writeTime, firstScan, rescan, selfHits, probes.count))
        XCTAssertGreaterThanOrEqual(Double(selfHits) / Double(probes.count), 0.99, "HNSW should find a photo's own shape")
        XCTAssertLessThan(rescan, firstScan / 4, "a rescan should be answered from stored neighbour lists")
    }
}

/// Deterministic random numbers, so the throughput test measures the same shard
/// every run.
struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func nextGaussian() -> Double {
        let u1 = max(Double(next() >> 11) / Double(1 << 53), .leastNonzeroMagnitude)
        let u2 = Double(next() >> 11) / Double(1 << 53)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}
