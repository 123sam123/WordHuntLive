import CoreGraphics
import Foundation

/// Maps grid cells to rectangles. `boardRect` is expressed in whatever space the caller
/// uses — normalized frame coordinates (0…1, origin top-left) for capture, or a unit
/// square for simulation/UI.
public struct BoardGeometry: Codable, Equatable, Sendable {
    public var rows: Int
    public var columns: Int
    public var boardRect: CGRect
    /// Fraction of each cell trimmed on every side to skip gaps/borders (0 … 0.4).
    public var tileInset: Double

    public init(rows: Int = 4, columns: Int = 4, boardRect: CGRect, tileInset: Double = 0.06) {
        self.rows = rows
        self.columns = columns
        self.boardRect = boardRect
        self.tileInset = tileInset
    }

    public static func unit(rows: Int = 4, columns: Int = 4) -> BoardGeometry {
        BoardGeometry(rows: rows, columns: columns, boardRect: CGRect(x: 0, y: 0, width: 1, height: 1), tileInset: 0)
    }

    public var cellSize: CGSize {
        CGSize(width: boardRect.width / CGFloat(columns), height: boardRect.height / CGFloat(rows))
    }

    /// The full grid cell.
    public func cellRect(_ c: GridCoord) -> CGRect {
        let s = cellSize
        return CGRect(x: boardRect.minX + CGFloat(c.column) * s.width,
                      y: boardRect.minY + CGFloat(c.row) * s.height,
                      width: s.width, height: s.height)
    }

    /// The cell with `tileInset` removed — the region that contains the tile face.
    public func tileRect(_ c: GridCoord) -> CGRect {
        let r = cellRect(c)
        return r.insetBy(dx: r.width * tileInset, dy: r.height * tileInset)
    }

    public func center(_ c: GridCoord) -> CGPoint {
        let r = cellRect(c)
        return CGPoint(x: r.midX, y: r.midY)
    }

    /// Returns the same geometry with boardRect converted from normalized (0…1) to pixel space.
    public func scaled(toWidth w: CGFloat, height h: CGFloat) -> BoardGeometry {
        var g = self
        g.boardRect = CGRect(x: boardRect.minX * w, y: boardRect.minY * h,
                             width: boardRect.width * w, height: boardRect.height * h)
        return g
    }
}
