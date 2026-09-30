@testable import WordHuntCore
import XCTest

final class TrackingTests: XCTestCase {
    let renderer = BoardRenderer()
    var geometry: BoardGeometry { BoardGeometry(boardRect: renderer.normalizedBoardRect, tileInset: 0.08) }

    func fingerprints(_ frame: Frame) -> [TileFingerprint] {
        let px = geometry.scaled(toWidth: CGFloat(frame.width), height: CGFloat(frame.height))
        return Fixtures.board.allCoords.map { TileFingerprint.make(frame: frame, rect: px.tileRect($0)) }
    }

    func testFingerprintDistances() {
        let a = fingerprints(renderer.render(Fixtures.board))
        let b = fingerprints(renderer.render(Fixtures.board))
        let highlighted = fingerprints(renderer.render(Fixtures.board, highlighted: [GridCoord(0, 0)]))
        var other = Fixtures.board
        other.apply([.init(coord: GridCoord(1, 1), letter: "W", confidence: 1)])
        let changed = fingerprints(renderer.render(other))
        XCTAssertEqual(a[0].distance(to: b[0]), 0, accuracy: 1e-6)
        XCTAssertGreaterThan(a[0].distance(to: highlighted[0]), 0.22, "highlight must register")
        XCTAssertGreaterThan(a[5].distance(to: changed[5]), 0.22, "letter swap must register")
        XCTAssertEqual(a[6].distance(to: changed[6]), 0, accuracy: 1e-6, "untouched tile is identical")
    }

    /// Scripted OCR so the test isolates the state machine.
    func testInitialReadNeedsStableFramesAndVotes() {
        let tracker = BoardTracker()
        let frame = fingerprints(renderer.render(Fixtures.board))
        XCTAssertTrue(tracker.ingest(frame).needsRecognition.isEmpty) // 1 still frame
        XCTAssertTrue(tracker.ingest(frame).needsRecognition.isEmpty) // 2
        let step = tracker.ingest(frame) // 3 → settled
        XCTAssertEqual(step.needsRecognition.count, 16)
        XCTAssertEqual(step.phase, .settling)

        // First vote at modest confidence: not accepted yet (temporal smoothing).
        let first = Dictionary(uniqueKeysWithValues: Fixtures.board.tiles.map {
            ($0.coord, LetterRecognitionResult(letter: $0.letter, confidence: 0.6, engine: "t"))
        })
        XCTAssertTrue(tracker.submit(first).isEmpty)
        XCTAssertEqual(tracker.board.version, 0)
        // A single-frame misread resets that tile's vote instead of corrupting the board.
        var noisy = first
        noisy[GridCoord(0, 0)] = LetterRecognitionResult(letter: "B", confidence: 0.6, engine: "t")
        _ = tracker.ingest(frame)
        let accepted = tracker.submit(noisy)
        XCTAssertEqual(accepted.count, 15)
        XCTAssertEqual(tracker.board[GridCoord(0, 0)].letter, Tile.unknown)
        _ = tracker.ingest(frame)
        tracker.submit([GridCoord(0, 0): LetterRecognitionResult(letter: "S", confidence: 0.95, engine: "t")])
        XCTAssertEqual(tracker.board.flatLetters, Fixtures.board.flatLetters)
        XCTAssertEqual(tracker.phase, .stable)
        XCTAssertTrue(tracker.ingest(frame).needsRecognition.isEmpty, "stable board is not re-OCR'd")
    }

