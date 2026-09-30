@testable import WordHuntCore
import XCTest

final class RecognitionTests: XCTestCase {
    static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")

    func testNormalizerFindsGlyphAndHandlesPolarity() {
        let dark = GlyphNormalizer.normalize(GlyphRenderer.tileImage("A", fontName: "Helvetica-Bold"))
        let light = GlyphNormalizer.normalize(GlyphRenderer.tileImage("A", fontName: "Helvetica-Bold", ink: 0.95, paper: 0.15))
        XCTAssertFalse(dark.isBlank)
        XCTAssertFalse(light.isBlank)
        // Light-on-dark and dark-on-light normalize to (nearly) the same glyph.
        let diff = zip(dark.feature, light.feature).map { abs($0 - $1) }.reduce(0, +) / Float(dark.feature.count)
        XCTAssertLessThan(diff, 0.05)
        XCTAssertTrue(GlyphNormalizer.normalize(GrayImage(width: 64, height: 64, fill: 0.7)).isBlank)
        XCTAssertLessThan(GlyphNormalizer.normalize(GlyphRenderer.tileImage("I", fontName: "Helvetica-Bold")).aspect, 0.4)
    }

    /// Template matching on a font that is NOT among the templates, with small offsets.
    func testTemplateRecognizerOnUnseenFont() {
        let rec = TemplateLetterRecognizer(fonts: ["Helvetica-Bold", "Arial-BoldMT", "AvenirNext-Bold", "Futura-Bold"])
        var correct = 0
        var misses: [String] = []
        for ch in Self.alphabet {
            let tile = GlyphRenderer.tileImage(ch, fontName: "Verdana-Bold", heightFraction: 0.5, offset: CGPoint(x: 2, y: -1))
            let r = rec.recognize(tile)
            if r.letter == ch { correct += 1 } else { misses.append("\(ch)→\(r.letter.map(String.init) ?? "nil")") }
        }
        XCTAssertGreaterThanOrEqual(correct, 24, "misses: \(misses)")
    }

    /// Learning the game's glyphs makes recognition exact and confident.
    func testLearningGameFont() {
        let rec = TemplateLetterRecognizer(fonts: ["Helvetica-Bold"])
        let gameFont = "ArialRoundedMTBold"
        for ch in Self.alphabet { rec.learn(ch, from: GlyphRenderer.tileImage(ch, fontName: gameFont)) }
        XCTAssertEqual(rec.learnedCount, 26)
        for ch in Self.alphabet {
            let r = rec.recognize(GlyphRenderer.tileImage(ch, fontName: gameFont, offset: CGPoint(x: -2, y: 1)))
            XCTAssertEqual(r.letter, ch)
            XCTAssertGreaterThan(r.confidence, 0.7, "\(ch)")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try! rec.saveLearned(to: url)
        let fresh = TemplateLetterRecognizer(fonts: ["Helvetica-Bold"])
        fresh.loadLearned(from: url)
        XCTAssertEqual(fresh.learnedCount, 26)
    }

    func testTemplateRecognizerIsFast() {
        let rec = TemplateLetterRecognizer()
        let tile = GlyphRenderer.tileImage("R", fontName: "Verdana-Bold")
        _ = rec.recognize(tile)
        let start = Date()
        for _ in 0..<16 { _ = rec.recognize(tile) }
        let perBoard = Date().timeIntervalSince(start)
        XCTAssertLessThan(perBoard, 0.25, "16 tiles took \(perBoard * 1000) ms (debug build)")
    }

    func testVisionRecognizer() {
        let rec = VisionLetterRecognizer()
        var correct = 0
        var misses: [String] = []
        for ch in Self.alphabet {
            let r = rec.recognize(GlyphRenderer.tileImage(ch, fontName: "Verdana-Bold"))
            if r.letter == ch { correct += 1 } else { misses.append("\(ch)→\(r.letter.map(String.init) ?? "nil")") }
        }
        print("Vision single-letter accuracy: \(correct)/26 misses: \(misses)")
        XCTAssertGreaterThanOrEqual(correct, 20, "misses: \(misses)")
    }

    func testCompositeFallsBackWhenPrimaryUnsure() {
        let unsure = ScriptedLetterRecognizer([.init(letter: "O", confidence: 0.3, engine: "A")])
        let sure = ScriptedLetterRecognizer([.init(letter: "Q", confidence: 0.8, engine: "B")])
        let agree = ScriptedLetterRecognizer([.init(letter: "O", confidence: 0.5, engine: "B")])
        let blank = GrayImage(width: 4, height: 4)
        XCTAssertEqual(CompositeLetterRecognizer(primary: unsure, fallback: sure).recognize(blank).letter, "Q")
        let both = CompositeLetterRecognizer(primary: unsure, fallback: agree).recognize(blank)
        XCTAssertEqual(both.letter, "O")
        XCTAssertEqual(both.confidence, 0.7, accuracy: 1e-9)
    }
}
