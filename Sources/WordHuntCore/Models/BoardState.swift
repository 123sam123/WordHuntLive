import CoreGraphics
import Foundation

public enum BoardParseError: Error, Equatable, LocalizedError {
    case wrongLetterCount(expected: Int, got: Int)
    case invalidCharacter(Character)

    public var errorDescription: String? {
        switch self {
        case let .wrongLetterCount(expected, got): "Expected \(expected) letters, got \(got)."
        case let .invalidCharacter(c): "Invalid character “\(c)”. Use A–Z (or ? for unknown)."
        }
    }
}

/// The persistent, versioned model of the board. Tiles are stored row-major.
public struct BoardState: Equatable, Sendable {
    public let rows: Int
    public let columns: Int
    public private(set) var tiles: [Tile]
    public var timestamp: Date
    /// Incremented every time any letter changes.
    public private(set) var version: Int

    public init(rows: Int = 4, columns: Int = 4, letters: [Character],
                confidences: [Double]? = nil,
                geometry: BoardGeometry? = nil,
                version: Int = 1, timestamp: Date = Date()) {
        precondition(letters.count == rows * columns, "letters must be rows*columns")
        self.rows = rows
        self.columns = columns
        self.version = version
        self.timestamp = timestamp
        let geo = geometry ?? BoardGeometry.unit(rows: rows, columns: columns)
        tiles = letters.enumerated().map { i, ch in
            let coord = GridCoord.from(index: i, columns: columns)
            let rect = geo.tileRect(coord)
            return Tile(row: coord.row, column: coord.column, letter: ch,
                        center: CGPoint(x: rect.midX, y: rect.midY), boundingBox: rect,
                        confidence: confidences?[i] ?? (ch == Tile.unknown ? 0 : 1))
        }
    }

    /// An all-unknown board, used before recognition has run.
    public static func empty(rows: Int = 4, columns: Int = 4, geometry: BoardGeometry? = nil) -> BoardState {
        BoardState(rows: rows, columns: columns,
                   letters: Array(repeating: Tile.unknown, count: rows * columns),
                   geometry: geometry, version: 0)
    }

    /// Parses "STON AERI PLDC MBGH", multi-line grids, or "S T O N / ..." — any
    /// whitespace or punctuation is ignored. `?` marks an unknown tile.
    public static func parse(_ text: String, rows: Int = 4, columns: Int = 4) throws -> BoardState {
        var letters: [Character] = []
        for ch in text.uppercased() {
            if ch.isWhitespace || ch == "," || ch == "/" || ch == "|" { continue }
            guard ch == Tile.unknown || ("A"..."Z").contains(ch) else { throw BoardParseError.invalidCharacter(ch) }
            letters.append(ch)
        }
        guard letters.count == rows * columns else {
            throw BoardParseError.wrongLetterCount(expected: rows * columns, got: letters.count)
        }
        return BoardState(rows: rows, columns: columns, letters: letters)
    }

    // MARK: Access

    public var letters: [[Character]] {
        (0..<rows).map { r in (0..<columns).map { c in tiles[r * columns + c].letter } }
    }

    public var flatLetters: [Character] { tiles.map(\.letter) }

    public subscript(_ coord: GridCoord) -> Tile {
        tiles[coord.index(columns: columns)]
    }

    public func contains(_ coord: GridCoord) -> Bool {
        coord.row >= 0 && coord.row < rows && coord.column >= 0 && coord.column < columns
    }

    public var allCoords: [GridCoord] { tiles.map(\.coord) }

    public var isComplete: Bool { tiles.allSatisfy(\.isKnown) }

    /// Mean recognition confidence across tiles.
    public var confidence: Double {
        tiles.map(\.confidence).reduce(0, +) / Double(tiles.count)
    }

    /// Text form, one row per line with spaces between letters.
    public var gridText: String {
        letters.map { $0.map(String.init).joined(separator: " ") }.joined(separator: "\n")
    }

    public var compactText: String { String(flatLetters) }

    // MARK: Mutation

    public struct LetterUpdate: Equatable, Sendable {
        public var coord: GridCoord
        public var letter: Character
        public var confidence: Double
        /// Tile point value (dots) if it was read; nil leaves it unknown.
        public var value: Int?
        public init(coord: GridCoord, letter: Character, confidence: Double, value: Int? = nil) {
            self.coord = coord
            self.letter = letter
            self.confidence = confidence
            self.value = value
        }
    }

    /// Applies letter updates. Bumps `version` only if at least one letter or value actually changed.
    /// Returns the coordinates whose letter or value changed.
    @discardableResult
    public mutating func apply(_ updates: [LetterUpdate], at time: Date = Date()) -> Set<GridCoord> {
        var changed = Set<GridCoord>()
        for u in updates where contains(u.coord) {
            let i = u.coord.index(columns: columns)
            let letterChanged = tiles[i].letter != u.letter
            let newValue = u.value ?? (letterChanged ? nil : tiles[i].value)
            if letterChanged || newValue != tiles[i].value { changed.insert(u.coord) }
            tiles[i].letter = u.letter
            tiles[i].confidence = u.confidence
            tiles[i].value = newValue
            tiles[i].state = .stable
        }
        if !changed.isEmpty {
            version += 1
            timestamp = time
        }
        return changed
    }

    public mutating func setState(_ state: TileState, at coord: GridCoord) {
        guard contains(coord) else { return }
        tiles[coord.index(columns: columns)].state = state
    }

    /// Re-lays tile rectangles for a new geometry (e.g. after calibration) without touching letters.
    public mutating func relayout(_ geometry: BoardGeometry) {
        for i in tiles.indices {
            let rect = geometry.tileRect(tiles[i].coord)
            tiles[i].boundingBox = rect
            tiles[i].center = CGPoint(x: rect.midX, y: rect.midY)
        }
    }
}
