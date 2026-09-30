import AppKit

/// Development aid: `WHL_SNAPSHOT=/path/out.png` writes a PNG of the main window after
/// `WHL_SNAPSHOT_DELAY` seconds (default 2). Uses the app's own view hierarchy, so it
/// needs no Screen Recording permission.
enum DebugSnapshot {
    @MainActor
    static func scheduleIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["WHL_SNAPSHOT"] else { return }
        let delay = Double(env["WHL_SNAPSHOT_DELAY"] ?? "") ?? 2
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.title == "Word Hunt Live" }),
                  let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            if env["WHL_SNAPSHOT_QUIT"] == "1" { NSApp.terminate(nil) }
        }
    }
}
