import CoreGraphics
import Foundation

public enum TileState: String, Codable, Sendable {
    /// Letter is known and the tile hasn't changed recently.
    case stable
    /// The tile's image changed away from its reference (e.g. tile being consumed or highlighted).
    case disappearing
    /// The tile is in motion (frame-to-frame change).
    case falling
    /// The tile settled with different content and its letter is being (re)recognized.
    case new
}

public struct Tile: Hashable, Codable, Sendable {
    public var row: Int
    public var column: Int
    /// Uppercase A–Z, or `Tile.unknown` when not yet recognized.
    public var letter: Character
    /// Centre of the tile in board-space (see `BoardGeometry`).
    public var center: CGPoint
    public var boundingBox: CGRect
    /// Recognition confidence in 0...1.
    public var confidence: Double
    public var state: TileState
    /// Point value printed on the tile (e.g. number of dots under the letter), when the game shows one.
    public var value: Int?

    public static let unknown: Character = "?"

    public init(row: Int, column: Int, letter: Character, center: CGPoint = .zero,
                boundingBox: CGRect = .zero, confidence: Double = 1, state: TileState = .stable) {
        self.row = row
        self.column = column
        self.letter = letter
        self.center = center
        self.boundingBox = boundingBox
        self.confidence = confidence
        self.state = state
    }

    public var coord: GridCoord { GridCoord(row, column) }
    public var isKnown: Bool { letter != Tile.unknown }

    private enum CodingKeys: String, CodingKey { case row, column, letter, center, boundingBox, confidence, state, value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        row = try c.decode(Int.self, forKey: .row)
        column = try c.decode(Int.self, forKey: .column)
        letter = try c.decode(String.self, forKey: .letter).first ?? Tile.unknown
        center = try c.decode(CGPoint.self, forKey: .center)
        boundingBox = try c.decode(CGRect.self, forKey: .boundingBox)
        confidence = try c.decode(Double.self, forKey: .confidence)
        state = try c.decode(TileState.self, forKey: .state)
        value = try c.decodeIfPresent(Int.self, forKey: .value)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(row, forKey: .row)
        try c.encode(column, forKey: .column)
        try c.encode(String(letter), forKey: .letter)
        try c.encode(center, forKey: .center)
        try c.encode(boundingBox, forKey: .boundingBox)
        try c.encode(confidence, forKey: .confidence)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(value, forKey: .value)
    }
}
