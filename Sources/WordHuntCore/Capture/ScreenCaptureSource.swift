import CoreMedia
import Foundation
import QuartzCore
import ScreenCaptureKit

/// Something on screen that can be captured.
public struct CaptureTarget: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case window, display }
    /// Stable-ish identifier used to key calibrations: app bundle id + window title, or display id.
    public var id: String
    public var kind: Kind
    public var title: String
    public var appName: String
    public var size: CGSize
    let windowID: CGWindowID
    let displayID: CGDirectDisplayID

    public var displayName: String {
        switch kind {
        case .window: title.isEmpty ? appName : "\(appName) — \(title)"
        case .display: "Display \(displayID) (\(Int(size.width))×\(Int(size.height)))"
        }
    }

    /// Windows that are likely to contain a mirrored iPhone.
    public var isLikelyPhoneMirror: Bool {
        let s = (appName + " " + title).lowercased()
        return ["iphone mirroring", "quicktime", "reflector", "airserver", "uxplay", "scrcpy", "iphone"].contains { s.contains($0) }
    }
}

public enum CaptureError: Error, LocalizedError {
    case targetNotFound
    case permissionDenied

    public var errorDescription: String? {
        switch self {
        case .targetNotFound: "The capture target is no longer on screen."
        case .permissionDenied: "Screen Recording permission is needed. Enable Word Hunt Live in System Settings → Privacy & Security → Screen & System Audio Recording, then relaunch."
        }
    }
}

/// Live capture of one window (or a display) via ScreenCaptureKit, delivered as BGRA frames.
public final class ScreenCaptureSource: NSObject, FrameSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public var onFrame: (@Sendable (Frame) -> Void)?
    public var onStop: (@Sendable (Error?) -> Void)?

    public let target: CaptureTarget
    public var maxFPS: Int
    private var stream: SCStream?
    private let outputQueue = DispatchQueue(label: "wordhunt.capture", qos: .userInteractive)

    public init(target: CaptureTarget, maxFPS: Int = 60) {
        self.target = target
        self.maxFPS = maxFPS
    }

    /// On-screen windows (likely phone mirrors first) followed by displays.
    public static func availableTargets() async throws -> [CaptureTarget] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.permissionDenied
        }
        let ownBundle = Bundle.main.bundleIdentifier
        let windows = content.windows
            .filter { $0.frame.width >= 120 && $0.frame.height >= 120 && $0.windowLayer == 0 }
            .filter { $0.owningApplication?.bundleIdentifier != ownBundle }
            .map { w in
                CaptureTarget(id: "window:\(w.owningApplication?.bundleIdentifier ?? "?"):\(w.title ?? "")",
                              kind: .window, title: w.title ?? "", appName: w.owningApplication?.applicationName ?? "Window",
                              size: w.frame.size, windowID: w.windowID, displayID: 0)
            }
            .sorted { ($0.isLikelyPhoneMirror ? 0 : 1, $0.appName) < ($1.isLikelyPhoneMirror ? 0 : 1, $1.appName) }
        let displays = content.displays.map { d in
            CaptureTarget(id: "display:\(d.displayID)", kind: .display, title: "", appName: "Display",
                          size: CGSize(width: d.width, height: d.height), windowID: 0, displayID: d.displayID)
        }
        return windows + displays
    }

    public func start() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.permissionDenied
        }
        let filter: SCContentFilter
        var pixelSize: CGSize
        switch target.kind {
        case .window:
            guard let w = content.windows.first(where: { $0.windowID == target.windowID }) else { throw CaptureError.targetNotFound }
            filter = SCContentFilter(desktopIndependentWindow: w)
            pixelSize = w.frame.size
        case .display:
            guard let d = content.displays.first(where: { $0.displayID == target.displayID }) else { throw CaptureError.targetNotFound }
            filter = SCContentFilter(display: d, excludingWindows: [])
            pixelSize = CGSize(width: d.width, height: d.height)
        }
        let scale = CGFloat(filter.pointPixelScale)
        pixelSize = CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale)

        let config = SCStreamConfiguration()
        config.width = Int(pixelSize.width)
        config.height = Int(pixelSize.height)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(maxFPS))
        config.queueDepth = 3 // small queue = low latency
        config.showsCursor = false
        config.capturesAudio = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    public func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    public func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusRaw) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        // Presentation timestamps use the host clock, same as CACurrentMediaTime().
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        onFrame?(Frame(pixelBuffer: pixelBuffer, timestamp: pts.isFinite ? pts : CACurrentMediaTime()))
    }

    public func stream(_: SCStream, didStopWithError error: Error) {
        stream = nil
        onStop?(error)
    }
}
