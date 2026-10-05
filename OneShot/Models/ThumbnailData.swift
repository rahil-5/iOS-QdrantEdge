import Foundation
import CoreGraphics

/// Raw pixels for one asset, squashed to a fixed square.
///
/// The square squash is deliberate: dHash compares luminance gradients on a fixed
/// grid, so normalising every image to the same dimensions is what lets a 4032×3024
/// original and its 1280×960 export produce the same hash. Aspect ratio is *not*
/// lost — it is carried separately on `AssetRecord` and used as a rejection guard.
///
/// Deliberately free of UIKit and PhotoKit so the detection pipeline can be
/// exercised on synthetic images without a photo library behind it.
struct ThumbnailData: Sendable {
    /// `edge * edge * 4` bytes, RGBA, premultiplied, sRGB.
    let rgba: [UInt8]
    let edge: Int

    init(rgba: [UInt8], edge: Int) {
        self.rgba = rgba
        self.edge = edge
    }

    /// Draws a `CGImage` into a tightly packed RGBA byte buffer of the given edge.
    init?(cgImage: CGImage, edge: Int) {
        guard let rgba = Self.rasterize(cgImage: cgImage, edge: edge) else { return nil }
        self.init(rgba: rgba, edge: edge)
    }

    static func rasterize(cgImage: CGImage, edge: Int) -> [UInt8]? {
        let bytesPerRow = edge * 4
        let byteCount = bytesPerRow * edge
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 8)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)

        guard let context = CGContext(
            data: buffer,
            width: edge,
            height: edge,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }

        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: edge, height: edge))

        let typed = buffer.bindMemory(to: UInt8.self, capacity: byteCount)
        return Array(UnsafeBufferPointer(start: typed, count: byteCount))
    }
}

enum ThumbnailFailure: Error, Sendable {
    /// The asset no longer exists in the library.
    case missing
    /// The pixels live only in iCloud. OneShot never uses the network, so this
    /// asset cannot be scanned on this device.
    case notDownloaded
    /// PhotoKit returned an image that could not be rasterised.
    case undecodable
}
