import Foundation

/// Counts the value dots printed under a tile's letter (games where "letters with more dots
/// underneath are worth more points").
///
/// Works on the same binarized tile as the letter reader: finds the letter (largest central
/// ink blob), then small, roughly round blobs below it that sit on one horizontal line.
public enum DotCounter {
    public struct Reading: Sendable, Equatable {
        public var count: Int
        public var confidence: Double
    }

    /// Resolution tiles are sampled at for dot counting (dots are small; more pixels help).
    public static let tileSide = 96

    public static func count(_ tile: GrayImage) -> Reading? {
        guard let bin = GlyphNormalizer.binarize(tile) else { return nil }
        let w = bin.w, h = bin.h
        let comps = GlyphNormalizer.components(bin.mask, w, h).filter { c in
            // Ignore tile borders / shading that touch the crop edge.
            c.minX > 0 && c.minY > 0 && c.maxX < w - 1 && c.maxY < h - 1
        }
        // The letter: biggest blob overlapping the centre.
        let central = comps.filter { $0.maxX >= w / 4 && $0.minX <= w * 3 / 4 && $0.maxY >= h / 4 && $0.minY <= h * 3 / 4 }
        guard let glyph = central.max(by: { $0.area < $1.area }) else { return nil }
        let glyphCx = Float(glyph.minX + glyph.maxX) / 2

        // Dot candidates: small, compact, entirely below most of the letter.
        let maxDot = max(4, w / 7)
        let dots = comps.filter { c in
            let bw = c.maxX - c.minX + 1, bh = c.maxY - c.minY + 1
            let compact = bw <= maxDot && bh <= maxDot && Float(bw) / Float(bh) > 0.4 && Float(bw) / Float(bh) < 2.5
            let fill = Float(c.area) / Float(bw * bh)
            let below = c.minY > glyph.minY + (glyph.maxY - glyph.minY) * 3 / 4
            return c.area >= 2 && compact && fill > 0.4 && below && c.area * 6 < glyph.area
        }
        guard !dots.isEmpty else { return Reading(count: 0, confidence: 0.4) }

        // Keep the largest group sharing one baseline, roughly centred under the letter.
        let rowTol = Float(maxDot) * 0.6
        var best: [GlyphNormalizer.Component] = []
        for d in dots {
            let cy = Float(d.minY + d.maxY) / 2
            let row = dots.filter { abs(Float($0.minY + $0.maxY) / 2 - cy) <= rowTol }
            if row.count > best.count { best = row }
        }
        let rowCx = best.map { Float($0.minX + $0.maxX) / 2 }.reduce(0, +) / Float(best.count)
        let centred = abs(rowCx - glyphCx) < Float(w) * 0.15
        let areas = best.map { Float($0.area) }
        let mean = areas.reduce(0, +) / Float(areas.count)
        let spread = areas.map { abs($0 - mean) }.reduce(0, +) / Float(areas.count) / max(mean, 1)
        var conf = 0.95
        if !centred { conf -= 0.35 }
        if spread > 0.4 { conf -= 0.3 }
        if best.count > 5 { conf -= 0.4 }
        return Reading(count: best.count, confidence: max(0.1, conf))
    }
}
