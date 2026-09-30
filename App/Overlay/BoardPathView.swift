import SwiftUI
import WordHuntCore

/// Draws the 4x4 board and the recommended path: highlighted tiles, a glowing connecting
/// line that draws itself in, direction arrows and numbered badges. Everything is laid out
/// from the candidate's real tile coordinates.
struct BoardPathView: View {
    let board: BoardState
    let candidate: WordCandidate?
    var showConfidence = false
    /// Draw each tile's point value as dots under the letter (dot-scoring games).
    var dotValue: ((Tile) -> Int?)?
    var onTileTap: ((GridCoord) -> Void)?

    @State private var progress: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let layout = BoardLayout(side: side, rows: board.rows, columns: board.columns)
            ZStack(alignment: .topLeading) {
                tiles(layout)
                if let candidate, candidate.coordinates.count > 1 {
                    PathLine(points: candidate.coordinates.map(layout.center))
                        .trim(from: 0, to: progress)
                        .stroke(Theme.path.opacity(0.35), style: StrokeStyle(lineWidth: layout.cell * 0.30, lineCap: .round, lineJoin: .round))
                        .blur(radius: 6)
                    PathLine(points: candidate.coordinates.map(layout.center))
                        .trim(from: 0, to: progress)
                        .stroke(Theme.path, style: StrokeStyle(lineWidth: layout.cell * 0.11, lineCap: .round, lineJoin: .round))
                }
                letters(layout)
                if let candidate {
                    markers(candidate, layout)
                        .opacity(progress >= 0.999 ? 1 : 0.0)
                }
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .aspectRatio(CGFloat(board.columns) / CGFloat(board.rows), contentMode: .fit)
        .onChange(of: candidate?.word) { _, _ in redraw() }
        .onChange(of: board.version) { _, _ in redraw() }
    }

    private func redraw() {
        progress = 0
        withAnimation(.easeOut(duration: 0.28)) { progress = 1 }
    }

    // MARK: Tiles

    private func tiles(_ layout: BoardLayout) -> some View {
        let onPath = Set(candidate?.coordinates ?? [])
        return ForEach(board.tiles, id: \.coord) { tile in
            let rect = layout.tileRect(tile.coord)
            let highlighted = onPath.contains(tile.coord)
            ZStack {
                RoundedRectangle(cornerRadius: rect.width * 0.18, style: .continuous)
                    .fill(tileFill(tile, highlighted: highlighted))
                RoundedRectangle(cornerRadius: rect.width * 0.18, style: .continuous)
                    .strokeBorder(tileStroke(tile, highlighted: highlighted), lineWidth: highlighted ? 2 : 1)
                if showConfidence {
                    Text(String(format: "%.0f", tile.confidence * 100))
                        .font(Theme.mono(rect.width * 0.13))
                        .foregroundStyle(confidenceColor(tile.confidence))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(rect.width * 0.08)
                }
            }
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .onTapGesture { onTileTap?(tile.coord) }
            .animation(.easeOut(duration: 0.2), value: tile.letter)
        }
    }

