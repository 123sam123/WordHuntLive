import Foundation

/// Temporal state machine over per-tile fingerprints. Decides *when* and *which* tiles
/// need OCR, smooths OCR output over frames, and maintains the persistent `BoardState`.
///
///   stable ──(any tile moves)──▶ animating ──(N still frames)──▶ settled
///      ▲                                                          │
///      └──────── changed tiles recognized + accepted ◀────────────┘
///
/// Not thread-safe; the pipeline drives it from one serial queue.
public final class BoardTracker {
    public struct Config: Sendable {
        /// Frame-to-frame distance above which a tile counts as moving.
        public var motionThreshold: Float = 0.12
        /// Distance from a tile's reference fingerprint above which its content has changed.
        public var changeThreshold: Float = 0.22
        /// Consecutive still frames required before the board counts as settled.
        public var stableFramesRequired = 3
        /// Identical consecutive OCR reads needed to accept a letter…
        public var votesRequired = 2
        /// …unless a single read is at least this confident.
        public var instantAcceptConfidence = 0.9
        public init() {}
    }

    public enum Phase: String, Sendable {
        case waiting, animating, settling, stable
    }

    public struct Step: Sendable {
        public var phase: Phase
        /// Tiles to run OCR on for this frame (empty unless settled with pending tiles).
        public var needsRecognition: [GridCoord]
        /// Set when an animation episode ended with every tile of `expectedPath` disturbed —
        /// i.e. the user most likely just played the recommended word.
        public var playedPathDetected: Bool
    }

    public private(set) var board: BoardState
    public private(set) var phase: Phase = .waiting
    public var config: Config
    /// The path currently recommended to the user (hint for played-word detection).
    public var expectedPath: [GridCoord] = []

    private var reference: [TileFingerprint?]
    private var previous: [TileFingerprint]?
    public private(set) var latest: [TileFingerprint]?
    private var stillFrames = 0
    private var disturbed = Set<Int>()
    private var pending = Set<Int>()
    private var votes: [Int: (letter: Character, count: Int, confSum: Double)] = [:]

    public init(board: BoardState = .empty(), config: Config = Config()) {
        self.board = board
        self.config = config
        reference = Array(repeating: nil, count: board.rows * board.columns)
        pending = Set(0..<(board.rows * board.columns))
    }

    public var pendingCoords: [GridCoord] { pending.sorted().map { GridCoord.from(index: $0, columns: board.columns) } }

    /// Feed one frame's fingerprints (row-major, one per tile).
    public func ingest(_ fps: [TileFingerprint]) -> Step {
        precondition(fps.count == reference.count)
        defer { previous = fps; latest = fps }
        let cols = board.columns

        let moving: [Int] = previous.map { prev in fps.indices.filter { fps[$0].distance(to: prev[$0]) > config.motionThreshold } } ?? []
        // "Looks different" (shape or colour, e.g. a drag highlight) vs. "shows a different glyph"
        // (shape only — colour/brightness changes are normalized away). Only the latter needs OCR.
        var looksDifferent: [Int] = []
        var glyphChanged: [Int] = []
        for i in fps.indices {
            guard let ref = reference[i] else { continue }
            if fps[i].distance(to: ref) > config.changeThreshold { looksDifferent.append(i) }
            if fps[i].shapeDistance(to: ref) > config.changeThreshold { glyphChanged.append(i) }
        }

        if !moving.isEmpty {
            // Something is animating: remember what got disturbed; don't OCR mid-motion.
            stillFrames = 0
            phase = .animating
            disturbed.formUnion(looksDifferent)
            disturbed.formUnion(moving)
            votes.removeAll()
            for i in fps.indices {
                let c = GridCoord.from(index: i, columns: cols)
                board.setState(moving.contains(i) ? .falling : (looksDifferent.contains(i) ? .disappearing : .stable), at: c)
            }
            return Step(phase: phase, needsRecognition: [], playedPathDetected: false)
        }

        stillFrames += 1
        guard stillFrames >= config.stableFramesRequired else {
            if phase == .animating || phase == .waiting { return Step(phase: phase, needsRecognition: [], playedPathDetected: false) }
            return step(played: false)
        }

        // Tiles showing a new glyph need re-reading.
        for i in glyphChanged where !pending.contains(i) {
            pending.insert(i)
            votes[i] = nil
        }

        // An episode is over once every tile either looks like its reference again (e.g. the
        // drag highlight faded) or has a new glyph queued for reading. A mid-drag pause with
        // tiles still highlighted doesn't end it.
        var played = false
        let highlightedOnly = Set(looksDifferent).subtracting(glyphChanged)
        if !disturbed.isEmpty, highlightedOnly.isEmpty {
            let expected = Set(expectedPath.map { $0.index(columns: cols) })
            played = !expected.isEmpty && expected.isSubset(of: disturbed)
            disturbed.removeAll()
        }
        for i in fps.indices {
            let c = GridCoord.from(index: i, columns: cols)
            board.setState(pending.contains(i) ? .new : (highlightedOnly.contains(i) ? .disappearing : .stable), at: c)
        }
        phase = pending.isEmpty ? .stable : .settling
        return step(played: played)
    }

    private func step(played: Bool) -> Step {
        Step(phase: phase, needsRecognition: pendingCoords, playedPathDetected: played)
    }

    /// Submit OCR results for tiles returned in `needsRecognition`. Returns the tiles whose
    /// letter was accepted (and possibly changed) this call.
    @discardableResult
    public func submit(_ results: [GridCoord: LetterRecognitionResult]) -> [BoardState.LetterUpdate] {
        let cols = board.columns
        var accepted: [BoardState.LetterUpdate] = []
        for (coord, r) in results {
            let i = coord.index(columns: cols)
            guard pending.contains(i), let letter = r.letter else { continue }
            var v = votes[i] ?? (letter, 0, 0)
            if v.letter != letter { v = (letter, 0, 0) }
            v.count += 1
            v.confSum += r.confidence
            votes[i] = v
            let avg = v.confSum / Double(v.count)
            if r.confidence >= config.instantAcceptConfidence || v.count >= config.votesRequired {
                let conf = min(1, avg + 0.1 * Double(v.count - 1))
                let value = r.dots.flatMap { $0.confidence >= 0.5 && $0.count > 0 ? $0.count : nil }
                accepted.append(.init(coord: coord, letter: letter, confidence: conf, value: value))
                pending.remove(i)
                votes[i] = nil
                reference[i] = latest?[i]
            }
        }
        if !accepted.isEmpty {
            board.apply(accepted)
            if pending.isEmpty { phase = .stable }
        }
        return accepted
    }

    /// Manual correction from the UI: trust the user, and re-anchor that tile's reference.
    public func override(_ coord: GridCoord, letter: Character) {
        let i = coord.index(columns: board.columns)
        board.apply([.init(coord: coord, letter: letter, confidence: 1)])
        pending.remove(i)
        votes[i] = nil
        if let fp = latest?[i] { reference[i] = fp }
    }

    /// Forget everything (e.g. after recalibration or a new game).
    public func reset() {
        let n = board.rows * board.columns
        board = .empty(rows: board.rows, columns: board.columns)
        reference = Array(repeating: nil, count: n)
        pending = Set(0..<n)
        votes.removeAll()
        disturbed.removeAll()
        previous = nil
        stillFrames = 0
        phase = .waiting
    }
}
