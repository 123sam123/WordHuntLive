import Foundation

public struct SolveResult: Sendable {
    public var boardVersion: Int
    /// Ranked best-first, already excluding played words.
    public var ranked: [WordCandidate]
    public var totalWordsFound: Int
    public var duration: TimeInterval

    public var best: WordCandidate? { ranked.first }

    public static let empty = SolveResult(boardVersion: 0, ranked: [], totalWordsFound: 0, duration: 0)
}

/// Scores and ranks solver output.
///
/// Ranking: expected score (score × recognition confidence) descending, then simpler
/// gesture, then longer word, then alphabetical — fully deterministic.
public struct Recommender: Sendable {
    public var solver: any WordSolver
    public var scoring: any ScoringEngine
    public var minLength: Int

    public init(solver: any WordSolver, scoring: any ScoringEngine, minLength: Int = 3) {
        self.solver = solver
        self.scoring = scoring
        self.minLength = minLength
    }

    public func solve(_ board: BoardState, excluding played: Set<String> = []) -> SolveResult {
        let start = DispatchTime.now().uptimeNanoseconds
        let found = solver.solve(board, minLength: minLength)
        let ranked = rank(found, on: board, excluding: played)
        let dt = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        return SolveResult(boardVersion: board.version, ranked: ranked, totalWordsFound: found.count, duration: dt)
    }

    public func rank(_ candidates: [WordCandidate], on board: BoardState, excluding played: Set<String> = []) -> [WordCandidate] {
        candidates
            .filter { !played.contains($0.word) }
            .map { c -> WordCandidate in
                var c = c
                c.score = scoring.score(word: c.word, path: c.coordinates, board: board)
                return c
            }
            .sorted(by: Self.isBetter)
    }

    static func isBetter(_ a: WordCandidate, _ b: WordCandidate) -> Bool {
        if abs(a.expectedScore - b.expectedScore) > 1e-6 { return a.expectedScore > b.expectedScore }
        if a.complexity != b.complexity { return a.complexity < b.complexity }
        if a.word.count != b.word.count { return a.word.count > b.word.count }
        return a.word < b.word
    }
}