    /// Letters sit above the path line so the route never hides what's on the tile.
    private func letters(_ layout: BoardLayout) -> some View {
        let onPath = Set(candidate?.coordinates ?? [])
        return ForEach(board.tiles, id: \.coord) { tile in
            let rect = layout.tileRect(tile.coord)
            VStack(spacing: rect.width * 0.02) {
                Text(tile.isKnown ? String(tile.letter) : "?")
                    .font(.system(size: rect.width * 0.46, weight: .heavy, design: .rounded))
                    .foregroundStyle(tile.isKnown ? Theme.tileText : Theme.secondaryText)
                if let n = dotValue?(tile), n > 0 {
                    HStack(spacing: rect.width * 0.04) {
                        ForEach(0..<n, id: \.self) { _ in
                            Circle().frame(width: rect.width * 0.07, height: rect.width * 0.07)
                        }
                    }
                    // Solid dots were read from the screen; faded ones come from the fallback table.
                    .foregroundStyle(tile.value != nil ? Theme.path : Theme.secondaryText)
                }
            }
            .shadow(color: onPath.contains(tile.coord) ? Theme.background.opacity(0.9) : .clear, radius: 3)
            .shadow(color: onPath.contains(tile.coord) ? Theme.background.opacity(0.9) : .clear, radius: 1)
            .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.2), value: tile.letter)
        }
    }

    private func tileFill(_ tile: Tile, highlighted: Bool) -> Color {
        switch tile.state {
        case .new: return Theme.good.opacity(0.28)
        case .disappearing, .falling: return Theme.warn.opacity(0.18)
        case .stable: return highlighted ? Theme.path.opacity(0.16) : Theme.tile
        }
    }

    private func tileStroke(_ tile: Tile, highlighted: Bool) -> Color {
        if highlighted { return Theme.path.opacity(0.9) }
        if tile.isKnown, tile.confidence < 0.6 { return Theme.bad.opacity(0.8) }
        return Color.white.opacity(0.06)
    }

    private func confidenceColor(_ c: Double) -> Color {
        c >= 0.85 ? Theme.good : c >= 0.6 ? Theme.warn : Theme.bad
    }

    // MARK: Arrows + numbered badges

    private func markers(_ candidate: WordCandidate, _ layout: BoardLayout) -> some View {
        Canvas { ctx, _ in
            let pts = candidate.coordinates.map(layout.center)
            // Direction arrows at each segment's midpoint.
            for i in 1..<max(pts.count, 1) {
                let a = pts[i - 1], b = pts[i]
                let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                let angle = atan2(b.y - a.y, b.x - a.x)
                let s = layout.cell * 0.13
                var arrow = Path()
                arrow.move(to: CGPoint(x: s, y: 0))
                arrow.addLine(to: CGPoint(x: -s * 0.8, y: -s * 0.85))
                arrow.addLine(to: CGPoint(x: -s * 0.35, y: 0))
                arrow.addLine(to: CGPoint(x: -s * 0.8, y: s * 0.85))
                arrow.closeSubpath()
                let t = CGAffineTransform(translationX: mid.x, y: mid.y).rotated(by: angle)
                ctx.fill(arrow.applying(t), with: .color(Theme.background))
            }
            // Numbered badges in each tile's top-left corner; start and end rings.
            for (i, coord) in candidate.coordinates.enumerated() {
                let rect = layout.tileRect(coord)
                let r = layout.cell * 0.15
                let c = CGPoint(x: rect.minX + r * 1.25, y: rect.minY + r * 1.25)
                let color: Color = i == 0 ? Theme.pathStart : (i == candidate.coordinates.count - 1 ? Theme.pathEnd : Theme.path)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(color))
                ctx.draw(Text("\(i + 1)").font(.system(size: r * 1.2, weight: .black, design: .rounded)).foregroundColor(Theme.background), at: c)
                if i == 0 || i == candidate.coordinates.count - 1 {
                    let ring = rect.insetBy(dx: -2, dy: -2)
                    ctx.stroke(Path(roundedRect: ring, cornerRadius: rect.width * 0.2), with: .color(color), lineWidth: 3)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

struct BoardLayout {
    let side: CGFloat
    let rows: Int
    let columns: Int
    var cell: CGFloat { side / CGFloat(max(rows, columns)) }
    var gap: CGFloat { cell * 0.08 }

    func tileRect(_ c: GridCoord) -> CGRect {
        CGRect(x: CGFloat(c.column) * cell + gap / 2, y: CGFloat(c.row) * cell + gap / 2,
               width: cell - gap, height: cell - gap)
    }

    func center(_ c: GridCoord) -> CGPoint {
        CGPoint(x: (CGFloat(c.column) + 0.5) * cell, y: (CGFloat(c.row) + 0.5) * cell)
    }
}

/// Polyline through tile centres; a Shape so `.trim` can animate the draw-in.
struct PathLine: Shape {
    let points: [CGPoint]
    func path(in _: CGRect) -> Path {
        var p = Path()
        guard let first = points.first else { return p }
        p.move(to: first)
        for pt in points.dropFirst() { p.addLine(to: pt) }
        return p
    }
}
