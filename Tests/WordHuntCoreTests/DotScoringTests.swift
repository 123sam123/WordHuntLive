@testable import WordHuntCore
import XCTest

final class DotScoringTests: XCTestCase {
    func testDotCounterReadsOneToFourDots() {
        let recognizer = TemplateLetterRecognizer()
        var renderer = BoardRenderer()
        renderer.fontName = "Helvetica-Bold"
        for n in 1...4 {
            renderer.dotValues = Dictionary(uniqueKeysWithValues: "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map { ($0, n) })
            let frame = renderer.render(Fixtures.board)
            let geo = BoardGeometry(boardRect: renderer.normalizedBoardRect, tileInset: 0.08)
                .scaled(toWidth: CGFloat(frame.width), height: CGFloat(frame.height))
            for coord in Fixtures.board.allCoords {
                let side = DotCounter.tileSide
                let tile = GrayImage.sample(frame, rect: geo.tileRect(coord), outW: side, outH: side).0
                let reading = DotCounter.count(tile)
                XCTAssertEqual(reading?.count, n, "tile \(coord) \(Fixtures.board[coord].letter) with \(n) dots")
                XCTAssertGreaterThanOrEqual(reading?.confidence ?? 0, 0.5)
                // The dots must not confuse the letter reader.
                let letter = recognizer.recognize(
                    GrayImage.sample(frame, rect: geo.tileRect(coord), outW: 64, outH: 64).0).letter
                XCTAssertEqual(letter, Fixtures.board[coord].letter, "\(coord) with \(n) dots")
            }
        }
    }

    func testNoDotsReadsZero() {
        let tile = GlyphRenderer.tileImage("A", fontName: "Helvetica-Bold", side: DotCounter.tileSide)
        XCTAssertEqual(DotCounter.count(tile)?.count, 0)
    }

    func testTileValueScoringUsesReadDotsThenFallback() {
        var board = try! BoardState.parse("CATX XXXX XXXX XXXX")
        let s = TileValueScoring.dots
        let path: [GridCoord] = .path((0, 0), (0, 1), (0, 2))
        // Fallback table: C=2, A=2, T=1 → 5 dots × 10 × 1.0 (3 letters)
        XCTAssertEqual(s.score(word: "CAT", path: path, board: board), 50)
        // Dots read from the screen override the table: C=4.
        board.apply([.init(coord: GridCoord(0, 0), letter: "C", confidence: 1, value: 4)])
        XCTAssertEqual(s.score(word: "CAT", path: path, board: board), 70)
        XCTAssertEqual(s.multiplier(forLength: 5), 2)
        XCTAssertEqual(s.multiplier(forLength: 10), 4.5)
    }

    func testDotModePrefersHighValueTiles() {
        // Two 4-letter words; the one through the 4-dot X should win in dot mode.
        let board = try! BoardState.parse("AXES OXXX XXXX NOTE")
        let trie = Trie(words: ["AXES", "NOTE"])
        var config = ScoringConfig()
        config.mode = .tileValues
        let best = Recommender(solver: TrieBoardSolver(trie: trie), scoring: config.makeEngine()).solve(board).best
        XCTAssertEqual(best?.word, "AXES")
    }

    func testOldSavedConfigStillDecodes() throws {
        let old = #"{"mode":"letterValues","lengthTable":{"table":{"3":100},"extraPerLetter":400},"letterValues":{"letterValues":{"A":1},"lengthBonus":0.25}}"#
        let config = try JSONDecoder().decode(ScoringConfig.self, from: Data(old.utf8))
        XCTAssertEqual(config.mode, .letterValues)
        XCTAssertEqual(config.tileValues, .dots)
    }

    func testPipelineReadsDotsEndToEnd() throws {
        let feed = SimulatedFeed(board: Fixtures.board, mode: .staticBoard)
        feed.setDotValues(TileValueScoring.dots.fallbackDots.reduce(into: [:]) { $0[Character($1.key)] = $1.value })
        let geometry = BoardGeometry(boardRect: feed.renderer.normalizedBoardRect, tileInset: 0.08)
        var config = ScoringConfig()
        config.mode = .tileValues
        let pipeline = LivePipeline(geometry: geometry, recognizer: TemplateLetterRecognizer(),
                                    recommender: Recommender(solver: TrieBoardSolver(trie: Fixtures.trie), scoring: config.makeEngine()))
        let box = SnapshotBox()
        pipeline.onSnapshot = { box.value = $0 }
        for k in 0..<12 { pipeline.processSync(feed.frame(at: Double(k) / 60)) }
        let board = try XCTUnwrap(box.value?.board)
        XCTAssertEqual(board.flatLetters, Fixtures.board.flatLetters)
        for t in board.tiles {
            XCTAssertEqual(t.value, TileValueScoring.dots.fallbackDots[String(t.letter)], "\(t.coord) \(t.letter)")
        }
    }
}
