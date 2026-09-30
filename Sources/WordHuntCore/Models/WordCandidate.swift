import CoreGraphics
import Foundation

public struct PathPoint: Hashable, Sendable {
    public var row: Int
    public var column: Int
    /// Position in board-space (same space as `Tile.center`), or screen space when projected.
    public var point: CGPoint

    public init(row: Int, column: Int, point: CGPoint) {
        self.row = row
        self.column = column
        self.point = point
    }

    public var coord: GridCoord { GridCoord(row, column) }
}

public struct WordCandidate: Hashable, Sendable, Identifiable {
    public var word: String
    /// Tiles in the order they must be dragged through.
    public var coordinates: [GridCoord]
    public var score: Int
    /// Lower = easier to drag. See `GestureComplexity`.
    public var complexity: Double
    /// Probability all tiles in the path are recognized correctly (product of tile confidences).
    public var confidence: Double

    public init(word: String, coordinates: [GridCoord], score: Int = 0, complexity: Double = 0, confidence: Double = 1) {
        self.word = word
        self.coordinates = coordinates
        self.score = score
        self.complexity = complexity
        self.confidence = confidence
    }

    public var id: String { word }
    public var expectedScore: Double { Double(score) * confidence }

    /// Path points positioned at the centres of the board's tiles.
    public func path(on board: BoardState) -> [PathPoint] {
        coordinates.map { PathPoint(row: $0.row, column: $0.column, point: board[$0].center) }
    }
}
