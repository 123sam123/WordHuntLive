import CoreGraphics
import CoreVideo
import Foundation

/// One captured (or rendered) BGRA frame. Wraps either a CVPixelBuffer from
/// ScreenCaptureKit (zero-copy) or a byte buffer from the simulator.
public final class Frame: @unchecked Sendable {
    public let width: Int
    public let height: Int
    /// Host time (seconds, `CACurrentMediaTime` clock) when the frame was produced.
    public let timestamp: TimeInterval
    private let storage: Storage

    private enum Storage {
        case pixelBuffer(CVPixelBuffer)
        case bytes([UInt8], bytesPerRow: Int)
    }

    public init(pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) {
        width = CVPixelBufferGetWidth(pixelBuffer)
        height = CVPixelBufferGetHeight(pixelBuffer)
        self.timestamp = timestamp
        storage = .pixelBuffer(pixelBuffer)
    }

    public init(bgra: [UInt8], width: Int, height: Int, bytesPerRow: Int, timestamp: TimeInterval) {
        precondition(bgra.count >= bytesPerRow * height)
        self.width = width
        self.height = height
        self.timestamp = timestamp
        storage = .bytes(bgra, bytesPerRow: bytesPerRow)
    }

    /// Renders any CGImage into a BGRA frame (used for screenshots and tests).
    public convenience init?(cgImage: CGImage, timestamp: TimeInterval = 0) {
        let w = cgImage.width, h = cgImage.height, bpr = w * 4
        var bytes = [UInt8](repeating: 0, count: bpr * h)
        let ok = bytes.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        self.init(bgra: bytes, width: w, height: h, bytesPerRow: bpr, timestamp: timestamp)
    }

    /// Gives read access to the BGRA bytes (row 0 = top of image).
    public func withBGRA<R>(_ body: (UnsafePointer<UInt8>, Int) throws -> R) rethrows -> R {
        switch storage {
        case let .pixelBuffer(pb):
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
            return try body(UnsafePointer(base), CVPixelBufferGetBytesPerRow(pb))
        case let .bytes(bytes, bpr):
            return try bytes.withUnsafeBufferPointer { try body($0.baseAddress!, bpr) }
        }
    }

    /// A CGImage copy of a region (pixel coordinates, origin top-left). For previews and debug.
    public func cgImage(cropping rect: CGRect? = nil) -> CGImage? {
        let r = (rect ?? CGRect(x: 0, y: 0, width: width, height: height)).integral
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard r.width >= 1, r.height >= 1 else { return nil }
        let w = Int(r.width), h = Int(r.height), x0 = Int(r.minX), y0 = Int(r.minY)
        var out = [UInt8](repeating: 0, count: w * h * 4)
        withBGRA { src, bpr in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    memcpy(dst.baseAddress! + y * w * 4, src + (y0 + y) * bpr + x0 * 4, w * 4)
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(out) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// A small single-channel float image (0 = black, 1 = white), row-major, row 0 = top.
public struct GrayImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public var pixels: [Float]

    public init(width: Int, height: Int, pixels: [Float]) {
        precondition(pixels.count == width * height)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init(width: Int, height: Int, fill: Float = 0) {
        self.init(width: width, height: height, pixels: Array(repeating: fill, count: width * height))
    }

    @inline(__always) public subscript(x: Int, y: Int) -> Float {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }

    /// Mean colour of the sampled region, kept alongside the luma so highlights are detectable.
    public struct MeanColor: Sendable, Equatable {
        public var r: Float, g: Float, b: Float
    }

    /// Area-averaged downsample of `rect` (pixel coords, origin top-left) to `outW`×`outH` luma.
    /// Each output pixel averages up to `maxSamples`² source pixels — cheap enough to run on
    /// all 16 tiles every frame.
    public static func sample(_ frame: Frame, rect: CGRect, outW: Int, outH: Int, maxSamples: Int = 4) -> (GrayImage, MeanColor) {
        var out = GrayImage(width: outW, height: outH)
        var sr: Float = 0, sg: Float = 0, sb: Float = 0
        let bounds = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        let r = rect.intersection(bounds)
        guard r.width >= 1, r.height >= 1 else { return (out, MeanColor(r: 0, g: 0, b: 0)) }
        let cellW = r.width / CGFloat(outW), cellH = r.height / CGFloat(outH)
        let nx = max(1, min(maxSamples, Int(cellW))), ny = max(1, min(maxSamples, Int(cellH)))
        let maxX = frame.width - 1, maxY = frame.height - 1
        frame.withBGRA { base, bpr in
            for oy in 0..<outH {
                for ox in 0..<outW {
                    var acc: Float = 0, ar: Float = 0, ag: Float = 0, ab: Float = 0
                    for sy in 0..<ny {
                        let y = min(maxY, Int(r.minY + (CGFloat(oy) + (CGFloat(sy) + 0.5) / CGFloat(ny)) * cellH))
                        let row = base + y * bpr
                        for sx in 0..<nx {
                            let x = min(maxX, Int(r.minX + (CGFloat(ox) + (CGFloat(sx) + 0.5) / CGFloat(nx)) * cellW))
                            let p = row + x * 4
                            let b = Float(p[0]), g = Float(p[1]), rr = Float(p[2])
                            ab += b; ag += g; ar += rr
                            acc += 0.299 * rr + 0.587 * g + 0.114 * b
                        }
                    }
                    let n = Float(nx * ny)
                    out[ox, oy] = acc / (n * 255)
                    sr += ar / n; sg += ag / n; sb += ab / n
                }
            }
        }
        let total = Float(outW * outH) * 255
        return (out, MeanColor(r: sr / total, g: sg / total, b: sb / total))
    }

    /// 8-bit grayscale CGImage (for Vision and debug views).
    public func cgImage() -> CGImage? {
        let bytes = pixels.map { UInt8(max(0, min(255, $0 * 255))) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
