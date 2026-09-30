import Foundation

/// A tile's letter isolated and normalized for recognition.
public struct NormalizedGlyph: Sendable {
    public static let side = 24
    /// `side`×`side` coverage map (1 = ink), glyph scaled to fit a 20px box, centred.
    public var feature: [Float]
    /// Ink bounding-box aspect (width / height) — separates I from wide letters.
    public var aspect: Float
    /// Fraction of the tile covered by the glyph's bounding box.
    public var coverage: Float
    public var isBlank: Bool
    /// Binary glyph as black ink on white, padded — the input handed to Vision.
    public var cleanImage: GrayImage

    public static let blank = NormalizedGlyph(feature: Array(repeating: 0, count: side * side), aspect: 0, coverage: 0,
                                              isBlank: true, cleanImage: GrayImage(width: 8, height: 8, fill: 1))
}

/// Per-tile preprocessing: contrast normalization → Otsu threshold → polarity detection →
/// connected components (drop tile borders, corner score digits, specks) → crop → rescale.
public enum GlyphNormalizer {
    /// Resolution tiles are sampled at before processing.
    public static let tileSide = 64

    struct Binarized {
        var px: [Float]
        var mask: [Bool]
        var inkIsDark: Bool
        var w: Int
        var h: Int
    }

    /// Steps 1–3: contrast stretch, Otsu threshold, polarity. Nil for a flat (blank) tile.
    static func binarize(_ tile: GrayImage) -> Binarized? {
        let w = tile.width, h = tile.height
        var px = tile.pixels

        // 1. Contrast stretch between the 2nd and 98th percentiles.
        let sorted = px.sorted()
        let lo = sorted[Int(Float(sorted.count - 1) * 0.02)], hi = sorted[Int(Float(sorted.count - 1) * 0.98)]
        guard hi - lo > 0.08 else { return nil } // flat tile: nothing printed on it
        for i in px.indices { px[i] = min(1, max(0, (px[i] - lo) / (hi - lo))) }

        // 2. Otsu threshold.
        let t = otsu(px)

        // 3. Polarity: the tile face (background) dominates the outer ring; ink is the other class.
        //    (Centre-area majority fails for dense letters like M and W.)
        var dark = 0, total = 0
        let ring = max(2, w / 12)
        for y in 0..<h {
            for x in 0..<w where x < ring || x >= w - ring || y < ring || y >= h - ring {
                total += 1
                if px[y * w + x] < t { dark += 1 }
            }
        }
        let inkIsDark = dark * 2 < total
        var mask = [Bool](repeating: false, count: w * h)
        for i in px.indices { mask[i] = inkIsDark ? px[i] < t : px[i] >= t }
        return Binarized(px: px, mask: mask, inkIsDark: inkIsDark, w: w, h: h)
    }

