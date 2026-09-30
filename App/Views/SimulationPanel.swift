import SwiftUI
import WordHuntCore

/// Static board entry + simulated collapse, for testing without a phone.
struct SimulationPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Panel(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionLabel(model.feed == .simulator ? "Simulation · vision pipeline" : "Simulation · static board")
                    Spacer()
                    Text(model.dictionaryStatus).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
                HStack(alignment: .top, spacing: 12) {
                    TextEditor(text: $model.boardInputText)
                        .font(Theme.mono(17, .semibold))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(Theme.background, in: RoundedRectangle(cornerRadius: 8))
                        .frame(width: 130, height: 104)
                    VStack(alignment: .leading, spacing: 8) {
                        Button("Load board") { model.applyBoardText() }
                            .keyboardShortcut(.return, modifiers: .command)
                        Button("Random board") { model.randomizeBoard() }
                        Button(model.feed == .simulator ? "Simulate play" : "Simulate collapse") { model.simulatePlay() }
                            .disabled(model.best == nil)
                            .help("Play the best word: the tiles are dragged, then (collapse mode) vanish, fall and refill")
                        if model.feed == .simulator {
                            Picker("", selection: $model.simulatorMode) {
                                Text("Collapse").tag(SimulatedFeed.Mode.collapse)
                                Text("Static").tag(SimulatedFeed.Mode.staticBoard)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 150)
                        }
                        if let err = model.boardInputError {
                            Text(err).font(.system(size: 11)).foregroundStyle(Theme.bad)
                        } else {
                            Text("⌘⏎ load · click a tile to correct it")
                                .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }
}
