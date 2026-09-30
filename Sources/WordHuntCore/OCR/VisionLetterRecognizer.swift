import CoreGraphics
import Foundation
import Vision

/// Apple Vision text recognition applied to a single, cleaned tile.
///
/// Vision is tuned for words, so a lone small letter is often skipped. We feed it the cleaned,
/// upscaled glyph; if nothing comes back we retry with the glyph repeated ("A A A") and take
/// the majority letter. In testing `.fast` reads isolated letters far better than `.accurate`.
public struct VisionLetterRecognizer: LetterRecognizer {
    public let name = "Vision"
    public var recognitionLevel: VNRequestTextRecognitionLevel

    public init(recognitionLevel: VNRequestTextRecognitionLevel = .fast) {
        self.recognitionLevel = recognitionLevel
    }

    /// Common digit/symbol confusions for uppercase-only tiles.
    static let lookalikes: [Character: Character] = ["0": "O", "1": "I", "|": "I", "l": "I", "5": "S", "8": "B", "2": "Z", "$": "S"]

    public func recognize(_ tile: GrayImage) -> LetterRecognitionResult {
        let glyph = GlyphNormalizer.normalize(tile)
        guard !glyph.isBlank else { return .none(name) }
        for copies in [1, 3] {
            if let r = read(glyph, copies: copies) { return r }
        }
        return .none(name)
    }

    private func read(_ glyph: NormalizedGlyph, copies: Int) -> LetterRecognitionResult? {
        guard let image = Self.visionImage(glyph.cleanImage, copies: copies) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = recognitionLevel
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return nil
        }
        var votes: [Character: Double] = [:]
        var reads = 0
        for obs in request.results ?? [] {
            guard let cand = obs.topCandidates(1).first else { continue }
            for raw in cand.string where !raw.isWhitespace {
                reads += 1
                let mapped = Self.lookalikes[raw] ?? Character(raw.uppercased())
                guard ("A"..."Z").contains(mapped) else { continue }
                votes[mapped, default: 0] += Double(cand.confidence)
            }
        }
        guard let best = votes.max(by: { $0.value < $1.value }) else { return nil }
        // Share of characters agreeing × Vision's own confidence for them.
        let agreeing = best.value / Double(copies)
        let conf = min(1, agreeing) * (Double(votes.count == 1 ? 1 : 0.6)) * (reads > copies * 2 ? 0.5 : 1)
        return LetterRecognitionResult(letter: best.key, confidence: conf, engine: name)
    }

    /// Lays out the glyph three times with spacing ("A A A"), smoothly upscaled so the glyph
    /// is ~120 px tall — Vision is unreliable on small, isolated characters.
    static func visionImage(_ glyph: GrayImage, copies: Int = 3) -> CGImage? {
        guard let src = glyph.cgImage() else { return nil }
        let scale = max(1, 120 / CGFloat(max(glyph.height, 1)))
        let gw = CGFloat(glyph.width) * scale, gh = CGFloat(glyph.height) * scale
        let gap = gw * 0.15
        let width = Int(gw * CGFloat(copies) + gap * CGFloat(copies - 1)), height = Int(gh)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        for k in 0..<copies {
            ctx.draw(src, in: CGRect(x: CGFloat(k) * (gw + gap), y: 0, width: gw, height: gh))
        }
        return ctx.makeImage()
    }
}
