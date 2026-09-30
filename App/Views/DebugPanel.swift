import SwiftUI
import WordHuntCore

struct DebugPanel: View {
    @EnvironmentObject var model: AppModel
    @State private var preview: (CGImage, BoardGeometry)?
    private let refresh = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionLabel("Debug")
                if let (img, geo) = preview {
                    group("Captured board · tile boxes") {
                        GeometryReader { g in
                            let s = g.size.width / CGFloat(img.width)
                            ZStack(alignment: .topLeading) {
                                Image(decorative: img, scale: 1).resizable()
                                GridOverlay(rect: CGRect(x: geo.boardRect.minX * s, y: geo.boardRect.minY * s,
                                                         width: geo.boardRect.width * s, height: geo.boardRect.height * s),
                                            inset: geo.tileInset)
                            }
                        }
                        .aspectRatio(CGFloat(img.width) / CGFloat(img.height), contentMode: .fit)
                    }
                }
                group("Board v\(model.board.version) · \(model.trackerPhase.rawValue)") {
                    Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                        ForEach(0..<model.board.rows, id: \.self) { r in
                            GridRow {
                                ForEach(0..<model.board.columns, id: \.self) { c in
                                    tileCell(GridCoord(r, c))
                                }
                            }
                        }
                    }
                }
                group("Timing") {
                    let t = model.timings
                    row("Capture FPS", String(format: "%.0f", t.captureFPS))
                    row("Frame age", ms(t.frameAge))
                    row("Fingerprint + track", ms(t.tracking))
                    row("OCR (changed tiles)", ms(t.recognition))
                    row("Solver", ms(model.solverLatency))
                    row("Capture → result", ms(t.total))
                    row("Words found", "\(model.result.totalWordsFound)")
                    row("Learned glyphs", "\(model.templateRecognizer.learnedCount)")
                }
                group("Candidates (top 40 of \(model.result.ranked.count))") {
                    ForEach(Array(model.result.ranked.prefix(40).enumerated()), id: \.element.word) { i, c in
                        HStack {
                            Text("\(i + 1).").foregroundStyle(Theme.secondaryText).frame(width: 26, alignment: .trailing)
                            Text(c.word).fontWeight(i == 0 ? .bold : .regular)
                            Spacer()
                            Text("\(c.score)")
                            Text(String(format: "cx %.1f", c.complexity)).foregroundStyle(Theme.secondaryText)
                        }
                        .font(Theme.mono(11))
                    }
                }
                if !model.playedWords.isEmpty {
                    group("Played") {
                        Text(model.playedWords.joined(separator: ", ")).font(Theme.mono(11))
                    }
                }
                Button("Forget learned glyphs") { model.forgetLearnedGlyphs() }
                    .controlSize(.small)
            }
            .padding(16)
        }
        .background(Theme.panel)
        .onReceive(refresh) { _ in preview = model.boardPreview() }
    }

    private func tileCell(_ coord: GridCoord) -> some View {
        let t = model.board[coord]
        let rec = model.recognitions[coord]
        return VStack(spacing: 1) {
            Text(String(t.letter)).font(Theme.mono(15, .bold))
            Text(String(format: "%.2f", t.confidence)).font(Theme.mono(9)).foregroundStyle(Theme.secondaryText)
            Text(t.state.rawValue).font(Theme.mono(8)).foregroundStyle(stateColor(t.state))
            if let rec {
                Text("\(rec.letter.map(String.init) ?? "∅") \(rec.engine.prefix(8))")
                    .font(Theme.mono(7)).foregroundStyle(Theme.secondaryText).lineLimit(1)
            }
        }
        .frame(width: 66, height: 58)
        .background(Theme.tile, in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold))
            content()
        }
    }

    func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Theme.secondaryText)
            Spacer()
            Text(value)
        }
        .font(Theme.mono(11))
    }

    func stateColor(_ s: TileState) -> Color {
        switch s {
        case .stable: Theme.secondaryText
        case .disappearing, .falling: Theme.warn
        case .new: Theme.good
        }
    }
}
