import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import OneShot

/// Synthetic photographs with known relationships, so detection can be measured
/// against ground truth rather than against whatever happens to be on a device.
///
/// A CoreGraphics port of the Android engine's `SyntheticCorpus`. Every scene shares
/// the same gross composition — sky above, terrain below — because that is what a
/// luminance-gradient hash keys on, and it is the shape of a real photo library. A
/// corpus of obviously different pictures would not test anything.
enum SyntheticCorpus {

    /// Deterministic pseudo-random in 0…1 from a seed and an index.
    private static func value(_ seed: Int, _ index: Int) -> Double {
        let x = sin(Double(seed * 97 + index * 31)) * 43758.5453
        return x - floor(x)
    }

    static func scene(
        _ seed: Int,
        width: Int = 1600,
        height: Int = 1200,
        brightness: Double = 1.0,
        blur: Int = 0
    ) -> CGImage {
        let context = makeContext(width: width, height: height)
        let w = Double(width)
        let h = Double(height)

        func clamp(_ v: Double) -> CGFloat { CGFloat(min(1, max(0, v * brightness))) }
        func colour(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
            CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
        }

        // Sky
        let top = colour(clamp(0.20 + value(seed, 1) * 0.40), clamp(0.45 + value(seed, 2) * 0.40), clamp(0.90))
        let bottom = colour(clamp(0.90 + value(seed, 3) * 0.10), clamp(0.60 + value(seed, 7) * 0.30),
                            clamp(0.45 + value(seed, 8) * 0.40))
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                  colors: [top, bottom] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: h), options: [])

        // Sun
        context.setFillColor(colour(clamp(1.0), clamp(0.95), clamp(0.70)))
        let sunRadius = w * (0.06 + value(seed, 4) * 0.05)
        let sunX = w * (0.2 + value(seed, 5) * 0.6)
        let sunY = h * (0.38 - value(seed, 6) * 0.25)
        context.fillEllipse(in: CGRect(x: sunX - sunRadius, y: sunY - sunRadius,
                                       width: sunRadius * 2, height: sunRadius * 2))

        // Terrain, three receding ridges.
        for layer in 0..<3 {
            let shade = clamp(0.12 + Double(layer) * 0.14 + value(seed, 10 + layer) * 0.18)
            context.setFillColor(colour(shade * CGFloat(0.4 + value(seed, 40 + layer) * 0.6), shade,
                                        shade * CGFloat(0.4 + value(seed, 50 + layer) * 0.5)))
            let path = CGMutablePath()
            let baseY = h * (0.80 - Double(layer) * 0.09)
            path.move(to: CGPoint(x: 0, y: h))
            path.addLine(to: CGPoint(x: 0, y: baseY))
            var x = 0.0
            var step = 0
            while x < w {
                let peak = baseY - h * value(seed, 20 + layer * 10 + step) * 0.20
                path.addQuadCurve(to: CGPoint(x: x + w / 5, y: baseY), control: CGPoint(x: x + w / 10, y: peak))
                x += w / 5
                step += 1
            }
            path.addLine(to: CGPoint(x: w, y: h))
            path.closeSubpath()
            context.addPath(path)
            context.fillPath()
        }

        // Fine detail. This is what blur destroys, so sharpness has something to read.
        for index in 0..<120 {
            let s = clamp(0.1 + value(seed, 200 + index) * 0.8)
            context.setFillColor(colour(s, s * 0.9, s * 0.7))
            let px = w * value(seed, 300 + index * 2)
            let py = h * (0.58 + value(seed, 301 + index * 2) * 0.42)
            context.fill(CGRect(x: px, y: py, width: w * 0.010, height: w * 0.010))
        }

        var result = context.makeImage()!
        for _ in 0..<blur { result = boxBlur(result) }
        return result
    }

    /// Downscale/upscale blur, enough to collapse the high-frequency detail the
    /// sharpness metric reads.
    static func boxBlur(_ image: CGImage) -> CGImage {
        let small = resized(image, width: max(1, image.width / 5), height: max(1, image.height / 5))
        return resized(small, width: image.width, height: image.height)
    }

    static func resized(_ image: CGImage, width: Int, height: Int) -> CGImage {
        let context = makeContext(width: width, height: height, flipped: false)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// Rotates by a quarter turn, as a phone does when a photo is rotated in an editor.
    static func rotated(_ image: CGImage, quarterTurns: Int) -> CGImage {
        let turns = ((quarterTurns % 4) + 4) % 4
        let swap = turns % 2 == 1
        let width = swap ? image.height : image.width
        let height = swap ? image.width : image.height
        let context = makeContext(width: width, height: height, flipped: false)
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.rotate(by: CGFloat(turns) * .pi / 2)
        context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                                       width: CGFloat(image.width), height: CGFloat(image.height)))
        return context.makeImage()!
    }

    /// A colour filter: multiplies every pixel by `tint`, the way a warm "vintage"
    /// preset does. Structure is untouched; chromaticity moves.
    static func tinted(_ image: CGImage, red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage {
        let context = makeContext(width: image.width, height: image.height, flipped: false)
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.draw(image, in: rect)
        context.setBlendMode(.multiply)
        context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
        context.fill(rect)
        return context.makeImage()!
    }

    /// Round-trips through JPEG so recompression artefacts are real, not simulated.
    static func jpegRoundTrip(_ image: CGImage, quality: Double) -> CGImage {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        CGImageDestinationFinalize(destination)
        let source = CGImageSourceCreateWithData(data, nil)!
        return CGImageSourceCreateImageAtIndex(source, 0, nil)!
    }

    static func solid(_ level: Double, width: Int = 1600, height: Int = 1200) -> CGImage {
        let context = makeContext(width: width, height: height)
        let c = CGFloat(min(1, max(0, level)))
        context.setFillColor(CGColor(srgbRed: c, green: c, blue: c, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// Blends two scenes, so consecutive steps are near-identical and the ends are not.
    static func morph(_ seedA: Int, _ seedB: Int, step: Int, of count: Int) -> CGImage {
        let context = makeContext(width: 1600, height: 1200, flipped: false)
        let rect = CGRect(x: 0, y: 0, width: 1600, height: 1200)
        context.draw(scene(seedA), in: rect)
        context.setAlpha(CGFloat(step) / CGFloat(count - 1))
        context.draw(scene(seedB), in: rect)
        return context.makeImage()!
    }

    static func png(_ image: CGImage) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// Wraps a rendered image as a fingerprinted library item.
    static func indexed(
        _ id: Int,
        _ image: CGImage,
        kind: MediaKind = .photo,
        takenAt: TimeInterval? = 0,
        stamp: Double = 0
    ) -> IndexedAsset {
        let record = AssetRecord(
            id: "asset-\(id)",
            kind: kind,
            pixelWidth: image.width,
            pixelHeight: image.height,
            creationDate: takenAt.map { Date(timeIntervalSince1970: 1_700_000_000 + $0) },
            modificationDate: nil,
            duration: 0,
            isFavorite: false,
            burstIdentifier: nil,
            isEdited: false,
            isHDR: false,
            byteSize: Int64(image.width * image.height / 3)
        )
        let thumbnail = ThumbnailData(cgImage: image, edge: Tuning.thumbnailEdge)!
        return IndexedAsset(
            record: record,
            fingerprint: Fingerprinter.fingerprint(thumbnail, assetID: record.id, stamp: stamp)
        )
    }

    /// An RGBA context whose user space has its origin at the top left, matching the
    /// Android generator's coordinates so the two corpora describe the same scenes.
    private static func makeContext(width: Int, height: Int, flipped: Bool = true) -> CGContext {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        if flipped {
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
        }
        return context
    }
}
