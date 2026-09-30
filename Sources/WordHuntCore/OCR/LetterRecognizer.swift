import Foundation

public struct LetterRecognitionResult: Sendable, Equatable {
    /// Uppercase A–Z, or nil when nothing legible was found.
    public var letter: Character?
    /// 0…1.
    public var confidence: Double
    /// Which engine produced the answer (for the debug panel).
    public var engine: String
    /// Value dots read under the letter (filled in by the pipeline, not the recognizer).
    public var dots: DotCounter.Reading?

    public init(letter: Character?, confidence: Double, engine: String, dots: DotCounter.Reading? = nil) {
        self.letter = letter
        self.confidence = confidence
        self.engine = engine
        self.dots = dots
    }

    public static func none(_ engine: String) -> LetterRecognitionResult {
        LetterRecognitionResult(letter: nil, confidence: 0, engine: engine)
    }
}

/// Recognizes the single letter on one tile. `tile` is the tile face sampled at
/// `GlyphNormalizer.tileSide`² luma; implementations may use the normalized glyph.
/// Implementations must be thread-safe: the pipeline calls them concurrently per tile.
public protocol LetterRecognizer: Sendable {
    var name: String { get }
    func recognize(_ tile: GrayImage) -> LetterRecognitionResult
}

/// Test double: returns scripted answers per call, then repeats the last one.
public final class ScriptedLetterRecognizer: LetterRecognizer, @unchecked Sendable {
    public let name = "Scripted"
    private let lock = NSLock()
    private var script: [LetterRecognitionResult]

    public init(_ script: [LetterRecognitionResult]) {
        self.script = script
    }

    public func recognize(_: GrayImage) -> LetterRecognitionResult {
        lock.lock()
        defer { lock.unlock() }
        return script.count > 1 ? script.removeFirst() : (script.first ?? .none(name))
    }
}

/// Tries a fast primary recognizer first and only falls back (e.g. to Vision) when
/// the primary isn't confident. Agreement between both boosts confidence.
public struct CompositeLetterRecognizer: LetterRecognizer {
    public var primary: any LetterRecognizer
    public var fallback: any LetterRecognizer
    public var threshold: Double

    public init(primary: any LetterRecognizer, fallback: any LetterRecognizer, threshold: Double = 0.75) {
        self.primary = primary
        self.fallback = fallback
        self.threshold = threshold
    }

    public var name: String { "\(primary.name)+\(fallback.name)" }

    public func recognize(_ tile: GrayImage) -> LetterRecognitionResult {
        let p = primary.recognize(tile)
        if p.letter != nil, p.confidence >= threshold { return p }
        let f = fallback.recognize(tile)
        switch (p.letter, f.letter) {
        case let (a?, b?) where a == b:
            return LetterRecognitionResult(letter: a, confidence: min(1, max(p.confidence, f.confidence) + 0.2),
                                           engine: "\(p.engine)=\(f.engine)")
        case (_, _?) where f.confidence >= p.confidence:
            return f
        default:
            return p.letter == nil ? f : p
        }
    }
}
