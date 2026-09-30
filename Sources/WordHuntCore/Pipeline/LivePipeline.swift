import CoreGraphics
import Foundation
import QuartzCore

public struct PipelineTimings: Sendable, Equatable {
    /// Frames/second actually processed.
    public var captureFPS: Double = 0
    /// Capture timestamp → start of processing.
    public var frameAge: TimeInterval = 0
    /// Fingerprinting all 16 tiles + tracker step.
    public var tracking: TimeInterval = 0
    /// Last OCR batch (only runs on changed tiles).
    public var recognition: TimeInterval = 0
    /// Last solve + rank.
    public var solve: TimeInterval = 0
    /// Capture timestamp → snapshot published, for the last frame that changed the board.
    public var total: TimeInterval = 0
    public init() {}
}

public struct PipelineSnapshot: Sendable {
    public var board: BoardState
    public var result: SolveResult
    public var phase: BoardTracker.Phase
    public var timings: PipelineTimings
    public var recognitions: [GridCoord: LetterRecognitionResult]
    public var playedWords: [String]
    public var frameSize: CGSize
    public var framesProcessed: Int
}

/// capture → fingerprint/track → OCR changed tiles → solve → publish.
///
/// Frames arrive on the capture queue and are processed on one serial queue; if a frame
/// arrives while the previous one is still being processed it is dropped (latest wins),
/// so latency never accumulates. The solver runs inline (sub-millisecond).
public final class LivePipeline: @unchecked Sendable {
    public var onSnapshot: (@Sendable (PipelineSnapshot) -> Void)?

    private let queue = DispatchQueue(label: "wordhunt.pipeline", qos: .userInteractive)
    private let lock = NSLock()
    private var busy = false
    private var paused = false
    private var latestFrame: Frame?

    // Queue-confined state.
    private var geometry: BoardGeometry
    private var recognizer: any LetterRecognizer
    private var recommender: Recommender?
    private let tracker: BoardTracker
    private var result = SolveResult.empty
    private var solvedVersion = -1
    private var played: [String] = []
    private var excludePlayed = true
    private var blocked = Set<String>()
    private var timings = PipelineTimings()
    private var recognitions: [GridCoord: LetterRecognitionResult] = [:]
    private var lastEmit: TimeInterval = 0
    private var frameTimes: [TimeInterval] = []
    private var processed = 0
    private var lastFrameSize = CGSize.zero

    /// Receives confirmed samples so it can learn the game's font (optional).
    public var learner: TemplateLetterRecognizer?

    public init(geometry: BoardGeometry, recognizer: any LetterRecognizer, recommender: Recommender?,
                trackerConfig: BoardTracker.Config = .init()) {
        self.geometry = geometry
        self.recognizer = recognizer
        self.recommender = recommender
        tracker = BoardTracker(board: .empty(rows: geometry.rows, columns: geometry.columns), config: trackerConfig)
    }

    // MARK: Input

    /// Thread-safe. Drops the frame if the pipeline is paused or still busy.
    public func submit(_ frame: Frame) {
        lock.lock()
        latestFrame = frame
        if busy || paused { lock.unlock(); return }
        busy = true
        lock.unlock()
        queue.async { [self] in
            process(frame)
            lock.withLock { busy = false }
        }
    }

    /// Runs one frame synchronously on the caller's thread (tests, benchmarks).
    public func processSync(_ frame: Frame) {
        queue.sync { process(frame) }
    }

    public var isPaused: Bool {
        get { lock.withLock { paused } }
        set { lock.withLock { paused = newValue } }
    }

    public func currentFrame() -> Frame? { lock.withLock { latestFrame } }

    // MARK: Configuration (all hop onto the pipeline queue)

    public func update(geometry: BoardGeometry) {
        queue.async { [self] in
            self.geometry = geometry
            tracker.reset()
            recognitions.removeAll()
            solvedVersion = -1
        }
    }

    public func update(recommender: Recommender?, excludePlayed: Bool) {
        queue.async { [self] in
            self.recommender = recommender
            self.excludePlayed = excludePlayed
            resolve(force: true)
            emit(force: true)
        }
    }

    /// Words that must never be recommended (e.g. the game rejected them).
    public func update(blocked: Set<String>) {
        queue.async { [self] in
            self.blocked = blocked
            resolve(force: true)
            emit(force: true)
        }
    }

    public func update(recognizer: any LetterRecognizer) {
        queue.async { [self] in self.recognizer = recognizer }
    }

    public func markPlayed(_ word: String) {
        queue.async { [self] in
            if !played.contains(word) { played.append(word) }
            resolve(force: true)
            emit(force: true)
        }
    }

    public func resetPlayed() {
        queue.async { [self] in
            played.removeAll()
            resolve(force: true)
            emit(force: true)
        }
    }