    public static func normalize(_ tile: GrayImage) -> NormalizedGlyph {
        guard let bin = binarize(tile) else { return .blank }
        let w = bin.w, h = bin.h, px = bin.px, mask = bin.mask, inkIsDark = bin.inkIsDark

        // 4. Connected components; keep the ones that make up the central glyph.
        let comps = components(mask, w, h)
        let cx0 = w / 4, cx1 = w - w / 4, cy0 = h / 4, cy1 = h - h / 4
        let central = comps.filter { c in
            let spansTile = c.maxX - c.minX > w * 9 / 10 || c.maxY - c.minY > h * 9 / 10
            let hitsCentre = c.maxX >= cx0 && c.minX <= cx1 && c.maxY >= cy0 && c.minY <= cy1
            return hitsCentre && !spansTile && c.area >= 6
        }
        guard let largest = central.map(\.area).max() else { return .blank }
        let keep = central.filter { $0.area * 100 >= largest * 12 }
        var minX = w, minY = h, maxX = 0, maxY = 0
        var ink = [Bool](repeating: false, count: w * h)
        for c in keep {
            minX = min(minX, c.minX); minY = min(minY, c.minY); maxX = max(maxX, c.maxX); maxY = max(maxY, c.maxY)
            for i in c.pixels { ink[i] = true }
        }
        let bw = maxX - minX + 1, bh = maxY - minY + 1
        guard bh >= h / 8 else { return .blank } // too small to be the tile's letter

        // 5. Scale the ink box into the feature canvas, preserving aspect.
        let side = NormalizedGlyph.side
        let box: Float = 20
        let scale = box / Float(max(bw, bh))
        let ow = Float(bw) * scale, oh = Float(bh) * scale
        let ox = (Float(side) - ow) / 2, oy = (Float(side) - oh) / 2
        var feature = [Float](repeating: 0, count: side * side)
        let ss = 3 // supersampling per axis
        for fy in 0..<side {
            for fx in 0..<side {
                var acc = 0
                for sy in 0..<ss {
                    for sx in 0..<ss {
                        let gx = (Float(fx) + (Float(sx) + 0.5) / Float(ss) - ox) / scale
                        let gy = (Float(fy) + (Float(sy) + 0.5) / Float(ss) - oy) / scale
                        guard gx >= 0, gy >= 0, gx < Float(bw), gy < Float(bh) else { continue }
                        if ink[(minY + Int(gy)) * w + minX + Int(gx)] { acc += 1 }
                    }
                }
                feature[fy * side + fx] = Float(acc) / Float(ss * ss)
            }
        }

        // 6. Clean image for Vision: the anti-aliased glyph as dark ink on white, other
        //    components (borders, corner digits) erased, generous padding.
        let pad = max(bw, bh) / 2 + 4
        let cw = bw + pad * 2, ch = bh + pad * 2
        var clean = GrayImage(width: cw, height: ch, fill: 1)
        for y in 0..<bh {
            for x in 0..<bw {
                let i = (minY + y) * w + minX + x
                // Keep grey anti-aliasing next to kept ink; blank out anything else.
                let v = inkIsDark ? px[i] : 1 - px[i]
                let nearInk = ink[i] || (x > 0 && ink[i - 1]) || (x < bw - 1 && ink[i + 1])
                    || (y > 0 && ink[i - w]) || (y < bh - 1 && ink[i + w])
                clean[x + pad, y + pad] = nearInk ? v : 1
            }
        }

        return NormalizedGlyph(feature: feature, aspect: Float(bw) / Float(bh),
                               coverage: Float(bw * bh) / Float(w * h), isBlank: false, cleanImage: clean)
    }

    static func otsu(_ px: [Float]) -> Float {
        var hist = [Int](repeating: 0, count: 64)
        for v in px { hist[min(63, Int(v * 64))] += 1 }
        let total = Float(px.count)
        var sumAll: Float = 0
        for i in 0..<64 { sumAll += Float(i) * Float(hist[i]) }
        var sumB: Float = 0, wB: Float = 0, best: Float = -1, threshold = 32
        for i in 0..<64 {
            wB += Float(hist[i])
            guard wB > 0 else { continue }
            let wF = total - wB
            if wF == 0 { break }
            sumB += Float(i) * Float(hist[i])
            let mB = sumB / wB, mF = (sumAll - sumB) / wF
            let between = wB * wF * (mB - mF) * (mB - mF)
            if between > best { best = between; threshold = i }
        }
        return (Float(threshold) + 1) / 64
    }

    struct Component {
        var pixels: [Int] = []
        var minX = Int.max, minY = Int.max, maxX = 0, maxY = 0
        var area: Int { pixels.count }
    }

    static func components(_ mask: [Bool], _ w: Int, _ h: Int) -> [Component] {
        var seen = [Bool](repeating: false, count: mask.count)
        var out: [Component] = []
        var stack: [Int] = []
        for start in mask.indices where mask[start] && !seen[start] {
            var c = Component()
            stack.append(start)
            seen[start] = true
            while let i = stack.popLast() {
                let x = i % w, y = i / w
                c.pixels.append(i)
                c.minX = min(c.minX, x); c.maxX = max(c.maxX, x); c.minY = min(c.minY, y); c.maxY = max(c.maxY, y)
                if x > 0, mask[i - 1], !seen[i - 1] { seen[i - 1] = true; stack.append(i - 1) }
                if x < w - 1, mask[i + 1], !seen[i + 1] { seen[i + 1] = true; stack.append(i + 1) }
                if y > 0, mask[i - w], !seen[i - w] { seen[i - w] = true; stack.append(i - w) }
                if y < h - 1, mask[i + w], !seen[i + w] { seen[i + w] = true; stack.append(i + w) }
            }
            out.append(c)
        }
        return out
    }
}
