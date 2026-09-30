import Foundation

/// Small deterministic PRNG (SplitMix64) so simulated boards/collapses are reproducible.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A stand-in for a "tiles collapse after a word" game, used to exercise the tracker and
/// UI without a phone. Played tiles vanish, tiles above fall, new letters drop in on top.
public struct SimulatedGame: Sendable {
    public let rows: Int
    public let columns: Int
    public private(set) var letters: [Character]
    private var rng: SeededGenerator

    public struct Move: Equatable, Sendable {
        public var from: GridCoord
        public var to: GridCoord
    }

    public struct CollapseResult: Equatable, Sendable {
        public var removed: [GridCoord]
        /// Surviving tiles that moved down (from != to).
        public var moves: [Move]
        /// Cells filled with brand-new letters; `fromRow` is the virtual row above the board they fall from.
        public var spawned: [(coord: GridCoord, letter: Character, fromRow: Int)]
        public var changed: Set<GridCoord>

        public static func == (a: CollapseResult, b: CollapseResult) -> Bool {
            a.removed == b.removed && a.moves == b.moves && a.changed == b.changed
                && a.spawned.map(\.coord) == b.spawned.map(\.coord) && a.spawned.map(\.letter) == b.spawned.map(\.letter)
        }
    }

    public init(board: BoardState, seed: UInt64 = 42) {
        rows = board.rows
        columns = board.columns
        letters = board.flatLetters
        rng = SeededGenerator(seed: seed)
    }

    public static func random(seed: UInt64, rows: Int = 4, columns: Int = 4) -> SimulatedGame {
        var rng = SeededGenerator(seed: seed)
        let letters = (0..<(rows * columns)).map { _ in randomLetter(&rng) }
        var game = SimulatedGame(board: BoardState(rows: rows, columns: columns, letters: letters), seed: seed &+ 1)
        game.rng = rng
        return game
    }

    public var board: BoardState { BoardState(rows: rows, columns: columns, letters: letters) }

    public subscript(_ c: GridCoord) -> Character { letters[c.index(columns: columns)] }

    public mutating func collapse(_ path: [GridCoord]) -> CollapseResult {
        let removed = Set(path)
        var moves: [Move] = []
        var spawned: [(GridCoord, Character, Int)] = []
        var next = letters
        for col in 0..<columns {
            // Survivors, bottom-up.
            let survivors = (0..<rows).reversed().map { GridCoord($0, col) }.filter { !removed.contains($0) }
            var target = rows - 1
            for s in survivors {
                let to = GridCoord(target, col)
                next[to.index(columns: columns)] = self[s]
                if to != s { moves.append(Move(from: s, to: to)) }
                target -= 1
            }
            // Fill remaining top cells with new letters, falling from above the board.
            let empty = target + 1
            for r in 0..<empty {
                let ch = Self.randomLetter(&rng)
                next[GridCoord(r, col).index(columns: columns)] = ch
                spawned.append((GridCoord(r, col), ch, r - empty))
            }
        }
        // Every removed cell is refilled by a falling survivor or a new tile, so the cells whose
        // tile changed are exactly the move destinations plus the spawned cells.
        let changed = Set(moves.map(\.to)).union(spawned.map(\.0))
        letters = next
        return CollapseResult(removed: path, moves: moves, spawned: spawned, changed: changed)
    }

    /// English-ish letter frequencies (per mille), so random boards contain real words.
    static let frequencies: [(Character, Int)] = [
        ("E", 120), ("T", 90), ("A", 85), ("O", 75), ("I", 75), ("N", 70), ("S", 70), ("R", 65), ("H", 45),
        ("L", 45), ("D", 40), ("C", 30), ("U", 30), ("M", 25), ("P", 22), ("G", 20), ("B", 16), ("Y", 16),
        ("F", 15), ("W", 14), ("K", 8), ("V", 8), ("X", 2), ("Z", 2), ("J", 2), ("Q", 1),
    ]

    static func randomLetter(_ rng: inout SeededGenerator) -> Character {
        let total = frequencies.reduce(0) { $0 + $1.1 }
        var pick = Int(rng.next() % UInt64(total))
        for (ch, w) in frequencies {
            if pick < w { return ch }
            pick -= w
        }
        return "E"
    }
}

public enum BoardDiff {
    /// Cells whose letter differs between two boards of the same size.
    public static func changedCoords(_ a: BoardState, _ b: BoardState) -> Set<GridCoord> {
        precondition(a.rows == b.rows && a.columns == b.columns)
        return Set(zip(a.tiles, b.tiles).filter { $0.letter != $1.letter }.map(\.0.coord))
    }
}
