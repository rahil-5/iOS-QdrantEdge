import Foundation
import QdrantEdge
import os

/// Qdrant Edge, holding one `ShapeSignature` per still image.
///
/// This is where photo matching beyond the cheap hash-and-colour test happens. It
/// replaced Apple's Vision feature print, and does two jobs Vision did not:
///
/// - **Scores grey-zone pairs** — those the hash and histogram could not decide —
///   with an exact similarity lookup restricted to the pair's own points.
/// - **Finds pairs the hash cannot see**, by nearest-neighbour search over the whole
///   library, including each photo's three rotations. Each photo's neighbours are
///   stored on its own point, so a rescan searches only for what is new or edited.
///
/// Qdrant Edge runs in-process: no server, no network, no model weights. The shard
/// lives in Application Support beside the SQLite fingerprint cache and persists
/// between scans, so only new or edited photos are written to it and its HNSW index
/// is rebuilt only for what changed.
///
/// Every failure degrades to "no match from this route" rather than a failed scan,
/// the same rule the fingerprint cache follows: the hash routes still run.
final class VectorIndex: @unchecked Sendable {

    private static let vectorName = "shape"
    private static let logger = Logger(subsystem: "com.rahil.OneShot", category: "VectorIndex")

    private let directory: URL
    /// Guards the shard reference only. Operations run outside it, since the shard
    /// synchronises internally and serves concurrent reads in parallel.
    private let lock = NSLock()
    private var shard: EdgeShard?

    init(directory: URL) {
        self.directory = directory
    }

