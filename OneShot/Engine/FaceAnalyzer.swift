import Foundation
import Vision
import CoreGraphics

/// What face detection contributes to picking a keeper.
struct FaceInfo: Sendable {
    let faceCount: Int
    /// Mean eye-openness across detected faces, 0…1. Defaults to 0 when no face is
    /// found, but the scorer ignores this dimension entirely for face-free groups so
    /// landscapes are never penalised.
    let openEyeScore: Float

    static let none = FaceInfo(faceCount: 0, openEyeScore: 0)
}

/// Detects faces and estimates whether their eyes are open.
///
/// This is the single most useful signal for burst frames of people: three shots of
/// the same group, and the one worth keeping is the one where nobody blinked. Run
/// only for assets that already landed in a duplicate group, because it is far too
/// expensive to run across an entire library.
enum FaceAnalyzer {

    /// Faces need more pixels than the 128px scanning thumbnail to land reliably.
    private static let inputEdge = 320

    static func analyze(assetID: String) async -> FaceInfo {
        let size = CGSize(width: inputEdge, height: inputEdge)
        guard let image = await AssetLoader.loadPreview(for: assetID, targetSize: size, allowNetwork: false),
              let cgImage = image.cgImage
        else { return .none }
        return analyze(cgImage: cgImage)
    }

    static func analyze(cgImage: CGImage) -> FaceInfo {
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
        } catch {
            return .none
        }

        guard let observations = request.results, !observations.isEmpty else { return .none }

        var openness: [Float] = []
        for observation in observations {
            if let score = eyeOpenness(of: observation) {
                openness.append(score)
            }
        }

        let mean = openness.isEmpty ? 0 : openness.reduce(0, +) / Float(openness.count)
        return FaceInfo(faceCount: observations.count, openEyeScore: mean)
    }

    /// Estimates eye openness from landmark geometry.
    ///
    /// Vision reports no "eyes open" flag, so this uses the eye aspect ratio: the
    /// height of the eye landmark polygon over its width. An open eye is roughly
    /// 0.25–0.35; a closed one collapses below 0.15. It is a heuristic, which is why
    /// it carries a modest weight in the final score rather than deciding the pick
    /// on its own.
    private static func eyeOpenness(of observation: VNFaceObservation) -> Float? {
        guard let landmarks = observation.landmarks else { return nil }

        var ratios: [Float] = []
        for region in [landmarks.leftEye, landmarks.rightEye] {
            guard let region, region.pointCount > 3 else { continue }
            let points = region.normalizedPoints

            var minX = Float.greatestFiniteMagnitude
            var maxX = -Float.greatestFiniteMagnitude
            var minY = Float.greatestFiniteMagnitude
            var maxY = -Float.greatestFiniteMagnitude
            for point in points {
                minX = min(minX, Float(point.x))
                maxX = max(maxX, Float(point.x))
                minY = min(minY, Float(point.y))
                maxY = max(maxY, Float(point.y))
            }

            // Landmark points are normalised to the face bounding box, so they must
            // be scaled back by that box before the ratio means anything. The input
            // is square, so width and height scale identically and cancel out.
            let width = (maxX - minX) * Float(observation.boundingBox.width)
            let height = (maxY - minY) * Float(observation.boundingBox.height)
            guard width > 0 else { continue }
            ratios.append(height / width)
        }

        guard !ratios.isEmpty else { return nil }
        let meanRatio = ratios.reduce(0, +) / Float(ratios.count)
        return min(1, max(0, (meanRatio - 0.10) / 0.20))
    }
}
