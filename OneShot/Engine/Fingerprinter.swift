import Foundation

/// Turns raw thumbnail pixels into a `Fingerprint`.
///
/// Every metric here is derived from a single 128×128 decode. That is the whole
/// design: image decoding dominates the scan's wall clock, so the pipeline pays for
/// it once per asset and extracts structure, colour, shape, sharpness and exposure
/// from the same buffer.
enum Fingerprinter {

    /// Computes every still-image metric from one thumbnail.
    static func fingerprint(
        _ thumbnail: ThumbnailData,
        assetID: String,
        stamp: Double,
        keyframeHashes: [UInt64] = []
    ) -> Fingerprint {
        let luma = luminance(from: thumbnail)
        let stats = tonalStatistics(of: luma)

        return Fingerprint(
            assetID: assetID,
            dHash: differenceHash(from: luma, edge: thumbnail.edge),
            histogram: colourHistogram(from: thumbnail),
            shape: shapeSignature(from: luma, edge: thumbnail.edge),
            sharpness: laplacianVariance(of: luma, edge: thumbnail.edge),
            exposure: stats.exposure,
            meanLuma: stats.mean,
            keyframeHashes: keyframeHashes,
            stamp: stamp
        )
    }

    // MARK: - Luminance

    /// Rec. 601 luma, 0…1, one value per pixel.
    static func luminance(from thumbnail: ThumbnailData) -> [Float] {
        let count = thumbnail.edge * thumbnail.edge
        var output = [Float](repeating: 0, count: count)
        thumbnail.rgba.withUnsafeBufferPointer { pixels in
            for index in 0..<count {
                let offset = index * 4
                let r = Float(pixels[offset])
                let g = Float(pixels[offset + 1])
                let b = Float(pixels[offset + 2])
                output[index] = (0.299 * r + 0.587 * g + 0.114 * b) / 255
            }
        }
        return output
    }

    // MARK: - Difference hash

    /// 64-bit dHash.
    ///
    /// The luminance plane is box-downsampled to a 9×8 grid and each bit records
    /// whether a cell is brighter than the one to its right. Because it encodes
    /// *relative* gradients rather than absolute values, it survives exposure
    /// shifts, rescaling and re-compression — which is exactly the "same photo,
    /// saved twice" case.
    static func differenceHash(from luma: [Float], edge: Int) -> UInt64 {
        let gridWidth = Tuning.hashEdge + 1   // 9
        let gridHeight = Tuning.hashEdge      // 8
        let grid = boxDownsample(luma, sourceEdge: edge, width: gridWidth, height: gridHeight)

        var hash: UInt64 = 0
        var bit = 0
        for row in 0..<gridHeight {
            for column in 0..<Tuning.hashEdge {
                let left = grid[row * gridWidth + column]
                let right = grid[row * gridWidth + column + 1]
                if left < right {
                    hash |= (1 << UInt64(bit))
                }
                bit += 1
            }
        }
        return hash
    }

    // MARK: - Shape signature

    /// Horizontal and vertical luminance differences on a 16×16 grid, as a unit
    /// vector. See `ShapeSignature` for why gradients rather than the grid itself.
    static func shapeSignature(from luma: [Float], edge: Int) -> ShapeSignature {
        let n = ShapeSignature.gridEdge
        let grid = boxDownsample(luma, sourceEdge: edge, width: n, height: n)

        var vector: [Float] = []
        vector.reserveCapacity(ShapeSignature.dimensions)
        for row in 0..<n {
            for column in 0..<(n - 1) {
                vector.append(grid[row * n + column + 1] - grid[row * n + column])
            }
        }
        for row in 0..<(n - 1) {
            for column in 0..<n {
                vector.append(grid[(row + 1) * n + column] - grid[row * n + column])
            }
        }

        let length = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        // Below this the frame is flat to within rounding, and its direction would
        // be noise. Treated as blank rather than normalised up into something
        // that looks like structure.
        guard length > 1e-4 else {
            return ShapeSignature(vector: [Float](repeating: 0, count: ShapeSignature.dimensions))
        }
        return ShapeSignature(vector: vector.map { $0 / length })
    }

    /// Area-averages a square plane down to an arbitrary width × height grid.
    ///
    /// Averaging rather than point-sampling matters: point-sampling a downscale
    /// makes the hash sensitive to which exact pixels survive, so two encodes of the
    /// same image can disagree.
    private static func boxDownsample(_ source: [Float], sourceEdge: Int, width: Int, height: Int) -> [Float] {
        var output = [Float](repeating: 0, count: width * height)
        for row in 0..<height {
            let y0 = row * sourceEdge / height
            let y1 = max(y0 + 1, (row + 1) * sourceEdge / height)
            for column in 0..<width {
                let x0 = column * sourceEdge / width
                let x1 = max(x0 + 1, (column + 1) * sourceEdge / width)

                var total: Float = 0
                var samples = 0
                for y in y0..<y1 {
                    let rowOffset = y * sourceEdge
                    for x in x0..<x1 {
                        total += source[rowOffset + x]
                        samples += 1
                    }
                }
                output[row * width + column] = samples > 0 ? total / Float(samples) : 0
            }
        }
        return output
    }