    convenience init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.init(directory: base.appendingPathComponent("vectors.qdrant", isDirectory: true))
    }

    // MARK: - Point identity

    /// Qdrant point id for an asset.
    ///
    /// 64-bit FNV-1a of the identifier's UTF-8 bytes — stable across launches, unlike
    /// Swift's seeded `Hasher`. At 30,000 assets the chance of any collision is
    /// around 1 in 40 billion, and a collision only drops that asset from the
    /// Qdrant routes, since lookups go through the current scan's own table.
    static func pointID(for assetID: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in assetID.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    /// Whether a fingerprint belongs in the index. Video is matched on its keyframe
    /// sequence instead, and a blank frame has no direction to search by.
    static func isIndexable(_ fingerprint: Fingerprint) -> Bool {
        !fingerprint.isVideo && !fingerprint.shape.isBlank
    }

    // MARK: - Writing

    /// Brings the index in line with these fingerprints, writing any that are
    /// missing or older than the fingerprint, then rebuilding the search index if
    /// anything changed. Returns how many points were written.
    ///
    /// Checking each point's stored stamp, rather than trusting that the index saw
    /// every fingerprint the SQLite cache did, is what makes the two stores
    /// self-healing: an interrupted scan, a deleted shard or an upgrade from a
    /// build without one all repair themselves on the next scan.
    @discardableResult
    func sync(_ fingerprints: [Fingerprint]) -> Int {
        let wanted = fingerprints.filter(Self.isIndexable)
        guard !wanted.isEmpty else { return 0 }

        let stored = storedPoints(for: wanted.map(\.assetID))
        let stale = wanted.filter { fingerprint in
            guard let point = stored[fingerprint.assetID] else { return true }
            return abs(point.stamp - fingerprint.stamp) >= 0.5
        }
        guard !stale.isEmpty else { return 0 }

        var written = 0
        for chunk in stale.chunked(into: 512) {
            let points = chunk.map { fingerprint in
                Point(
                    id: .numId(value: Self.pointID(for: fingerprint.assetID)),
                    vector: .named(map: [Self.vectorName: .dense(values: fingerprint.shape.vector)]),
                    payload: Self.payload(assetID: fingerprint.assetID, stamp: fingerprint.stamp)
                )
            }
            let ok = withShard { shard in
                try shard.update(operation: UpdateOperation.upsertPoints(points: points))
            }
            if ok != nil { written += chunk.count }
        }
        if written > 0 { optimize() }
        return written
    }

    /// Records the neighbours found for one photo on its own point.
    ///
    /// Written with `set_payload`, which merges, so the point's vector and identity
    /// are untouched. A rewrite of the point by `sync` — because the photo was
    /// edited — drops the list, which is how it gets recomputed.
    func storeNeighbours(_ neighbours: [StoredNeighbour], assetID: String, stamp: Double) {
        let object: [String: Any] = [
            "near_stamp": stamp,
            "near_version": Self.neighbourVersion,
            "near": neighbours.map { ["a": $0.assetID, "s": Double($0.score), "t": $0.stamp] as [String: Any] },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: data, encoding: .utf8)
        else { return }
        withShard { shard in
            try shard.update(operation: UpdateOperation.setPayload(
                pointIds: [.numId(value: Self.pointID(for: assetID))],
                payloadJson: json
            ))
        }
    }

    /// Removes the points for assets that no longer exist.
    func remove(_ assetIDs: [String]) {
        for chunk in assetIDs.chunked(into: 1024) {
            withShard { shard in
                try shard.update(operation: UpdateOperation.deletePoints(
                    pointIds: chunk.map { .numId(value: Self.pointID(for: $0)) }
                ))
            }
        }
    }

    /// Builds the HNSW graph for freshly written points and persists everything.
    ///
    /// Until this runs Qdrant answers by brute force, and large unindexed segments
    /// can be left out of results — so it is called after every batch of writes,
    /// never left for later.
    func optimize() {
        withShard { shard in
            _ = try shard.optimize()
            try shard.flush()
        }
    }

    /// Flushes and releases the shard's files, keeping them on disk. The next
    /// operation reopens it.
    func close() {
        lock.lock()
        defer { lock.unlock() }
        try? shard?.unload()
        shard = nil
    }

    /// Deletes every point and the files behind them.
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? shard?.unload()
        shard = nil
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Reading

    struct Neighbour: Sendable {
        let pointID: UInt64
        let score: Float
        /// Present for `nearest`, which asks for the point's identity.
        var assetID: String? = nil
        var stamp: Double? = nil
    }

    /// One entry of a photo's stored neighbour list. `stamp` is the neighbour's
    /// modification stamp when the pair was measured; an entry whose neighbour has
    /// since been edited no longer describes it and is ignored.
    struct StoredNeighbour: Sendable, Hashable {
        let assetID: String
        let score: Float
        let stamp: Double
    }

    /// What the index holds for one asset.
    struct StoredPoint: Sendable {
        let stamp: Double
        /// Nil until neighbours have been searched for at this stamp.
        let neighbours: [StoredNeighbour]?
    }

    /// Bumped when the meaning of a stored neighbour list changes — its score floor
    /// or length — so lists written under the old rules are recomputed.
    static let neighbourVersion = 1

    /// The closest stored shapes to `vector`, best first, scoring at least
    /// `minimumScore` (cosine), with each one's asset and stamp.
    func nearest(to vector: [Float], limit: Int, minimumScore: Float, searchWidth: Int? = nil) -> [Neighbour] {
        let request = SearchRequest(
            query: .nearest(vector: .dense(values: vector), using: Self.vectorName),
            limit: UInt64(limit),
            params: searchWidth.map { SearchParams(hnswEf: UInt64($0)) },
            withPayload: .fields(fields: ["asset", "stamp"]),
            scoreThreshold: minimumScore
        )
        guard let points = withShard({ shard in try shard.search(request: request) }) else { return [] }
        return points.compactMap { point in
            guard case .numId(let id) = point.id else { return nil }
            let payload = Self.decode(point.payload)
            return Neighbour(pointID: id, score: point.score,
                             assetID: payload["asset"] as? String,
                             stamp: (payload["stamp"] as? NSNumber)?.doubleValue)
        }
    }

    /// The exact similarity of `vector` to each of the given assets' stored shapes.
    ///
    /// Restricting the search to those points with a `HasId` filter, and asking for
    /// an exact search, turns a nearest-neighbour engine into a pairwise scorer —
    /// which is what the grey zone needs: a verdict on these particular pairs.
    func scores(of vector: [Float], against assetIDs: [String]) -> [Neighbour] {
        guard !assetIDs.isEmpty else { return [] }
        let request = SearchRequest(
            query: .nearest(vector: .dense(values: vector), using: Self.vectorName),
            limit: UInt64(assetIDs.count),
            filter: Filter(must: [.hasId(ids: assetIDs.map { .numId(value: Self.pointID(for: $0)) })]),
            params: SearchParams(exact: true)
        )
        return withShard { shard in try shard.search(request: request) }.map(Self.neighbours) ?? []
    }

    /// How many points the index holds.
    func count() -> Int {
        withShard { shard in Int(try shard.info().pointsCount) } ?? 0
    }

    /// Points, how many of them the HNSW graph covers, and segment count.
    func statistics() -> (points: Int, indexed: Int, segments: Int) {
        withShard { shard in
            let info = try shard.info()
            return (Int(info.pointsCount), Int(info.indexedVectorsCount), Int(info.segmentsCount))
        } ?? (0, 0, 0)
    }

    /// Size of the shard on disk, for the Settings screen.
    func diskUsage() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let size = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize
            total += Int64(size ?? 0)
        }
        return total
    }

    // MARK: - Internals

    /// What the index holds for each of these assets, keyed by asset id. Assets
    /// with no point are absent.
    func storedPoints(for assetIDs: [String]) -> [String: StoredPoint] {
        var points: [String: StoredPoint] = [:]
        for chunk in assetIDs.chunked(into: 2048) {
            let assetByPoint = Dictionary(chunk.map { (Self.pointID(for: $0), $0) },
                                          uniquingKeysWith: { first, _ in first })
            let request = RetrieveRequest(
                pointIds: chunk.map { .numId(value: Self.pointID(for: $0)) },
                withPayload: .fields(fields: ["stamp", "near_stamp", "near_version", "near"]),
                withVector: .bool(enable: false)
            )
            guard let records = withShard({ shard in try shard.retrieve(request: request) }) else { continue }
            for record in records {
                guard case .numId(let id) = record.id,
                      let assetID = assetByPoint[id]
                else { continue }
                let payload = Self.decode(record.payload)
                guard let stamp = (payload["stamp"] as? NSNumber)?.doubleValue else { continue }

                var neighbours: [StoredNeighbour]?
                if let nearStamp = (payload["near_stamp"] as? NSNumber)?.doubleValue,
                   abs(nearStamp - stamp) < 0.5,
                   (payload["near_version"] as? NSNumber)?.intValue == Self.neighbourVersion,
                   let near = payload["near"] as? [[String: Any]] {
                    neighbours = near.compactMap { entry in
                        guard let asset = entry["a"] as? String,
                              let score = (entry["s"] as? NSNumber)?.floatValue,
                              let stamp = (entry["t"] as? NSNumber)?.doubleValue
                        else { return nil }
                        return StoredNeighbour(assetID: asset, score: score, stamp: stamp)
                    }
                }
                points[assetID] = StoredPoint(stamp: stamp, neighbours: neighbours)
            }
        }
        return points
    }

    private static func decode(_ json: String?) -> [String: Any] {
        guard let data = json?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    private static func payload(assetID: String, stamp: Double) -> String? {
        let object: [String: Any] = ["asset": assetID, "stamp": stamp]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func neighbours(_ points: [ScoredPoint]) -> [Neighbour] {
        points.compactMap { point in
            guard case .numId(let id) = point.id else { return nil }
            return Neighbour(pointID: id, score: point.score)
        }
    }

    /// Runs `body` against the open shard, opening it on first use. Returns nil, and
    /// logs, if Qdrant reports an error.
    @discardableResult
    private func withShard<T>(_ body: (EdgeShard) throws -> T) -> T? {
        guard let shard = openShard() else { return nil }
        do {
            return try body(shard)
        } catch {
            Self.logger.error("Qdrant Edge operation failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func openShard() -> EdgeShard? {
        lock.lock()
        defer { lock.unlock() }
        if let shard { return shard }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            shard = try EdgeShard.load(path: directory.path, config: Self.configuration)
        } catch {
            // An unreadable or incompatible shard — say, one written by a build with
            // a different signature size — costs a re-index, never a failed scan.
            Self.logger.error("Rebuilding Qdrant Edge shard: \(String(describing: error), privacy: .public)")
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            shard = try? EdgeShard.load(path: directory.path, config: Self.configuration)
        }
        return shard
    }

    /// One cosine field of `ShapeSignature.dimensions`, stored in half precision like
    /// the signature itself.
    private static var configuration: EdgeConfig {
        EdgeConfig(vectorData: [
            vectorName: VectorDataConfig(
                size: UInt64(ShapeSignature.dimensions),
                distance: .cosine,
                datatype: .float16
            )
        ])
    }
}

extension Array {
    func chunked(into size: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: size).map { self[$0..<Swift.min($0 + size, count)] }
    }
}
