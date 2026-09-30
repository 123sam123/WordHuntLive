@testable import WordHuntCore
import XCTest

final class SolverTests: XCTestCase {
    func testAdjacency() {
        let c = GridCoord(1, 1)
        let neighbours: [GridCoord] = Fixtures.board.allCoords.filter { c.isAdjacent(to: $0) }
        let expected: [GridCoord] = .path((0, 0), (0, 1), (0, 2), (1, 0), (1, 2), (2, 0), (2, 1), (2, 2))
        XCTAssertEqual(Set(neighbours), Set(expected))
        XCTAssertFalse(c.isAdjacent(to: c))
        XCTAssertFalse(GridCoord(0, 0).isAdjacent(to: GridCoord(0, 2)))
        XCTAssertEqual(GridCoord(3, 3).description, "(3,3)")
    }

    func testCornerHasThreeNeighbours() {
        let board = Fixtures.board
        XCTAssertEqual(board.allCoords.filter { GridCoord(0, 0).isAdjacent(to: $0) }.count, 3)
    }

    func testFindsExpectedWordsWithValidPaths() {
        let board = Fixtures.board
        let found = TrieBoardSolver(trie: Fixtures.trie).solve(board, minLength: 3)
        let words = Set(found.map(\.word))
        // S T O N / A E R I / P L D C / M B G H
        for w in ["STORE", "ASTER", "NOTE", "SEA", "TEA", "EAT", "SET", "TOE", "ORE", "LED", "PLED",
                  "SEAL", "TEAL", "RID", "IRE", "DIRE"] {
            XCTAssertTrue(words.contains(w), "missing \(w)")
        }
        // Not traceable: STONE/TONE (E isn't adjacent to N), ROD (D isn't adjacent to O),
        // STAR/RATE (no path), NOON (reuses O), ZEBRA (no Z), TOTE (only one T), AT (below min length).
        for w in ["STONE", "TONE", "ROD", "STAR", "RATE", "NOON", "ZEBRA", "TOTE", "AT"] {
            XCTAssertFalse(words.contains(w), "unexpected \(w)")
        }
        for c in found {
            XCTAssertTrue(PathValidator.isValid(c.coordinates, spells: c.word, on: board), "bad path for \(c.word)")
        }
    }

    func testNoTileReuse() {
        // A board with a single O — "NOON" needs two Os and two Ns.
        let board = try! BoardState.parse("NOXX XXXX XXXX XXXX")
        let found = TrieBoardSolver(trie: Trie(words: ["NOON", "NON", "ONO"])).solve(board, minLength: 3)
        XCTAssertTrue(found.isEmpty, "found \(found.map(\.word)) by reusing tiles")

        let board2 = try! BoardState.parse("NOXX NOXX XXXX XXXX")
        let found2 = TrieBoardSolver(trie: Trie(words: ["NOON"])).solve(board2, minLength: 3)
        XCTAssertEqual(found2.map(\.word), ["NOON"])
        XCTAssertEqual(Set(found2[0].coordinates).count, 4)
    }

    func testDiagonalMovement() {
        // C A T only along the main diagonal.
        let board = try! BoardState.parse("CXXX XAXX XXTX XXXX")
        let found = TrieBoardSolver(trie: Trie(words: ["CAT"])).solve(board, minLength: 3)
        XCTAssertEqual(found.first?.coordinates, .path((0, 0), (1, 1), (2, 2)))
        // Anti-diagonal too.
        let board2 = try! BoardState.parse("XXXC XXAX XTXX XXXX")
        XCTAssertEqual(TrieBoardSolver(trie: Trie(words: ["CAT"])).solve(board2, minLength: 3).first?.coordinates,
                       .path((0, 3), (1, 2), (2, 1)))
    }

    func testRejectsNonAdjacentJump() {
        let board = try! BoardState.parse("CXAX XXXX XXXX TXXX")
        XCTAssertTrue(TrieBoardSolver(trie: Trie(words: ["CAT"])).solve(board, minLength: 3).isEmpty)
    }

    func testMinimumLengthIsConfigurable() {
        let solver = TrieBoardSolver(trie: Fixtures.trie)
        let words3 = Set(solver.solve(Fixtures.board, minLength: 3).map(\.word))
        let words5 = Set(solver.solve(Fixtures.board, minLength: 5).map(\.word))
        XCTAssertTrue(words3.contains("SEA"))
        XCTAssertFalse(words5.contains("SEA"))
        XCTAssertEqual(words5, ["STORE", "ASTER"])
    }

    func testUnknownTilesAreSkipped() {
        let board = try! BoardState.parse("ST?N AERI PLDC MBGH")
        let words = Set(TrieBoardSolver(trie: Fixtures.trie).solve(board, minLength: 3).map(\.word))
        XCTAssertFalse(words.contains("STORE"))
        XCTAssertTrue(words.contains("SEA"))
    }

    func testDuplicateWordKeepsSimplestPath() {
        // "EAT" can be traced two ways; the straight one should win.
        let board = try! BoardState.parse("EATX AXXX TXXX XXXX")
        let found = TrieBoardSolver(trie: Trie(words: ["EAT"])).solve(board, minLength: 3)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].complexity, 2.0)
    }

    func testFullDictionarySolveIsFast() {
        let trie = Fixtures.fullTrie
        let solver = TrieBoardSolver(trie: trie)
        let board = Fixtures.board
        _ = solver.solve(board, minLength: 3) // warm
        let start = Date()
        let found = solver.solve(board, minLength: 3)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThan(found.count, 50)
        XCTAssertLessThan(elapsed, 0.05, "solve took \(elapsed * 1000) ms")
        for c in found { XCTAssertTrue(PathValidator.isValid(c.coordinates, spells: c.word, on: board)) }
    }
}
