import Foundation

/// A tiny signature of a tile's appearance used for frame-to-frame change detection.
/// Much cheaper than OCR: 16×16 luma, z-normalized, plus the tile's mean colour.
public struct TileFingerprint: Sendable, Equatable {
    public static let side = 16

    /// Zero-mean, unit-variance luma (so brightness/contrast shifts don't register as change).
    public var shape: [Float]
    public var meanLuma: Float
    public var color: GrayImage.MeanColor

    public init(image: GrayImage, color: GrayImage.MeanColor) {
        let n = Float(image.pixels.count)
        let mean = image.pixels.reduce(0, +) / n
        let variance = image.pixels.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / n
        // Floor the std so a blank tile's sensor noise isn't amplified into "shape".
        let std = max(variance.squareRoot(), 0.04)
        shape = image.pixels.map { ($0 - mean) / std }
        meanLuma = mean
        self.color = color
    }

    public static func make(frame: Frame, rect: CGRect) -> TileFingerprint {
        let (img, color) = GrayImage.sample(frame, rect: rect, outW: side, outH: side, maxSamples: 3)
        return TileFingerprint(image: img, color: color)
    }

    /// Glyph/shape difference, roughly 0 (identical) … 1.5 (unrelated).
    public func shapeDistance(to other: TileFingerprint) -> Float {
        var acc: Float = 0
        for i in shape.indices { acc += abs(shape[i] - other.shape[i]) }
        return acc / Float(shape.count)
    }

    /// Colour/brightness difference in 0…1.
    public func colorDistance(to other: TileFingerprint) -> Float {
        max(abs(color.r - other.color.r), abs(color.g - other.color.g), abs(color.b - other.color.b),
            abs(meanLuma - other.meanLuma))
    }

    /// Combined change score. ≈0 for the same tile in consecutive frames; a letter swap
    /// or highlight typically scores > 0.25.
    public func distance(to other: TileFingerprint) -> Float {
        max(shapeDistance(to: other), colorDistance(to: other) * 3)
    }
}
