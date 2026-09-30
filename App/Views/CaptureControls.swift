import SwiftUI
import WordHuntCore

struct CaptureControls: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Panel(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Picker("Source", selection: $model.feed) {
                        ForEach(FeedKind.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    .disabled(model.isCapturing)
                    if model.feed == .screen {
                        Picker("Window", selection: $model.selectedTargetID) {
                            if model.captureTargets.isEmpty { Text("No windows — refresh").tag(String?.none) }
                            ForEach(model.captureTargets) { t in
                                Text(t.displayName).lineLimit(1).tag(Optional(t.id))
                            }
                        }
                        .labelsHidden()
                        .disabled(model.isCapturing)
                        Button { model.refreshTargets() } label: { Image(systemName: "arrow.clockwise") }
                            .help("Refresh window list")
                            .disabled(model.isCapturing)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    if model.isCapturing {
                        Button { model.stopCapture() } label: { Label("Stop", systemImage: "stop.fill") }
                            .help("Stop capture (Esc)")
                        Button { model.togglePause() } label: {
                            Label(model.captureStatus == .paused ? "Resume" : "Pause",
                                  systemImage: model.captureStatus == .paused ? "play.fill" : "pause.fill")
                        }
                        .help("Pause/resume tracking (Space)")
                        Button { model.recalibrate() } label: { Label("Calibrate", systemImage: "viewfinder") }
                            .help("Select the board area (R)")
                    } else {
                        Button { model.startCapture() } label: { Label("Start Capture", systemImage: "record.circle") }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.good)
                            .disabled(model.feed == .manual && !model.dictionaryReady)
                            .help(model.feed == .manual ? "Starts the simulated feed" : "Start capture")
                    }
                    Spacer()
                    if model.isCapturing {
                        Button("Board is correct") { model.learnFromBoard() }
                            .help("Teach the recognizer this game's font from the current (verified) board")
                    }
                }
                .controlSize(.regular)
                if model.feed == .simulator {
                    Label("Simulated feed: this is a fake test board, not your phone. Stop, then choose Screen capture.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.warn)
                } else if model.feed == .screen, !model.isCapturing, model.selectedTarget?.isLikelyPhoneMirror == false {
                    Text("Pick the QuickTime Player window that shows your phone (↻ to refresh the list).")
                        .font(.system(size: 11)).foregroundStyle(Theme.warn)
                }
                if let msg = model.statusMessage {
                    Text(msg).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                } else if model.feed == .screen, model.calibration == nil, model.isCapturing {
                    Text("Calibrate the board (R) so the app knows where the tiles are.")
                        .font(.system(size: 11)).foregroundStyle(Theme.warn)
                }
            }
        }
        .onAppear { if model.feed == .screen { model.refreshTargets() } }
        .onChange(of: model.feed) { _, f in if f == .screen { model.refreshTargets() } }
    }
}
