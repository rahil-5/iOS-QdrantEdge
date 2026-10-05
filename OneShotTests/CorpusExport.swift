import XCTest
@testable import OneShot

/// Writes the device corpus to disk so it can be added to a simulator's photo
/// library and scanned by the real app.
///
/// `testDeviceCorpusResolvesToItsKnownGroups` certifies the same list the export
/// writes, so the photos in the simulator are exactly the ones the ground-truth
/// assertion covers. The export is skipped unless a destination is given;
/// `TEST_RUNNER_` forwards it into the test process:
///
///     TEST_RUNNER_ONESHOT_CORPUS_OUT=/tmp/corpus xcodebuild test \
///         -only-testing:OneShotTests/CorpusExport ...
final class CorpusExport: XCTestCase {

    /// The seeded library, plus two copies only Qdrant Edge can find: a rotated
    /// sunset and a colour-filtered valley. File name, truth label, image.
    static func deviceCorpus() -> [(name: String, label: String, image: CGImage)] {
        var items: [(String, String, CGImage)] = []

        // Group A — one photo saved five ways, plus a rotated copy.
        let sunset = SyntheticCorpus.scene(11, width: 3200, height: 2400)
        items.append(("sunset-original", "A", sunset))
        items.append(("sunset-shared-copy", "A", SyntheticCorpus.resized(sunset, width: 1600, height: 1200)))
        items.append(("sunset-thumbnail-copy", "A", SyntheticCorpus.resized(sunset, width: 800, height: 600)))
        items.append(("sunset-recompressed", "A", SyntheticCorpus.jpegRoundTrip(sunset, quality: 0.25)))
        items.append(("sunset-brightened", "A", SyntheticCorpus.scene(11, width: 3200, height: 2400, brightness: 1.16)))
        items.append(("sunset-rotated", "A", SyntheticCorpus.rotated(sunset, quarterTurns: 1)))

        // Group B — a burst, one frame out of focus.
        let harbour = SyntheticCorpus.scene(27, width: 3200, height: 2400)
        items.append(("harbour-frame1", "B", harbour))
        items.append(("harbour-frame2-blurry", "B", SyntheticCorpus.scene(27, width: 3200, height: 2400, blur: 2)))
        items.append(("harbour-frame3", "B", SyntheticCorpus.jpegRoundTrip(harbour, quality: 0.55)))

        // Group C — a resized pair, plus a colour-filtered copy.
        let valley = SyntheticCorpus.scene(43, width: 2400, height: 1800)
        items.append(("valley-original", "C", valley))
        items.append(("valley-copy", "C", SyntheticCorpus.resized(valley, width: 1200, height: 900)))
        items.append(("valley-filtered", "C", SyntheticCorpus.tinted(valley, red: 0.85, green: 0.95, blue: 1.0)))

        // Unrelated photographs that must not be grouped.
        for (index, seed) in [61, 79, 97, 113, 131, 149].enumerated() {
            items.append(("unique-\(index + 1)", "unique-\(index)", SyntheticCorpus.scene(seed, width: 2400, height: 1800)))
        }

        // The false-positive trap.
        items.append(("lens-cap-1", "blank", SyntheticCorpus.solid(0.01)))
        items.append(("lens-cap-2", "blank", SyntheticCorpus.solid(0.01)))
        items.append(("overexposed", "white", SyntheticCorpus.solid(0.99)))
        return items
    }

    func testDeviceCorpusResolvesToItsKnownGroups() async {
        var corpus = LabelledCorpus()
        for item in Self.deviceCorpus() {
            corpus.add(item.image, item.label)
        }
        let result = await runPipeline(corpus.assets, sensitivity: .strict)
        print("device corpus → groups \(sizes(result.groups))")

        assertNoMixedGroups(result.groups, truth: corpus.truth)
        XCTAssertEqual(sizes(result.groups), [6, 3, 3, 2])
        XCTAssertEqual(result.groups.reduce(0) { $0 + $1.count - 1 }, 10, "expected ten duplicates")
    }

    func testExportDeviceCorpus() throws {
        guard let destination = ProcessInfo.processInfo.environment["ONESHOT_CORPUS_OUT"] else {
            throw XCTSkip("set TEST_RUNNER_ONESHOT_CORPUS_OUT to export")
        }
        let directory = URL(fileURLWithPath: destination, isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let items = Self.deviceCorpus()
        for (order, item) in items.enumerated() {
            let url = directory.appendingPathComponent(String(format: "%02d-%@.png", order + 1, item.name))
            try SyntheticCorpus.png(item.image).write(to: url)
        }
        print("exported \(items.count) files to \(directory.path)")
        print("ground truth: 4 groups (6, 3, 3, 2), 10 duplicates")
    }
}
