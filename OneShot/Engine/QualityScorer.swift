import Foundation

/// Decides which member of a duplicate group is worth keeping.
///
/// The scoring is deliberately *relative*: every measured dimension is normalised
/// against the range within that one group. Absolute sharpness is meaningless — a
/// tack-sharp macro shot and a soft landscape are not comparable — but "sharpest of
/// these four near-identical frames" is exactly the question being asked.
///
/// Objective measurements (sharpness, resolution, exposure, faces) are normalised
/// and weighted. User intent (favourited, edited) is added as a flat bonus large
/// enough to override the measurements, because a photo the user explicitly starred
/// should never be discarded in favour of a marginally sharper copy.
enum QualityScorer {

    private enum Weight {
        static let sharpness = 3.0
        static let resolution = 2.5
        static let exposure = 1.2
        static let faces = 2.0
        static let fileSize = 0.8

        static let favourite = 5.0
        static let edited = 1.2
        static let livePhoto = 0.8
        static let highDynamicRange = 0.8
        /// Applied when a group mixes screenshots with real photos: the photo is
        /// almost always the original and the screenshot the derived copy.
        static let screenshotInMixedGroup = -1.5
    }

    /// Scores and ranks one group.
    ///
    /// - Parameters:
    ///   - members: the group's assets, with fingerprints.
    ///   - faces: face analysis keyed by asset id. May be empty, in which case the
    ///     face dimension is skipped rather than scored as zero.
    static func score(members: [IndexedAsset], faces: [String: FaceInfo]) -> [ScoredAsset] {
        guard !members.isEmpty else { return [] }

        let sharpnessRange = Range(of: members.map { Double($0.fingerprint.sharpness) })
        let resolutionRange = Range(of: members.map { logPixelCount($0.record) })
        let exposureRange = Range(of: members.map { Double($0.fingerprint.exposure) })
        let byteRange = Range(of: members.map { Double($0.record.byteSize) })

        // Ranges are built only from members that were actually analysed, so an
        // unanalysed member cannot drag the bottom of the range down and distort
        // everyone else's normalised score.
        let analysed = members.compactMap { faces[$0.record.id] }
        let groupHasFaces = analysed.contains { $0.faceCount > 0 }
        let faceRange = Range(of: analysed.map { Double($0.openEyeScore) })
        let faceCountRange = Range(of: analysed.map { Double($0.faceCount) })

        let hasNonScreenshot = members.contains { $0.record.kind != .screenshot }

        // Track the winner of each dimension so the UI can explain the pick.
        var winners: [QualityHighlight: String] = [:]
        winners[.sharpest] = argmax(members) { Double($0.fingerprint.sharpness) }
        winners[.highestResolution] = argmax(members) { logPixelCount($0.record) }
        winners[.bestExposure] = argmax(members) { Double($0.fingerprint.exposure) }
        winners[.largestFile] = argmax(members) { Double($0.record.byteSize) }
        if groupHasFaces {
            winners[.eyesOpen] = argmax(members) { Double(faces[$0.record.id]?.openEyeScore ?? 0) }
            winners[.mostFaces] = argmax(members) { Double(faces[$0.record.id]?.faceCount ?? 0) }
        }
        // The earliest capture in a group is almost always the original, and the
        // later ones the exports, re-saves and shares derived from it.
        winners[.original] = members
            .min { ($0.record.creationDate ?? .distantFuture) < ($1.record.creationDate ?? .distantFuture) }?
            .record.id

        return members.map { member in
            var total = 0.0
            total += Weight.sharpness * sharpnessRange.normalise(Double(member.fingerprint.sharpness))
            total += Weight.resolution * resolutionRange.normalise(logPixelCount(member.record))
            total += Weight.exposure * exposureRange.normalise(Double(member.fingerprint.exposure))
            total += Weight.fileSize * byteRange.normalise(Double(member.record.byteSize))

            if groupHasFaces {
                if let info = faces[member.record.id] {
                    total += Weight.faces * (0.7 * faceRange.normalise(Double(info.openEyeScore))
                                             + 0.3 * faceCountRange.normalise(Double(info.faceCount)))
                } else {
                    // Not analysed rather than "no faces". The scanner only runs face
                    // detection on the handful of members still in contention, so
                    // scoring the rest as zero would punish them for work that was
                    // deliberately skipped. A neutral half-share leaves their ranking
                    // to the dimensions that were actually measured.
                    total += Weight.faces * 0.5
                }
            }

            if member.record.isFavorite { total += Weight.favourite }
            if member.record.isEdited { total += Weight.edited }
            if member.record.kind == .livePhoto { total += Weight.livePhoto }
            if member.record.isHDR { total += Weight.highDynamicRange }
            if member.record.kind == .screenshot && hasNonScreenshot {
                total += Weight.screenshotInMixedGroup
            }

            return ScoredAsset(
                record: member.record,
                score: total,
                highlights: highlights(for: member, winners: winners)
            )
        }
    }

    private static func highlights(
        for member: IndexedAsset,
        winners: [QualityHighlight: String]
    ) -> [QualityHighlight] {
        var result: [QualityHighlight] = []

        // User intent first — it is the most meaningful thing to show.
        if member.record.isFavorite { result.append(.favourite) }
        if member.record.isEdited { result.append(.edited) }

        // Then measured wins, in descending order of how much they influenced the
        // score, so the top three chips explain the actual decision.
        for highlight in [QualityHighlight.sharpest, .highestResolution, .eyesOpen,
                          .mostFaces, .bestExposure, .original, .largestFile] {
            if winners[highlight] == member.record.id {
                result.append(highlight)
            }
        }

        if member.record.kind == .livePhoto { result.append(.livePhoto) }
        if member.record.isHDR { result.append(.highDynamicRange) }

        // Three chips is as many as the layout reads well with.
        return Array(result.prefix(3))
    }

    /// Log scale, because the perceptual gap between 2 MP and 4 MP is far larger
    /// than between 46 MP and 48 MP.
    private static func logPixelCount(_ record: AssetRecord) -> Double {
        log2(Double(max(1, record.pixelCount)))
    }

    private static func argmax(_ members: [IndexedAsset], by value: (IndexedAsset) -> Double) -> String? {
        var best: (id: String, value: Double)?
        for member in members {
            let candidate = value(member)
            if best == nil || candidate > best!.value {
                best = (member.record.id, candidate)
            }
        }
        return best?.id
    }

    /// Min/max of one dimension, with a normaliser that degrades gracefully when
    /// every member scores the same (which is common — identical copies really do
    /// have identical resolution).
    private struct Range {
        let minimum: Double
        let maximum: Double

        init(of values: [Double]) {
            minimum = values.min() ?? 0
            maximum = values.max() ?? 0
        }

        /// Maps a value into 0…1 within this range. Returns 0.5 for a degenerate
        /// range so a tied dimension contributes equally to everyone rather than
        /// arbitrarily favouring whoever is compared first.
        func normalise(_ value: Double) -> Double {
            let span = maximum - minimum
            guard span > 1e-9 else { return 0.5 }
            return (value - minimum) / span
        }
    }
}
