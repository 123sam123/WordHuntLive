import Foundation

/// A cell on the board grid. Row 0 is the top row, column 0 the leftmost column.
public struct GridCoord: Hashable, Codable, Sendable, CustomStringConvertible {
    public var row: Int
    public var column: Int

    public init(_ row: Int, _ column: Int) {
        self.row = row
        self.column = column
    }

    public init(row: Int, column: Int) {
        self.init(row, column)
    }

    /// Row-major index on a board with `columns` columns.
    public func index(columns: Int) -> Int { row * columns + column }

    public static func from(index: Int, columns: Int) -> GridCoord {
        GridCoord(index / columns, index % columns)
    }

    /// True for the 8 surrounding cells (orthogonal + diagonal), false for itself.
    public func isAdjacent(to other: GridCoord) -> Bool {
        let dr = abs(row - other.row), dc = abs(column - other.column)
        return max(dr, dc) == 1
    }

    public var description: String { "(\(row),\(column))" }
}
