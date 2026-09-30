@testable import WordHuntCore
import XCTest

final class BoardStateTests: XCTestCase {
    func testParseAcceptsSeveralFormats() throws {
        let a = try BoardState.parse(Fixtures.boardText)
        let b = try BoardState.parse("ston aeri pldc mbgh")
        let c = try BoardState.parse("S,T,O,N/A,E,R,I/P,L,D,C/M,B,G,H")
        XCTAssertEqual(a.flatLetters, b.flatLetters)
        XCTAssertEqual(a.flatLetters, c.flatLetters)
        XCTAssertEqual(a.letters[1], ["A", "E", "R", "I"])
        XCTAssertEqual(a.gridText, Fixtures.boardText)
    }

    func testParseErrors() {
        XCTAssertThrowsError(try BoardState.parse("ABC")) { err in
            XCTAssertEqual(err as? BoardParseError, .wrongLetterCount(expected: 16, got: 3))
        }
        XCTAssertThrowsError(try BoardState.parse("STO1 AERI PLDC MBGH")) { err in
            XCTAssertEqual(err as? BoardParseError, .invalidCharacter("1"))
        }
    }

    func testApplyBumpsVersionOnlyOnRealChange() {
        var board = Fixtures.board
        let v0 = board.version
        let unchanged = board.apply([.init(coord: GridCoord(0, 0), letter: "S", confidence: 0.9)])
        XCTAssertTrue(unchanged.isEmpty)
        XCTAssertEqual(board.version, v0)
        XCTAssertEqual(board[GridCoord(0, 0)].confidence, 0.9)

        let changed = board.apply([.init(coord: GridCoord(0, 0), letter: "Q", confidence: 1),
                                   .init(coord: GridCoord(3, 3), letter: "Z", confidence: 1)])
        XCTAssertEqual(changed, [GridCoord(0, 0), GridCoord(3, 3)])
        XCTAssertEqual(board.version, v0 + 1)
        XCTAssertEqual(board[GridCoord(3, 3)].letter, "Z")
    }

    func testGeometryAndRelayout() {
        let geo = BoardGeometry(boardRect: CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.4), tileInset: 0.1)
        XCTAssertEqual(geo.cellRect(GridCoord(0, 0)), CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.1))
        let tile = geo.tileRect(GridCoord(3, 3))
        XCTAssertEqual(tile.minX, 0.72, accuracy: 1e-9)
        XCTAssertEqual(tile.width, 0.16, accuracy: 1e-9)
        var board = Fixtures.board
        board.relayout(geo)
        XCTAssertEqual(board[GridCoord(0, 0)].center.x, 0.2, accuracy: 1e-9)
        let px = geo.scaled(toWidth: 1000, height: 500)
        XCTAssertEqual(px.boardRect, CGRect(x: 100, y: 100, width: 800, height: 200))
    }

    func testCalibrationPersistence() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = CalibrationStore(directory: dir)
        XCTAssertNil(store.latest())
        let cal = BoardCalibration.fromSelection(CGRect(x: 0.9, y: 0.5, width: 0.3, height: 0.3),
                                                 sourceID: "w:1", sourceName: "iPhone Mirroring")
        XCTAssertEqual(cal.geometry.boardRect.maxX, 1.0, accuracy: 1e-9, "clamped to frame")
        try store.save(cal)
        XCTAssertEqual(store.load(sourceID: "w:1"), cal)
        XCTAssertEqual(CalibrationStore(directory: dir).latest(), cal)
    }
}

final class SimulatedGameTests: XCTestCase {
    func testCollapseAppliesGravityAndSpawnsOnTop() {
        var game = SimulatedGame(board: Fixtures.board, seed: 7)
        // Remove S(0,0) T(0,1) O(0,2) R(1,2) E(1,1) — "STORE".
        let result = game.collapse(.path((0, 0), (0, 1), (0, 2), (1, 2), (1, 1)))
        let after = game.board
        // Column 0: S removed → A,P,M stay in place (below S), one new tile at the top.
        XCTAssertEqual(after.letters.map { $0[0] }.dropFirst(), ["A", "P", "M"])
        // Column 1: T,E removed → L,B stay at rows 2,3; two new tiles.
        XCTAssertEqual(after[GridCoord(2, 1)].letter, "L")
        XCTAssertEqual(after[GridCoord(3, 1)].letter, "B")
        // Column 2: O,R removed → D,G stay; column 3 untouched.
        XCTAssertEqual(after.letters.map { $0[3] }, ["N", "I", "C", "H"])
        XCTAssertEqual(result.spawned.count, 5)
        XCTAssertTrue(result.moves.isEmpty, "nothing sits above the removed tiles in this case")
        XCTAssertEqual(result.changed, Set([GridCoord].path((0, 0), (0, 1), (1, 1), (0, 2), (1, 2))))
    }

    func testCollapseMovesTilesDown() {
        var game = SimulatedGame(board: Fixtures.board, seed: 7)
        // Remove L(2,1) and B(3,1): E and T above fall two rows.
        let result = game.collapse(.path((2, 1), (3, 1)))
        XCTAssertEqual(result.moves, [.init(from: GridCoord(1, 1), to: GridCoord(3, 1)),
                                      .init(from: GridCoord(0, 1), to: GridCoord(2, 1))])
        XCTAssertEqual(game[GridCoord(3, 1)], "E")
        XCTAssertEqual(game[GridCoord(2, 1)], "T")
        XCTAssertEqual(result.changed, Set([GridCoord].path((0, 1), (1, 1), (2, 1), (3, 1))))
    }

    func testBoardDiffAndDeterminism() {
        var g1 = SimulatedGame(board: Fixtures.board, seed: 99)
        var g2 = SimulatedGame(board: Fixtures.board, seed: 99)
        let r1 = g1.collapse(.path((0, 3)))
        let r2 = g2.collapse(.path((0, 3)))
        XCTAssertEqual(r1, r2)
        let diff = BoardDiff.changedCoords(Fixtures.board, g1.board)
        XCTAssertTrue(diff.isSubset(of: r1.changed))
    }
}