    // MARK: - Colour histogram

    /// Normalised 8×8 chromaticity histogram.
    ///
    /// This is the colour-proportion signal. Binning by chromaticity rather than raw
    /// RGB makes it invariant to exposure: scaling every channel by the same factor,
    /// which is what brightening a photo does, cancels out of r/(r+g+b) entirely.
    ///
    /// It is blind to composition — a photo and its mirror image score 1.0 — which
    /// is precisely why it is used as a *corroborating* signal alongside dHash
    /// rather than on its own.
    static func colourHistogram(from thumbnail: ThumbnailData) -> HistogramSignature {
        var bins = [Float](repeating: 0, count: HistogramSignature.binCount)
        let pixelCount = thumbnail.edge * thumbnail.edge
        let axis = HistogramSignature.axisBins
        // Below this total intensity the channel ratios are dominated by sensor and
        // compression noise, so near-black pixels are pooled into the achromatic
        // centre instead of being scattered at random.
        let darkFloor = 30
        let centre = (axis / 2) * axis + (axis / 2)

        thumbnail.rgba.withUnsafeBufferPointer { pixels in
            for index in 0..<pixelCount {
                let offset = index * 4
                let r = Int(pixels[offset])
                let g = Int(pixels[offset + 1])
                let b = Int(pixels[offset + 2])
                let sum = r + g + b

                guard sum >= darkFloor else {
                    bins[centre] += 1
                    continue
                }
                let red = min(axis - 1, r * axis / sum)
                let green = min(axis - 1, g * axis / sum)
                bins[red * axis + green] += 1
            }
        }

        let scale = 1 / Float(max(1, pixelCount))
        for index in 0..<bins.count {
            bins[index] *= scale
        }
        return HistogramSignature(bins: bins)
    }

    // MARK: - Sharpness

    /// Variance of the Laplacian — the standard focus measure.
    ///
    /// A blurred frame has little high-frequency energy, so the second derivative
    /// stays near zero everywhere and its variance collapses. Blur survives
    /// downscaling, so comparing two 128×128 thumbnails still ranks the sharp
    /// original above the soft burst frame. Absolute values are meaningless across
    /// different scenes; the scorer only ever compares within one group.
    static func laplacianVariance(of luma: [Float], edge: Int) -> Float {
        guard edge > 2 else { return 0 }
        var total: Float = 0
        var totalOfSquares: Float = 0
        var count: Float = 0

        for y in 1..<(edge - 1) {
            let row = y * edge
            let above = (y - 1) * edge
            let below = (y + 1) * edge
            for x in 1..<(edge - 1) {
                let response = luma[above + x]
                    + luma[below + x]
                    + luma[row + x - 1]
                    + luma[row + x + 1]
                    - 4 * luma[row + x]
                total += response
                totalOfSquares += response * response
                count += 1
            }
        }

        guard count > 0 else { return 0 }
        let mean = total / count
        let variance = totalOfSquares / count - mean * mean
        // Scaled purely so the numbers are pleasant to read when debugging.
        return max(0, variance) * 1000
    }

    // MARK: - Exposure

    private struct TonalStatistics {
        let mean: Float
        let exposure: Float
    }

    /// Rewards a frame that uses its tonal range without clipping either end.
    private static func tonalStatistics(of luma: [Float]) -> TonalStatistics {
        guard !luma.isEmpty else { return TonalStatistics(mean: 0, exposure: 0) }

        var histogram = [Int](repeating: 0, count: 256)
        var total: Float = 0
        for value in luma {
            total += value
            let bucket = min(255, max(0, Int(value * 255)))
            histogram[bucket] += 1
        }
        let mean = total / Float(luma.count)

        let clipped = Float(histogram[0] + histogram[1] + histogram[254] + histogram[255])
            / Float(luma.count)

        // 5th and 95th percentiles describe the usable range without letting a
        // handful of specular highlights claim the frame is well exposed.
        let low = percentile(histogram, count: luma.count, fraction: 0.05)
        let high = percentile(histogram, count: luma.count, fraction: 0.95)
        let range = Float(high - low) / 255

        let clippingScore = max(0, 1 - clipped * 1.5)
        let rangeScore = min(1, range / 0.8)
        let exposure = min(1, max(0, clippingScore * 0.6 + rangeScore * 0.4))

        return TonalStatistics(mean: mean, exposure: exposure)
    }

    private static func percentile(_ histogram: [Int], count: Int, fraction: Double) -> Int {
        let target = Int(Double(count) * fraction)
        var running = 0
        for bucket in 0..<histogram.count {
            running += histogram[bucket]
            if running >= target { return bucket }
        }
        return histogram.count - 1
    }
}
