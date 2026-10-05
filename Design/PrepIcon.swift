// Prepares a supplied artwork file as an iOS app icon.
//
// Does not repaint anything: it finds the artwork inside the surrounding white
// margin, crops to it, and rescales to 1024×1024 opaque.
//
// The crop matters. iOS masks every app icon to its own superellipse, so artwork
// that already carries rounded corners and a white border would render as a rounded
// icon inside a rounded icon. Trimming past the existing corner radius lets the
// background run to all four edges, which is what the system mask expects.
//
// Usage: PrepIcon <input> <output> [insetFraction]

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count >= 3 else { fatalError("usage: PrepIcon <input> <output> [insetFraction]") }
let inputPath = arguments[1]
let outputPath = arguments[2]
let insetFraction = arguments.count > 3 ? (Double(arguments[3]) ?? 0) : 0

guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: inputPath) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fatalError("could not read \(inputPath)")
}

let width = image.width
let height = image.height
print("source: \(width)×\(height)")

// MARK: Read pixels

let bytesPerRow = width * 4
var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
pixels.withUnsafeMutableBytes { raw in
    guard let base = raw.baseAddress,
          let context = CGContext(
            data: base, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else { fatalError("could not rasterise source") }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
}

// MARK: Find the artwork

/// A pixel counts as artwork when it is meaningfully darker than the white page it
/// sits on, or when it is transparent-backed. The threshold sits low enough to
/// ignore the soft drop shadow around the artwork, which would otherwise inflate
/// the box by a few pixels on every side.
func isArtwork(x: Int, y: Int) -> Bool {
    let offset = y * bytesPerRow + x * 4
    let r = Int(pixels[offset])
    let g = Int(pixels[offset + 1])
    let b = Int(pixels[offset + 2])
    let a = Int(pixels[offset + 3])
    if a < 16 { return false }
    return r < 225 || g < 225 || b < 225
}

var minX = width, minY = height, maxX = -1, maxY = -1
for y in 0..<height {
    for x in 0..<width where isArtwork(x: x, y: y) {
        if x < minX { minX = x }
        if x > maxX { maxX = x }
        if y < minY { minY = y }
        if y > maxY { maxY = y }
    }
}
guard maxX > minX, maxY > minY else { fatalError("found no artwork") }
print("artwork bounds: x \(minX)…\(maxX)  y \(minY)…\(maxY)  (\(maxX - minX + 1)×\(maxY - minY + 1))")

// Square it up about the artwork's centre so nothing is stretched.
//
// Takes the *smaller* dimension. The measured box is not perfectly square — the
// soft drop shadow reads as artwork along some edges and not others — and squaring
// up to the larger side would pull the surrounding white page back in along the
// shorter axis, which is precisely what this crop exists to remove.
let centreX = Double(minX + maxX) / 2
let centreY = Double(minY + maxY) / 2
var side = Double(min(maxX - minX + 1, maxY - minY + 1))

// Trim past the existing corner radius so the background reaches every edge.
side -= side * insetFraction * 2

// The bounds above were measured in pixel space, whose origin is top-left, but
// Core Graphics draws from the bottom-left. Convert the y coordinate rather than
// flipping the context: `draw(image:in:)` already emits the image the right way up,
// so a context flip would turn the artwork upside down.
let cropOrigin = CGPoint(
    x: centreX - side / 2,
    y: Double(height) - (centreY + side / 2)
)
print("crop: origin (\(Int(cropOrigin.x)), \(Int(cropOrigin.y))) side \(Int(side))")

// MARK: Render at icon size

let output = 1024
guard let destinationContext = CGContext(
    data: nil, width: output, height: output,
    bitsPerComponent: 8, bytesPerRow: output * 4,
    space: CGColorSpaceCreateDeviceRGB(),
    // App icons must not carry an alpha channel.
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else { fatalError("could not create output context") }

destinationContext.interpolationQuality = .high
destinationContext.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
destinationContext.fill(CGRect(x: 0, y: 0, width: output, height: output))

// Scale the crop up to the full canvas.
let scale = Double(output) / side
destinationContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
destinationContext.translateBy(x: -cropOrigin.x, y: -cropOrigin.y)
destinationContext.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

guard let rendered = destinationContext.makeImage() else { fatalError("could not render") }
guard let destination = CGImageDestinationCreateWithURL(
    URL(fileURLWithPath: outputPath) as CFURL, UTType.png.identifier as CFString, 1, nil
) else { fatalError("could not create destination") }
CGImageDestinationAddImage(destination, rendered, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("could not write PNG") }

print("wrote \(outputPath) at \(output)×\(output)")
