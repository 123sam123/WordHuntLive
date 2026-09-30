import Foundation

/// Assigns points to a word. Swap implementations to match a specific game's rules.
public protocol ScoringEngine: Sendable {
    var name: String { get }
    func score(word: String, path: [GridCoord], board: BoardState) -> Int
}

/// Points by word length. Default table is GamePigeon Word Hunt's:
/// 3→100, 4→400, 5→800, 6→1400, 7→1800, 8→2200, then +400 per extra letter.
public struct LengthTableScoring: ScoringEngine, Codable, Equatable {
    public var table: [Int: Int]
    /// Points added per letter beyond the longest length in `table`.
    public var extraPerLetter: Int

    public init(table: [Int: Int], extraPerLetter: Int) {
        self.table = table
        self.extraPerLetter = extraPerLetter
    }

    public static let wordHunt = LengthTableScoring(
        table: [3: 100, 4: 400, 5: 800, 6: 1400, 7: 1800, 8: 2200], extraPerLetter: 400)

    public var name: String { "Length table" }

    public func score(word: String, path: [GridCoord], board: BoardState) -> Int {
        let n = word.count
        if let pts = table[n] { return pts }
        guard let maxLen = table.keys.max(), n > maxLen, let top = table[maxLen] else { return 0 }
        return top + (n - maxLen) * extraPerLetter
    }
}

/// Sum of per-letter values times a length multiplier — for Scrabble-like word games.
public struct LetterValueScoring: ScoringEngine, Codable, Equatable {
    public var letterValues: [String: Int]
    /// Multiplier applied to the letter sum: 1 + lengthBonus * (length - 3), floored at 1.
    public var lengthBonus: Double

    public init(letterValues: [String: Int], lengthBonus: Double) {
        self.letterValues = letterValues
        self.lengthBonus = lengthBonus
    }

    public static let scrabble: LetterValueScoring = {
        var v: [String: Int] = [:]
        let groups: [(String, Int)] = [("AEILNORSTU", 1), ("DG", 2), ("BCMP", 3), ("FHVWY", 4),
                                       ("K", 5), ("JX", 8), ("QZ", 10)]
        for (letters, pts) in groups { for ch in letters { v[String(ch)] = pts } }
        return LetterValueScoring(letterValues: v, lengthBonus: 0.25)
    }()

    public var name: String { "Letter values" }

    public func score(word: String, path: [GridCoord], board: BoardState) -> Int {
        let sum = word.reduce(0) { $0 + (letterValues[String($1)] ?? 1) }
        let mult = max(1.0, 1.0 + lengthBonus * Double(word.count - 3))
        return Int((Double(sum) * mult * 10).rounded())
    }
}

/// For games that print a value under each letter ("letters with more dots are worth more"):
/// score = (sum of the dots on the word's tiles) × pointsPerDot × a multiplier that grows with length.
/// Dots are read live from each tile; `fallbackDots` covers tiles whose dots couldn't be read.
public struct TileValueScoring: ScoringEngine, Codable, Equatable {
    public var pointsPerDot: Int
    /// Multiplier by word length; lengths above the table add `extraMultiplierPerLetter` each.
    public var lengthMultipliers: [Int: Double]
    public var extraMultiplierPerLetter: Double
    public var fallbackDots: [String: Int]

    public init(pointsPerDot: Int, lengthMultipliers: [Int: Double], extraMultiplierPerLetter: Double, fallbackDots: [String: Int]) {
        self.pointsPerDot = pointsPerDot
        self.lengthMultipliers = lengthMultipliers
        self.extraMultiplierPerLetter = extraMultiplierPerLetter
        self.fallbackDots = fallbackDots
    }

    /// Starting guesses from the game's tutorial screenshot; edit them in Settings to match the game.
    public static let dots: TileValueScoring = {
        var v: [String: Int] = [:]
        let groups: [(String, Int)] = [("ERSTLN", 1), ("AIOUCMDG", 2), ("BHPWFVY", 3), ("KJXQZ", 4)]
        for (letters, n) in groups { for ch in letters { v[String(ch)] = n } }
        return TileValueScoring(pointsPerDot: 10,
                                lengthMultipliers: [3: 1, 4: 1.5, 5: 2, 6: 2.5, 7: 3, 8: 3.5],
                                extraMultiplierPerLetter: 0.5, fallbackDots: v)
    }()

    public var name: String { "Tile dots" }

    public func multiplier(forLength n: Int) -> Double {
        if let m = lengthMultipliers[n] { return m }
        guard let maxLen = lengthMultipliers.keys.max(), n > maxLen, let top = lengthMultipliers[maxLen] else {
            return n < (lengthMultipliers.keys.min() ?? 0) ? 0 : 1
        }
        return top + Double(n - maxLen) * extraMultiplierPerLetter
    }

    public func dots(at coord: GridCoord, on board: BoardState) -> Int {
        let tile = board[coord]
        return tile.value ?? fallbackDots[String(tile.letter)] ?? 1
    }

    public func score(word: String, path: [GridCoord], board: BoardState) -> Int {
        let sum = path.reduce(0) { $0 + dots(at: $1, on: board) }
        return Int((Double(sum * pointsPerDot) * multiplier(forLength: word.count)).rounded())
    }
}

/// User-editable, persistable scoring configuration.
public struct ScoringConfig: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable, Identifiable {
        case lengthTable, tileValues, letterValues
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .lengthTable: "Word length (Word Hunt)"
            case .tileValues: "Tile dots × length multiplier"
            case .letterValues: "Letter values (Scrabble-like)"
            }
        }
    }

    public var mode: Mode = .lengthTable
    public var lengthTable: LengthTableScoring = .wordHunt
    public var letterValues: LetterValueScoring = .scrabble
    public var tileValues: TileValueScoring = .dots

    public init() {}

    private enum CodingKeys: String, CodingKey { case mode, lengthTable, letterValues, tileValues }

    // Tolerant decoding so settings saved by older versions keep working.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? c.decode(Mode.self, forKey: .mode)) ?? .lengthTable
        lengthTable = (try? c.decode(LengthTableScoring.self, forKey: .lengthTable)) ?? .wordHunt
        letterValues = (try? c.decode(LetterValueScoring.self, forKey: .letterValues)) ?? .scrabble
        tileValues = (try? c.decode(TileValueScoring.self, forKey: .tileValues)) ?? .dots
    }

    public func makeEngine() -> any ScoringEngine {
        switch mode {
        case .lengthTable: lengthTable
        case .tileValues: tileValues
        case .letterValues: letterValues
        }
    }
}
