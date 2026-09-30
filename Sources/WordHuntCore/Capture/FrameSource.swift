import Foundation

/// Anything that produces frames: ScreenCaptureKit, the simulator, a video file…
public protocol FrameSource: AnyObject, Sendable {
    /// Called on a background queue for every frame.
    var onFrame: (@Sendable (Frame) -> Void)? { get set }
    func start() async throws
    func stop() async
}
