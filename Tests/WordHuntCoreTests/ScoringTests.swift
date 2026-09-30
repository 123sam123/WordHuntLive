@testable import WordHuntCore
import XCTest

final class ScoringTests: XCTestCase {
    let board = Fixtures.board

    func testWordHuntLengthTable() {
        let s = LengthTableScoring.wordHunt
        XCTAssertEqual(s.score(word: "AB", path: [], board: board), 0)
        XCTAssertEqual(s.score(word: "SEA", path: [], board: board), 100)
        XCTAssertEqual(s.score(word: "TONE", path: [], board: board), 400)
        XCTAssertEqual(s.score(word: "STORE", path: [], board: board), 800)
        XCTAssertEqual(s.score(word: "ABCDEF", path: [], board: board), 1400)
        XCTAssertEqual(s.score(word: "ABCDEFGH", path: [], board: board), 2200)
        XCTAssertEqual(s.score(word: "ABCDEFGHIJ", path: [], board: board), 3000)
    }

    func testLetterValueScoring() {
        let s = LetterValueScoring.scrabble
        // Q(10)+U(1)+I(1)+Z(10) = 22, length 4 → ×1.25 → 27.5 → ×10 = 275
        XCTAssertEqual(s.score(word: "QUIZ", path: [], board: board), 275)
        XCTAssertEqual(s.score(word: "SEA", path: [], board: board), 30)
    }

    func testConfigSwitchesEngines() {
        var config = ScoringConfig()
        XCTAssertEqual(config.makeEngine().score(word: "STORE", path: [], board: board), 800)
        config.mode = .letterValues
        XCTAssertEqual(config.makeEngine().name, "Letter values")
        let data = try! JSONEncoder().encode(config)
        XCTAssertEqual(try! JSONDecoder().decode(ScoringConfig.self, from: data), config)
    }

    func testGestureComplexity() {
        XCTAssertEqual(GestureComplexity.score(.path((0, 0), (0, 1), (0, 2), (0, 3))), 3.0)       // straight
        XCTAssertEqual(GestureComplexity.score(.path((0, 0), (1, 1), (2, 2))), 2.5)               // straight diagonal
        XCTAssertEqual(GestureComplexity.score(.path((0, 0), (0, 1), (1, 1))), 2.5)               // one 90° turn
        XCTAssertEqual(GestureComplexity.score(.path((0, 0), (0, 1), (1, 0))), 3.25)              // 135° turn
        XCTAssertEqual(GestureComplexity.score([GridCoord(0, 0)]), 0)
    }

    func testRecommenderPrefersScoreThenSimplicity() {
        let rec = Recommender(solver: TrieBoardSolver(trie: Fixtures.trie), scoring: LengthTableScoring.wordHunt)
        let result = rec.solve(board)
        XCTAssertEqual(result.best?.word, "STORE")
        XCTAssertEqual(result.best?.score, 800)
        // Scores never increase down the list.
        let scores = result.ranked.map(\.expectedScore)
        XCTAssertEqual(scores, scores.sorted(by: >))
        // Among equal-score 4-letter words, complexity must be non-decreasing.
        let fours = result.ranked.filter { $0.word.count == 4 }
        XCTAssertEqual(fours.map(\.complexity), fours.map(\.complexity).sorted())
    }

    func testRecommenderExcludesPlayedWords() {
        let rec = Recommender(solver: TrieBoardSolver(trie: Fixtures.trie), scoring: LengthTableScoring.wordHunt)
        let result = rec.solve(board, excluding: ["STORE"])
        // ASTER (also 800) is next; it lost to STORE only on gesture complexity (5.5 vs 5.0).
        XCTAssertEqual(result.best?.word, "ASTER")
        XCTAssertEqual(rec.solve(board).ranked.prefix(2).map(\.complexity), [5.0, 5.5])
    }

    func testLowConfidenceLowersExpectedScore() {
        // Make the T (in both STORE and ASTER) uncertain: 800 × 0.4 = 320 < 400, so a sure
        // 4-letter word avoiding that tile should win.
        var board = Fixtures.board
        board.apply([.init(coord: GridCoord(0, 1), letter: "T", confidence: 0.4)])
        let rec = Recommender(solver: TrieBoardSolver(trie: Fixtures.trie), scoring: LengthTableScoring.wordHunt)
        let best = rec.solve(board).best!
        XCTAssertFalse(best.coordinates.contains(GridCoord(0, 1)))
        XCTAssertEqual(best.score, 400)
    }

    func testPathGenerationUsesTileCenters() {
        let rec = Recommender(solver: TrieBoardSolver(trie: Fixtures.trie), scoring: LengthTableScoring.wordHunt)
        let best = rec.solve(board).best!
        let path = best.path(on: board)
        XCTAssertEqual(path.map(\.coord), best.coordinates)
        // Unit geometry: tile (r,c) centre is ((c+.5)/4, (r+.5)/4)
        for p in path {
            XCTAssertEqual(p.point.x, (CGFloat(p.column) + 0.5) / 4, accuracy: 1e-9)
            XCTAssertEqual(p.point.y, (CGFloat(p.row) + 0.5) / 4, accuracy: 1e-9)
        }
        // STORE: S(0,0) T(0,1) O(0,2) R(1,2) E(1,1)
        XCTAssertEqual(best.coordinates, .path((0, 0), (0, 1), (0, 2), (1, 2), (1, 1)))
    }
}
