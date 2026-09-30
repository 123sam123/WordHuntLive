import SwiftUI
import WordHuntCore

struct StatsBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let t = model.timings
        let live = model.isCapturing
        Panel(padding: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), alignment: .leading, spacing: 10) {
                Stat(label: "Board conf.", value: percent(model.board.confidence), color: confColor(model.board.confidence))
                Stat(label: "Capture FPS", value: live ? String(format: "%.0f", t.captureFPS) : "—")
                Stat(label: "Recognition", value: live ? ms(t.recognition) : "—")
                Stat(label: "Solver", value: ms(model.solverLatency))
                Stat(label: "Pipeline", value: live ? ms(t.total) : "—", color: latencyColor(t.total, live))
                Stat(label: "Board ver.", value: "v\(model.board.version)")
                Stat(label: "Words found", value: "\(model.result.totalWordsFound)")
                Stat(label: "Capture", value: model.captureStatus.label)
            }
        }
    }

    private func percent(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }
    private func confColor(_ v: Double) -> Color { v >= 0.85 ? Theme.good : v >= 0.6 ? Theme.warn : Theme.bad }
    private func latencyColor(_ v: TimeInterval, _ live: Bool) -> Color {
        guard live else { return Theme.tileText }
        return v < 0.1 ? Theme.good : v < 0.2 ? Theme.warn : Theme.bad
    }
}

func ms(_ seconds: TimeInterval) -> String {
    let v = seconds * 1000
    return v < 1 ? String(format: "%.2f ms", v) : String(format: "%.0f ms", v)
}

struct Stat: View {
    let label: String
    let value: String
    var color: Color = Theme.tileText

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(0.8)
                .foregroundStyle(Theme.secondaryText).lineLimit(1)
            Text(value).font(Theme.mono(13, .medium)).foregroundStyle(color).lineLimit(1)
        }
    }
}
