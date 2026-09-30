import Foundation

/// Finds every dictionary word that can be traced on a board.
public protocol WordSolver: Sendable {
    /// One candidate per distinct word (the easiest path when several exist). Candidates are
    /// unscored: `score` is 0 and `confidence` is filled from tile confidences.
    func solve(_ board: BoardState, minLength: Int) -> [WordCandidate]
}

/// Boggle-style solver: DFS from every tile over the 8-neighbourhood, never reusing a tile,
/// walking the trie in lockstep so dead prefixes are abandoned immediately.
public struct TrieBoardSolver: WordSolver {
    public let trie: Trie

    public init(trie: Trie) {
        self.trie = trie
    }

    public func solve(_ board: BoardState, minLength: Int = 3) -> [WordCandidate] {
        let cols = board.columns, count = board.rows * board.columns
        precondition(count <= 64, "board too large for bitmask")
        let letterIdx: [Int] = board.flatLetters.map { Trie.index(of: $0) ?? -1 }
        let neighbors: [[Int]] = (0..<count).map { i in
            let c = GridCoord.from(index: i, columns: cols)
            return board.allCoords.filter { c.isAdjacent(to: $0) }.map { $0.index(columns: cols) }
        }

        var best: [String: (path: [Int], complexity: Double)] = [:]
        var path: [Int] = []
        var chars: [UInt8] = []
        path.reserveCapacity(count)
        chars.reserveCapacity(count)

        func visit(_ i: Int, node: Trie.Node, used: UInt64) {
            guard let next = trie.child(of: node, letterIndex: letterIdx[i]) else { return }
            path.append(i)
            chars.append(UInt8(65 + letterIdx[i]))
            if chars.count >= minLength, trie.isWord(next) {
                let word = String(decoding: chars, as: UTF8.self)
                let coords = path.map { GridCoord.from(index: $0, columns: cols) }
                let cx = GestureComplexity.score(coords)
                if let existing = best[word] {
                    if cx < existing.complexity { best[word] = (path, cx) }
                } else {
                    best[word] = (path, cx)
                }
            }
            let usedNow = used | (1 << UInt64(i))
            for n in neighbors[i] where usedNow & (1 << UInt64(n)) == 0 && letterIdx[n] >= 0 {
                visit(n, node: next, used: usedNow)
            }
            path.removeLast()
            chars.removeLast()
        }

        for i in 0..<count where letterIdx[i] >= 0 {
            visit(i, node: Trie.root, used: 0)
        }

        return best.map { word, entry in
            let coords = entry.path.map { GridCoord.from(index: $0, columns: cols) }
            let conf = coords.reduce(1.0) { $0 * board[$1].confidence }
            return WordCandidate(word: word, coordinates: coords, complexity: entry.complexity, confidence: conf)
        }
    }
}

/// Validates that a path is legal on a board: in-bounds, adjacent steps, no reuse, spells `word`.
public enum PathValidator {
    public static func isValid(_ path: [GridCoord], spells word: String, on board: BoardState) -> Bool {
        guard path.count == word.count, Set(path).count == path.count else { return false }
        for (i, c) in path.enumerated() {
            guard board.contains(c) else { return false }
            if i > 0, !path[i - 1].isAdjacent(to: c) { return false }
        }
        return String(path.map { board[$0].letter }) == word
    }
}
