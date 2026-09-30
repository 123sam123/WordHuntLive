import AppKit
import SwiftUI
import WordHuntCore

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @State private var editingTile: GridCoord?

    private var dotProvider: ((Tile) -> Int?)? {
        guard model.scoringConfig.mode == .tileValues else { return nil }
        let model = model
        return { model.dotValue($0) }
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 14) {
                    HeaderBar()
                    CaptureControls()
                    RecommendationCard(candidate: model.best, board: model.board, played: model.playedWords.count)
                    Panel(padding: 14) {
                        BoardPathView(board: model.board, candidate: model.best,
                                      showConfidence: model.showDebug,
                                      dotValue: dotProvider) { coord in
                            editingTile = coord
                        }
                    }
                    StatsBar()
                    if model.feed != .screen { SimulationPanel() }
                }
                .padding(16)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .frame(minWidth: 480)
            if model.showDebug {
                Divider()
                DebugPanel()
                    .frame(width: 340)
                    .transition(.move(edge: .trailing))
            }
        }
        .background(Theme.background)
        .animation(.easeOut(duration: 0.2), value: model.showDebug)
        .onChange(of: model.showDebug) { _, shown in resizeWindowForDebug(shown) }
        .onAppear {
            DispatchQueue.main.async {
                model.applyWindowLevel()
                if model.showDebug { resizeWindowForDebug(true) }
            }
        }
        .sheet(item: $model.calibrationRequest) { req in
            CalibrationView(request: req) { model.confirmCalibration($0) }
                .preferredColorScheme(.dark)
        }
        .sheet(item: $editingTile) { coord in
            TileEditor(coord: coord, current: model.board[coord].letter) { letter in
                model.correctTile(coord, to: letter)
            }
        }
    }
}

/// Widens (or narrows) the window by the debug panel's width so the main column never gets squeezed.
@MainActor
private func resizeWindowForDebug(_ shown: Bool) {
    guard let window = NSApp.windows.first(where: { $0.title == "Word Hunt Live" }) else { return }
    var frame = window.frame
    let needed: CGFloat = shown ? 520 + 341 : 520
    if shown, frame.width < needed { frame.size.width = needed }
    else if !shown, frame.width > needed { frame.size.width = max(needed, frame.width - 341) }
    else { return }
    window.setFrame(frame, display: true, animate: true)
}

extension GridCoord: @retroactive Identifiable {
    public var id: Int { row * 100 + column }
}

struct HeaderBar: View {
    @EnvironmentObject var model: AppModel

    private var statusText: String {
        switch model.captureStatus {
        case .off: model.feed == .screen ? "Not capturing" : "Static board"
        case .starting: "Starting…"
        case .running: "\(model.feed == .simulator ? "Simulator" : "Live") · \(model.trackerPhase.rawValue)"
        case .paused: "Paused"
        case let .failed(msg): msg
        }
    }

    private var statusColor: Color {
        switch model.captureStatus {
        case .running: model.trackerPhase == .stable ? Theme.good : Theme.warn
        case .starting, .paused: Theme.warn
        case .failed: Theme.bad
        case .off: Theme.secondaryText
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("WORD HUNT LIVE")
                    .font(.system(size: 15, weight: .black, design: .rounded))
                    .tracking(2)
                StatusPill(text: statusText, color: statusColor)
            }
            Spacer()
            Button { model.alwaysOnTop.toggle() } label: {
                Label("Keep on top", systemImage: model.alwaysOnTop ? "pin.fill" : "pin")
            }
            .help(model.alwaysOnTop ? "Floating above other windows — click to release" : "Keep this window above iPhone Mirroring")
            Button { model.showDebug.toggle() } label: {
                Label("Debug", systemImage: "ladybug")
            }
            .help("Toggle debug panel (D)")
            SettingsLink {
                Label("Settings", systemImage: "slider.horizontal.3")
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.system(size: 15))
    }
}

struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
        .foregroundStyle(color)
    }
}

struct RecommendationCard: View {
    let candidate: WordCandidate?
    let board: BoardState
    let played: Int
    @EnvironmentObject var model: AppModel

    var body: some View {
        Panel(padding: 18) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    SectionLabel("Best word")
                    Spacer()
                    if played > 0 {
                        Text("\(played) played").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                    }
                }
                if let c = candidate {
                    HStack(alignment: .firstTextBaseline) {
                        Text(c.word)
                            .font(.system(size: 52, weight: .black, design: .rounded))
                            .tracking(3)
                            .foregroundStyle(Theme.tileText)
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                            .contentTransition(.numericText())
                        Spacer()
                        VStack(alignment: .trailing, spacing: 0) {
                            Text("\(c.score)")
                                .font(.system(size: 30, weight: .heavy, design: .rounded))
                                .foregroundStyle(Theme.path)
                                .contentTransition(.numericText())
                            Text("POINTS").font(.system(size: 10, weight: .bold)).tracking(1.5)
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                    if model.scoringConfig.mode == .tileValues {
                        let dots = c.coordinates.reduce(0) { $0 + (model.dotValue(board[$1]) ?? 0) }
                        let mult = model.scoringConfig.tileValues.multiplier(forLength: c.word.count)
                        Text("\(dots) dots × \(model.scoringConfig.tileValues.pointsPerDot) × \(mult.formatted())× length bonus")
                            .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                    }
                    Text(c.coordinates.map { String(board[$0].letter) }.joined(separator: "  →  "))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.path.opacity(0.9))
                    HStack(spacing: 12) {
                        Button("Played ⏎") { model.markBestPlayed() }
                            .help("Mark as played and show the next best word (Return)")
                        Button("✗ Not a word (X)") { model.rejectBest() }
                            .foregroundStyle(Theme.bad)
                            .help("The game rejected it: never suggest this word again (X or Delete)")
                        if played > 0 {
                            Button("Reset played") { model.resetPlayedWords() }
                        }
                        Spacer()
                        if c.confidence < 0.999 {
                            Text(String(format: "read confidence %.0f%%", c.confidence * 100))
                                .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.top, 4)
                } else {
                    Text(model.dictionaryReady ? "—" : "…")
                        .font(.system(size: 52, weight: .black, design: .rounded))
                        .foregroundStyle(Theme.secondaryText)
                    Text(emptyReason).font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.snappy(duration: 0.2), value: candidate?.word)
        }
    }

    private var emptyReason: String {
        if !model.dictionaryReady { return model.dictionaryStatus }
        if !board.isComplete && board.version == 0 { return "Waiting for a board." }
        return "No words found on this board."
    }
}

struct TileEditor: View {
    let coord: GridCoord
    let current: Character
    let onCommit: (Character) -> Void
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text("Correct tile row \(coord.row + 1), column \(coord.column + 1)")
                .font(.headline)
            TextField(String(current), text: $text)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
                .frame(width: 80)
                .onSubmit(commit)
                .onChange(of: text) { _, new in
                    if let ch = new.uppercased().last(where: { ("A"..."Z").contains($0) }) {
                        text = String(ch)
                    } else if !new.isEmpty { text = "" }
                }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Set", action: commit).keyboardShortcut(.defaultAction).disabled(text.isEmpty)
            }
        }
        .padding(24)
    }

    private func commit() {
        guard let ch = text.first else { return }
        onCommit(ch)
        dismiss()
    }
}
