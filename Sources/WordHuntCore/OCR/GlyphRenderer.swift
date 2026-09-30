import CoreGraphics
import CoreText
import Foundation

/// Draws letters with CoreText. Used to bootstrap recognition templates and by the simulator.
public enum GlyphRenderer {
    /// Bold, sans-serif faces similar to what word games use for tiles. Missing fonts
    /// silently fall back to the system font, which is fine for templates.
    public static let templateFonts = [
        "Helvetica-Bold", "Arial-BoldMT", "ArialRoundedMTBold", "AvenirNext-Bold", "AvenirNext-Heavy",
        "Futura-Bold", "GillSans-Bold", "Verdana-Bold", "HelveticaNeue-Medium", "Arial-Black",
    ]

    /// Draws `letter` centred in `rect` of `ctx` (CoreGraphics coordinates, origin bottom-left).
    public static func draw(_ letter: Character, in ctx: CGContext, rect: CGRect, fontName: String,
                            heightFraction: CGFloat = 0.55, color: CGColor) {
        let font = CTFontCreateWithName(fontName as CFString, 100, nil)
        let cap = CTFontGetCapHeight(font)
        let size = rect.height * heightFraction * 100 / max(cap, 1)
        let sized = CTFontCreateCopyWithAttributes(font, size, nil, nil)
        let attr = NSAttributedString(string: String(letter), attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): sized,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
        let line = CTLineCreateWithAttributedString(attr)
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        ctx.saveGState()
        ctx.textPosition = CGPoint(x: rect.midX - bounds.midX, y: rect.midY - bounds.midY)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// Renders one tile (letter on a flat background) as a luma image of `side`².
    public static func tileImage(_ letter: Character, fontName: String, side: Int = GlyphNormalizer.tileSide,
                                 heightFraction: CGFloat = 0.55, ink: CGFloat = 0.1, paper: CGFloat = 0.9,
                                 offset: CGPoint = .zero) -> GrayImage {
        var bytes = [UInt8](repeating: 0, count: side * side)
        bytes.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.setFillColor(gray: paper, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
            let r = CGRect(x: offset.x, y: -offset.y, width: CGFloat(side), height: CGFloat(side))
            draw(letter, in: ctx, rect: r, fontName: fontName, heightFraction: heightFraction,
                 color: CGColor(gray: ink, alpha: 1))
        }
        // CGContext rows are stored top-down in memory already.
        return GrayImage(width: side, height: side, pixels: bytes.map { Float($0) / 255 })
    }
}