    func testDetectsChangedTilesAfterCollapseAnimation() {
        let tracker = BoardTracker()
        settle(tracker, on: Fixtures.board)
        var game = SimulatedGame(board: Fixtures.board, seed: 3)
        let before = game
        let path: [GridCoord] = .path((2, 1), (3, 1))
        let collapse = game.collapse(path)
        tracker.expectedPath = path

        // Play the animation frame by frame at 60 fps.
        var t = 0.0
        var sawAnimating = false
        var played = false
        var step: BoardTracker.Step!
        repeat {
            let tiles = SimulatedAnimation.appearance(before: before, after: game, collapse: collapse, path: path, t: t)
            let frame = tiles.map { renderer.render($0) } ?? renderer.render(game.board)
            step = tracker.ingest(fingerprints(frame))
            sawAnimating = sawAnimating || step.phase == .animating
            played = played || step.playedPathDetected
            t += 1.0 / 60
        } while step.needsRecognition.isEmpty && t < 2
        XCTAssertTrue(sawAnimating)
        XCTAssertTrue(played, "the recommended path was played")
        // Only the column that collapsed is re-read — not all 16 tiles.
        XCTAssertEqual(Set(step.needsRecognition), collapse.changed)
        for c in step.needsRecognition { XCTAssertEqual(tracker.board[c].state, .new) }
    }

    func testTransientHighlightDetectsPlayWithoutBoardChange() {
        let tracker = BoardTracker()
        settle(tracker, on: Fixtures.board)
        let path: [GridCoord] = .path((0, 0), (0, 1), (0, 2))
        tracker.expectedPath = path
        let game = SimulatedGame(board: Fixtures.board)
        var played = false
        var t = 0.0
        while t < 0.6 {
            let tiles = SimulatedAnimation.appearance(before: game, after: nil, collapse: nil, path: path, t: t)
            let frame = tiles.map { renderer.render($0) } ?? renderer.render(game.board)
            let step = tracker.ingest(fingerprints(frame))
            played = played || step.playedPathDetected
            XCTAssertTrue(step.needsRecognition.isEmpty, "static board must not trigger OCR")
            t += 1.0 / 60
        }
        XCTAssertTrue(played)
        XCTAssertEqual(tracker.board.flatLetters, Fixtures.board.flatLetters)
    }

    private func settle(_ tracker: BoardTracker, on board: BoardState) {
        let fps = fingerprints(renderer.render(board))
        for _ in 0..<3 { _ = tracker.ingest(fps) }
        tracker.submit(Dictionary(uniqueKeysWithValues: board.tiles.map {
            ($0.coord, LetterRecognitionResult(letter: $0.letter, confidence: 1, engine: "t"))
        }))
        XCTAssertEqual(tracker.board.flatLetters, board.flatLetters)
    }
}

/// End to end: rendered frames → fingerprints → tracker → real OCR → solver.
final class PipelineTests: XCTestCase {
    func testSimulatedGameEndToEnd() throws {
        let feed = SimulatedFeed(board: Fixtures.board, mode: .collapse, seed: 5)
        let geometry = BoardGeometry(boardRect: feed.renderer.normalizedBoardRect, tileInset: 0.08)
        let recommender = Recommender(solver: TrieBoardSolver(trie: Fixtures.fullTrie), scoring: LengthTableScoring.wordHunt)
        let pipeline = LivePipeline(geometry: geometry, recognizer: TemplateLetterRecognizer(), recommender: recommender)
        let box = SnapshotBox()
        pipeline.onSnapshot = { box.value = $0 }

        var t = 100.0
        func run(_ seconds: Double) {
            let end = t + seconds
            while t < end {
                pipeline.processSync(feed.frame(at: t))
                t += 1.0 / 60
            }
        }
        run(0.2)
        var snap = try XCTUnwrap(box.value)
        XCTAssertEqual(snap.board.flatLetters, Fixtures.board.flatLetters, "initial OCR read:\n\(snap.board.gridText)")
        let first = try XCTUnwrap(snap.result.best)

        // "User" plays the recommendation; the board collapses and refills.
        feed.play(first.coordinates, now: t)
        run(1.6)
        snap = try XCTUnwrap(box.value)
        XCTAssertEqual(snap.board.flatLetters, feed.board.flatLetters, "after collapse:\n\(snap.board.gridText)\nexpected\n\(feed.board.gridText)")
        XCTAssertGreaterThan(snap.board.version, 1)
        XCTAssertTrue(snap.playedWords.contains(first.word))
        XCTAssertNotNil(snap.result.best)
        print("E2E: first=\(first.word) next=\(snap.result.best!.word) timings=\(snap.timings)")
    }
}

final class SnapshotBox: @unchecked Sendable {
    var value: PipelineSnapshot?
}
