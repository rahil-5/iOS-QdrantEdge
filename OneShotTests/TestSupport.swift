import Foundation
import XCTest
@testable import OneShot

/// A Qdrant Edge index in its own temporary directory, so tests never share points
/// and never touch the app's real shard.
func makeVectorIndex() -> (index: VectorIndex, directory: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("oneshot-tests-\(UUID().uuidString)", isDirectory: true)
    return (VectorIndex(directory: directory), directory)
}

/// What the scanner does between fingerprinting and scoring, minus the photo
/// library: index the shapes in Qdrant Edge, generate candidates, verify, cluster.
struct PipelineResult {
    let groups: [[Int]]
    let confirmed: [ConfirmedPair]
    let components: [[Int]]
}

func runPipeline(_ assets: [IndexedAsset], sensitivity: Sensitivity) async -> PipelineResult {
    let (vectors, directory) = makeVectorIndex()
    defer {
        vectors.clear()
        try? FileManager.default.removeItem(at: directory)
    }
    vectors.sync(assets.map(\.fingerprint))

    var candidates = await CandidateIndex.stillCandidates(in: assets, sensitivity: sensitivity) { _, _ in }
    candidates += CandidateIndex.videoCandidates(in: assets, sensitivity: sensitivity)
    let confirmed = await PairVerifier.verify(candidates, in: assets, sensitivity: sensitivity, vectors: vectors)

    var unionFind = UnionFind(count: assets.count)
    for pair in confirmed {
        unionFind.union(pair.firstIndex, pair.secondIndex)
    }
    let components = unionFind.groups()
    let groups = ClusterRefiner.refine(
        components: components,
        edges: confirmed.map {
            ClusterRefiner.Edge(first: $0.firstIndex, second: $0.secondIndex, confidence: $0.confidence)
        }
    )
    return PipelineResult(groups: groups, confirmed: confirmed, components: components)
}

/// A group mixing truth labels is a false positive.
func assertNoMixedGroups(
    _ groups: [[Int]],
    truth: [String],
    _ context: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    for group in groups {
        let labels = Set(group.map { truth[$0] })
        XCTAssertEqual(labels.count, 1, "\(context) group mixes unrelated photos: \(group.map { truth[$0] })",
                       file: file, line: line)
    }
}

/// Sizes, largest first — the shape a result is reported in.
func sizes(_ groups: [[Int]]) -> [Int] {
    groups.map(\.count).sorted(by: >)
}

/// Builds a corpus with a truth label per asset.
struct LabelledCorpus {
    private(set) var assets: [IndexedAsset] = []
    private(set) var truth: [String] = []

    mutating func add(
        _ image: CGImage,
        _ label: String,
        kind: MediaKind = .photo,
        takenAt: TimeInterval? = 0
    ) {
        assets.append(SyntheticCorpus.indexed(assets.count, image, kind: kind, takenAt: takenAt))
        truth.append(label)
    }
}
