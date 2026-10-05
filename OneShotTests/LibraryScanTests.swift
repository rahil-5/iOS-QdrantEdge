import XCTest
import Photos
@testable import OneShot

/// The whole scan, exactly as the Scan button runs it, against the simulator's real
/// photo library: PhotoKit, fingerprinting, the SQLite cache, Qdrant Edge, the
/// verifier, clustering and keeper scoring.
///
/// Opt-in, because it clears and rebuilds the host app's caches and depends on what
/// the simulator's library holds. Seed the library with the exported device corpus
/// (see `CorpusExport`), grant the app photo access, then:
///
///     xcrun simctl addmedia booted /tmp/corpus/*.png
///     xcrun simctl privacy booted grant photos com.rahil.OneShot
///     TEST_RUNNER_ONESHOT_LIBRARY_SCAN=1 xcodebuild test \
///         -only-testing:OneShotTests/LibraryScanTests ...
final class LibraryScanTests: XCTestCase {

    func testScanOfSeededLibrary() async throws {
        guard ProcessInfo.processInfo.environment["ONESHOT_LIBRARY_SCAN"] != nil else {
            throw XCTSkip("set TEST_RUNNER_ONESHOT_LIBRARY_SCAN=1 to scan the simulator's library")
        }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw XCTSkip("grant OneShot photo access first: xcrun simctl privacy booted grant photos com.rahil.OneShot")
        }

        let scanner = DuplicateScanner()
        await scanner.clearCache()
        let settings = ScanSettings(sensitivity: .strict, includedKinds: Set(MediaKind.allCases))

        let first = await scanner.scan(settings: settings) { _ in }
        let second = await scanner.scan(settings: settings) { _ in }
        let cache = await scanner.cacheStatistics()

        // Label each asset by the corpus file it came from; anything else in the
        // library (the simulator's own sample photos) is its own label, so it can
        // only ever be grouped wrongly, never rightly.
        let names = Self.originalFilenames()
        func label(_ id: String) -> String {
            guard let name = names[id] else { return id }
            let stem = name.replacingOccurrences(of: ".png", with: "")
            let parts = stem.split(separator: "-").dropFirst()  // drop the "01" order prefix
            switch parts.first {
            case "sunset": return "A"
            case "harbour": return "B"
            case "valley": return "C"
            case "lens": return "blank"
            default: return stem
            }
        }

        for (pass, result) in [("first scan", first), ("rescan", second)] {
            let described = result.groups.map { group in
                group.members.map { names[$0.id] ?? "(library photo)" }
            }
            print(String(format: "%@: %d assets in %.2f s → %d groups %@",
                         pass, result.assetsScanned, result.duration, result.groups.count,
                         result.groups.map(\.members.count).sorted(by: >).description))
            for (group, members) in zip(result.groups, described) {
                print("  keeper \(names[group.keeperID] ?? group.keeperID): \(members.sorted())")
            }

            for group in result.groups {
                let labels = Set(group.members.map { label($0.id) })
                XCTAssertEqual(labels.count, 1, "\(pass): group mixes unrelated photos: \(group.members.map { names[$0.id] ?? $0.id })")
            }
            XCTAssertEqual(result.groups.map(\.members.count).sorted(by: >), [6, 3, 3, 2], pass)
            XCTAssertEqual(result.duplicateCount, 10, pass)
        }
        print("cache: \(cache.count) fingerprints, \(cache.bytes.formattedBytes) including the Qdrant Edge shard")
        XCTAssertLessThan(second.duration, first.duration, "the rescan should reuse the caches")
    }

    /// Asset identifier → original filename, from PhotoKit.
    private static func originalFilenames() -> [String: String] {
        var names: [String: String] = [:]
        let assets = PHAsset.fetchAssets(with: .image, options: nil)
        assets.enumerateObjects { asset, _, _ in
            if let resource = PHAssetResource.assetResources(for: asset).first {
                names[asset.localIdentifier] = resource.originalFilename
            }
        }
        return names
    }
}
