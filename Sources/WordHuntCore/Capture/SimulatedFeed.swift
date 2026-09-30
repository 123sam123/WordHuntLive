import Foundation
import QuartzCore

/// A FrameSource that renders a simulated phone screen at 60 fps, including the drag
/// highlight and (optionally) the tile-collapse animation after each played word.
public final class SimulatedFeed: FrameSource, @unchecked Sendable {
    public enum Mode: String, Sendable, CaseIterable {
        /// Board never changes (GamePigeon Word Hunt style); only the drag highlight shows.
        case staticBoard
        /// Played tiles vanish, tiles above fall, new letters drop in.
        case collapse
    }

    public var onFrame: (@Sendable (Frame) -> Void)?
    public private(set) var renderer: BoardRenderer
    public var fps: Double

    private let lock = NSLock()
    private var game: SimulatedGame
    private var mode: Mode
    private var animation: (start: TimeInterval, before: SimulatedGame, after: SimulatedGame?, collapse: SimulatedGame.CollapseResult?, path: [GridCoord])?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "wordhunt.simfeed", qos: .userInteractive)

    public init(board: BoardState, mode: Mode = .collapse, seed: UInt64 = 42, renderer: BoardRenderer = BoardRenderer(), fps: Double = 60) {
        game = SimulatedGame(board: board, seed: seed)
        self.mode = mode
        self.renderer = renderer
        self.fps = fps
    }

    public var board: BoardState { lock.withLock { game.board } }

    public func setMode(_ mode: Mode) { lock.withLock { self.mode = mode } }

    /// Draw value dots under letters (for dot-scoring games); nil hides them.
    public func setDotValues(_ values: [Character: Int]?) { lock.withLock { renderer.dotValues = values } }

    public func setBoard(_ board: BoardState, seed: UInt64 = 42) {
        lock.withLock {
            game = SimulatedGame(board: board, seed: seed)
            animation = nil
        }
    }

    /// Simulates the user dragging `path` on the phone.
    public func play(_ path: [GridCoord], now: TimeInterval = CACurrentMediaTime()) {
        lock.withLock {
            let before = game
            var after: SimulatedGame?
            var collapse: SimulatedGame.CollapseResult?
            if mode == .collapse {
                var g = game
                collapse = g.collapse(path)
                after = g
                game = g
            }
            animation = (now, before, after, collapse, path)
        }
    }

    /// Renders the frame for time `t` (used by the timer and by deterministic tests).
    public func frame(at t: TimeInterval) -> Frame {
        lock.lock()
        let anim = animation
        let current = game
        let renderer = self.renderer
        lock.unlock()
        if let a = anim {
            if let tiles = SimulatedAnimation.appearance(before: a.before, after: a.after, collapse: a.collapse, path: a.path, t: t - a.start) {
                return renderer.render(tiles, timestamp: t)
            }
            lock.withLock { if animation?.start == a.start { animation = nil } }
        }
        return renderer.render(current.board, timestamp: t)
    }

    public func start() async throws {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / fps, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.onFrame?(self.frame(at: CACurrentMediaTime()))
        }
        timer.resume()
        lock.withLock { self.timer = timer }
    }

    public func stop() async {
        lock.withLock {
            timer?.cancel()
            timer = nil
        }
    }
}
