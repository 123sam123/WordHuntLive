import CoreGraphics
import Foundation

/// Paints a fake phone screen containing a 4x4 letter board, so the whole vision pipeline
/// (fingerprints → tracker → OCR → solver) can run without an iPhone.
public struct BoardRenderer: Sendable {
    public var frameSize = CGSize(width: 390, height: 844)
    /// Board location in pixels (origin top-left) — what calibration should find.
    public var boardRect = CGRect(x: 35, y: 300, width: 320, height: 320)
    public var fontName = "ArialRoundedMTBold"
    /// When set, each tile gets this many value dots under its letter (dot-scoring games).
    public var dotValues: [Character: Int]?

    public init() {}

    /// Board location normalized to the frame (what a correct calibration stores).
    public var normalizedBoardRect: CGRect {
        CGRect(x: boardRect.minX / frameSize.width, y: boardRect.minY / frameSize.height,
               width: boardRect.width / frameSize.width, height: boardRect.height / frameSize.height)
    }

    public struct TileAppearance: Sendable {
        public var letter: Character?
        /// Vertical offset in cells (negative = above its final slot, used while falling).
        public var offsetCells: CGFloat = 0
        public var alpha: CGFloat = 1
        public var highlighted = false
        /// Explicit dot count; nil uses the renderer's `dotValues`.
        public var dots: Int?
        public init(letter: Character?, offsetCells: CGFloat = 0, alpha: CGFloat = 1, highlighted: Bool = false) {
            self.letter = letter
            self.offsetCells = offsetCells
            self.alpha = alpha
            self.highlighted = highlighted
        }
    }

    public func render(_ tiles: [TileAppearance], rows: Int = 4, columns: Int = 4, timestamp: TimeInterval = 0) -> Frame {
        let w = Int(frameSize.width), h = Int(frameSize.height), bpr = w * 4
        var bytes = [UInt8](repeating: 0, count: bpr * h)
        bytes.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return }
            // Flip so we can think in top-left coordinates like the rest of the pipeline.
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            ctx.setFillColor(red: 0.20, green: 0.45, blue: 0.30, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setFillColor(red: 0.12, green: 0.30, blue: 0.19, alpha: 1)
            ctx.addPath(CGPath(roundedRect: boardRect.insetBy(dx: -8, dy: -8), cornerWidth: 14, cornerHeight: 14, transform: nil))
            ctx.fillPath()

            let cw = boardRect.width / CGFloat(columns), ch = boardRect.height / CGFloat(rows)
            ctx.saveGState()
            ctx.clip(to: boardRect.insetBy(dx: -8, dy: -8))
            for (i, t) in tiles.enumerated() {
                guard let letter = t.letter, t.alpha > 0 else { continue }
                let r = i / columns, c = i % columns
                let cell = CGRect(x: boardRect.minX + CGFloat(c) * cw, y: boardRect.minY + (CGFloat(r) + t.offsetCells) * ch,
                                  width: cw, height: ch).insetBy(dx: cw * 0.05, dy: ch * 0.05)
                ctx.setAlpha(t.alpha)
                if t.highlighted {
                    ctx.setFillColor(red: 0.98, green: 0.98, blue: 0.95, alpha: 1)
                } else {
                    ctx.setFillColor(red: 0.95, green: 0.86, blue: 0.66, alpha: 1)
                }
                ctx.addPath(CGPath(roundedRect: cell, cornerWidth: cw * 0.14, cornerHeight: cw * 0.14, transform: nil))
                ctx.fillPath()
                // Text draws in unflipped space.
                ctx.saveGState()
                ctx.translateBy(x: 0, y: cell.midY * 2)
                ctx.scaleBy(x: 1, y: -1)
                GlyphRenderer.draw(letter, in: ctx, rect: cell, fontName: fontName, heightFraction: 0.5,
                                   color: CGColor(red: 0.16, green: 0.12, blue: 0.08, alpha: 1))
                ctx.restoreGState()
                let n = t.dots ?? dotValues?[letter] ?? 0
                if n > 0 {
                    let d = cell.width * 0.065, gap = d * 0.9
                    let total = CGFloat(n) * d + CGFloat(n - 1) * gap
                    ctx.setFillColor(red: 0.16, green: 0.12, blue: 0.08, alpha: 1)
                    for k in 0..<n {
                        let x = cell.midX - total / 2 + CGFloat(k) * (d + gap)
                        ctx.fillEllipse(in: CGRect(x: x, y: cell.minY + cell.height * 0.84, width: d, height: d))
                    }
                }
                ctx.setAlpha(1)
            }
            ctx.restoreGState()
        }
        return Frame(bgra: bytes, width: w, height: h, bytesPerRow: bpr, timestamp: timestamp)
    }

    /// A still frame of a settled board.
    public func render(_ board: BoardState, highlighted: Set<GridCoord> = [], timestamp: TimeInterval = 0) -> Frame {
        render(board.tiles.map { TileAppearance(letter: $0.isKnown ? $0.letter : nil, highlighted: highlighted.contains($0.coord)) },
               rows: board.rows, columns: board.columns, timestamp: timestamp)
    }
}

/// Keyframed animations the simulated feed plays. Times are in seconds.
public enum SimulatedAnimation {
    /// Drag highlight (tiles light up one by one), then either collapse or return to normal.
    public static func appearance(before: SimulatedGame, after: SimulatedGame?, collapse: SimulatedGame.CollapseResult?,
                                  path: [GridCoord], t: TimeInterval) -> [BoardRenderer.TileAppearance]? {
        let cols = before.columns
        let dragPerTile = 0.07, drag = dragPerTile * Double(path.count)
        let fade = 0.12, fall = 0.25
        let base = before.board.tiles.map { BoardRenderer.TileAppearance(letter: $0.letter) }

        if t < drag + 0.05 {
            var tiles = base
            for (k, c) in path.enumerated() where t >= Double(k) * dragPerTile {
                tiles[c.index(columns: cols)].highlighted = true
            }
            return tiles
        }
        guard let after, let collapse else { return nil } // static game: back to normal
        let t2 = t - drag - 0.05
        if t2 < fade {
            var tiles = base
            for c in path { tiles[c.index(columns: cols)].alpha = 1 - t2 / fade; tiles[c.index(columns: cols)].highlighted = true }
            return tiles
        }
        let t3 = t2 - fade
        guard t3 < fall else { return nil } // done: caller renders `after` statically
        let p = CGFloat(t3 / fall)
        let ease = p * p // gravity-ish
        var tiles = after.board.tiles.map { BoardRenderer.TileAppearance(letter: $0.letter) }
        for m in collapse.moves {
            tiles[m.to.index(columns: cols)].offsetCells = CGFloat(m.from.row - m.to.row) * (1 - ease)
        }
        for s in collapse.spawned {
            tiles[s.coord.index(columns: cols)].offsetCells = CGFloat(s.fromRow - s.coord.row) * (1 - ease)
        }
        return tiles
    }
}
