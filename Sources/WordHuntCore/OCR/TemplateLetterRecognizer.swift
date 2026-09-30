import Accelerate
import Foundation

/// Fast nearest-template classifier over normalized glyphs (~0.1 ms per tile).
///
/// Bootstraps from letters rendered in several bold system fonts, and gets much more
/// accurate once it has learned real samples of the game's own font (`learn`), which the
/// app does whenever the user confirms or corrects a board.
public final class TemplateLetterRecognizer: LetterRecognizer, @unchecked Sendable {
    public let name = "Template"

    struct Template: Codable {
        var letter: String
        var vector: [Float] // zero-mean, unit-norm
        var aspect: Float
        var learned: Bool
    }

    private let lock = NSLock()
    private var templates: [Template] = []

    public init(fonts: [String] = GlyphRenderer.templateFonts) {
        for font in fonts {
            for ch in "ABCDEFGHIJKLMNOPQRSTUVWXYZ" {
                let glyph = GlyphNormalizer.normalize(GlyphRenderer.tileImage(ch, fontName: font))
                guard !glyph.isBlank else { continue }
                templates.append(Template(letter: String(ch), vector: Self.unit(glyph.feature), aspect: glyph.aspect, learned: false))
            }
        }
    }

    public var learnedCount: Int { lock.withLock { templates.filter(\.learned).count } }

    public func recognize(_ tile: GrayImage) -> LetterRecognitionResult {
        recognize(glyph: GlyphNormalizer.normalize(tile))
    }

    public func recognize(glyph: NormalizedGlyph) -> LetterRecognitionResult {
        guard !glyph.isBlank else { return .none(name) }
        let v = Self.unit(glyph.feature)
        var bestPerLetter: [String: Float] = [:]
        lock.lock()
        for t in templates {
            var s: Float = 0
            vDSP_dotpr(v, 1, t.vector, 1, &s, vDSP_Length(v.count))
            // Penalise aspect mismatch (I vs L vs T etc. differ strongly in width).
            s -= min(0.3, abs(log(max(glyph.aspect, 0.05) / max(t.aspect, 0.05))) * 0.15)
            if t.learned { s += 0.02 } // prefer the game's own font on near-ties
            if s > bestPerLetter[t.letter] ?? -2 { bestPerLetter[t.letter] = s }
        }
        lock.unlock()
        let ranked = bestPerLetter.sorted { $0.value > $1.value }
        guard let top = ranked.first else { return .none(name) }
        let second = ranked.count > 1 ? ranked[1].value : 0
        let conf = Self.confidence(best: top.value, second: second)
        return LetterRecognitionResult(letter: Character(top.key), confidence: conf, engine: name)
    }

    static func confidence(best: Float, second: Float) -> Double {
        let absolute = min(1, max(0, (best - 0.55) / 0.35))
        let margin = min(1, max(0, (best - second) / 0.12))
        return Double(absolute * (0.4 + 0.6 * margin))
    }

    /// Adds a confirmed sample of `letter` (e.g. after the user verifies the board).
    public func learn(_ letter: Character, from tile: GrayImage) {
        let glyph = GlyphNormalizer.normalize(tile)
        guard !glyph.isBlank, ("A"..."Z").contains(letter) else { return }
        let t = Template(letter: String(letter), vector: Self.unit(glyph.feature), aspect: glyph.aspect, learned: true)
        lock.withLock {
            // Cap learned samples per letter so memory/time stay bounded.
            let existing = templates.indices.filter { templates[$0].learned && templates[$0].letter == t.letter }
            if existing.count >= 8, let oldest = existing.first { templates.remove(at: oldest) }
            templates.append(t)
        }
    }

    public func saveLearned(to url: URL) throws {
        let learned = lock.withLock { templates.filter(\.learned) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(learned).write(to: url, options: .atomic)
    }

    public func loadLearned(from url: URL) {
        guard let data = try? Data(contentsOf: url),
              let learned = try? JSONDecoder().decode([Template].self, from: data) else { return }
        lock.withLock {
            templates.removeAll(where: \.learned)
            templates.append(contentsOf: learned)
        }
    }

    public func forgetLearned() {
        lock.withLock { templates.removeAll(where: \.learned) }
    }

    static func unit(_ v: [Float]) -> [Float] {
        let mean = v.reduce(0, +) / Float(v.count)
        let centered = v.map { $0 - mean }
        let norm = centered.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? centered.map { $0 / norm } : centered
    }
}