    public func reset() {
        queue.async { [self] in
            tracker.reset()
            played.removeAll()
            recognitions.removeAll()
            result = .empty
            solvedVersion = -1
            emit(force: true)
        }
    }

    /// User-corrected tile: accept it and teach the template recognizer this glyph.
    public func correct(_ coord: GridCoord, letter: Character) {
        queue.async { [self] in
            tracker.override(coord, letter: letter)
            if let tile = tileImage(coord) { learner?.learn(letter, from: tile) }
            resolve(force: true)
            emit(force: true)
        }
    }

    /// Teach the template recognizer every tile of the current (user-verified) board.
    public func learnCurrentBoard(completion: (@Sendable (Int) -> Void)? = nil) {
        queue.async { [self] in
            var n = 0
            for t in tracker.board.tiles where t.isKnown {
                if let img = tileImage(t.coord) { learner?.learn(t.letter, from: img); n += 1 }
            }
            completion?(n)
        }
    }

    // MARK: Processing

    private func tileImage(_ coord: GridCoord) -> GrayImage? {
        guard let frame = currentFrame() else { return nil }
        let px = geometry.scaled(toWidth: CGFloat(frame.width), height: CGFloat(frame.height))
        let side = GlyphNormalizer.tileSide
        return GrayImage.sample(frame, rect: px.tileRect(coord), outW: side, outH: side).0
    }

    private func process(_ frame: Frame) {
        let start = CACurrentMediaTime()
        processed += 1
        lastFrameSize = CGSize(width: frame.width, height: frame.height)
        frameTimes.append(start)
        frameTimes.removeAll { start - $0 > 1 }
        timings.captureFPS = Double(frameTimes.count)
        let age = start - frame.timestamp
        timings.frameAge = (0...5).contains(age) ? age : 0 // ignore foreign clocks (tests, files)

        let px = geometry.scaled(toWidth: CGFloat(frame.width), height: CGFloat(frame.height))
        let fps = tracker.board.allCoords.map { TileFingerprint.make(frame: frame, rect: px.tileRect($0)) }
        let step = tracker.ingest(fps)
        timings.tracking = CACurrentMediaTime() - start

        var changed = false
        if !step.needsRecognition.isEmpty {
            let ocrStart = CACurrentMediaTime()
            let coords = step.needsRecognition
            let side = GlyphNormalizer.tileSide
            let images = coords.map { GrayImage.sample(frame, rect: px.tileRect($0), outW: side, outH: side).0 }
            var out = [LetterRecognitionResult](repeating: .none("—"), count: coords.count)
            let recognizer = self.recognizer
            out.withUnsafeMutableBufferPointer { buf in
                let base = buf.baseAddress!
                let dotRects = coords.map { px.tileRect($0) }
                DispatchQueue.concurrentPerform(iterations: coords.count) { k in
                    var r = recognizer.recognize(images[k])
                    if r.letter != nil {
                        let side = DotCounter.tileSide
                        r.dots = DotCounter.count(GrayImage.sample(frame, rect: dotRects[k], outW: side, outH: side).0)
                    }
                    base[k] = r
                }
            }
            var results: [GridCoord: LetterRecognitionResult] = [:]
            for (k, c) in coords.enumerated() { results[c] = out[k]; recognitions[c] = out[k] }
            let accepted = tracker.submit(results)
            timings.recognition = CACurrentMediaTime() - ocrStart
            changed = !accepted.isEmpty
        }

        if step.playedPathDetected, let best = result.best {
            if !played.contains(best.word) { played.append(best.word) }
            changed = true
        }

        if resolve(force: step.playedPathDetected) { changed = true }
        if changed {
            timings.total = CACurrentMediaTime() - start + timings.frameAge
        }
        emit(force: changed)
    }

    /// Re-solves when the board version moved (or when forced). Returns true if it solved.
    @discardableResult
    private func resolve(force: Bool) -> Bool {
        let board = tracker.board
        guard let recommender, force || board.version != solvedVersion else { return false }
        solvedVersion = board.version
        result = recommender.solve(board, excluding: blocked.union(excludePlayed ? Set(played) : []))
        timings.solve = result.duration
        tracker.expectedPath = result.best?.coordinates ?? []
        return true
    }

    private func emit(force: Bool) {
        let now = CACurrentMediaTime()
        // Metrics refresh at ~15 Hz; board/recommendation changes go out immediately.
        guard force || now - lastEmit > 1.0 / 15 else { return }
        lastEmit = now
        let snap = PipelineSnapshot(board: tracker.board, result: result, phase: tracker.phase, timings: timings,
                                    recognitions: recognitions, playedWords: played, frameSize: lastFrameSize,
                                    framesProcessed: processed)
        onSnapshot?(snap)
    }
}
