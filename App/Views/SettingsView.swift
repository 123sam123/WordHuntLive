import SwiftUI
import WordHuntCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            ScoringSettings().tabItem { Label("Scoring", systemImage: "number") }
        }
        .frame(width: 520, height: 460)
    }

    private var general: some View {
        Form {
            Section("Dictionary") {
                Picker("Word list", selection: $model.dictionarySource) {
                    Text(DictionarySource.bundledCommon.displayName).tag(DictionarySource.bundledCommon)
                    Text(DictionarySource.bundledEnable.displayName).tag(DictionarySource.bundledEnable)
                    Text(DictionarySource.systemWords.displayName).tag(DictionarySource.systemWords)
                    if case .file = model.dictionarySource {
                        Text(model.dictionarySource.displayName).tag(model.dictionarySource)
                    }
                }
                HStack {
                    Button("Choose file…") { model.chooseDictionaryFile() }
                    Button("Reload") { model.reloadDictionary() }
                    Spacer()
                    Text(model.dictionaryStatus).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Rejected words") {
                HStack {
                    Text("\(model.rejected.words.count) words the game refused")
                    Spacer()
                    Button("Show file") { model.revealRejectedFile() }
                    Button("Clear") { model.clearRejected() }.disabled(model.rejected.words.isEmpty)
                }
                Text("Press X (or Delete) when the game doesn't accept a suggestion.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Words") {
                Stepper("Minimum word length: \(model.minWordLength)", value: $model.minWordLength, in: 2...8)
                Toggle("Never recommend a word twice", isOn: $model.excludePlayedWords)
            }
            Section("Display") {
                Toggle("Debug panel (D)", isOn: $model.showDebug)
                Toggle("Keep window on top of iPhone Mirroring", isOn: $model.alwaysOnTop)
            }
        }
        .formStyle(.grouped)
    }
}

struct ScoringSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Picker("Scoring", selection: $model.scoringConfig.mode) {
                ForEach(ScoringConfig.Mode.allCases) { Text($0.displayName).tag($0) }
            }
            switch model.scoringConfig.mode {
            case .lengthTable: lengthTable
            case .letterValues: letterValues
            case .tileValues: tileValues
            }
            Button("Reset to defaults") { model.scoringConfig = ScoringConfig() }
        }
        .formStyle(.grouped)
    }

    private var lengthTable: some View {
        Section("Points by word length") {
            ForEach(model.scoringConfig.lengthTable.table.keys.sorted(), id: \.self) { len in
                LabeledContent("\(len) letters") {
                    TextField("", value: binding(len), format: .number).frame(width: 90)
                }
            }
            LabeledContent("Each extra letter") {
                TextField("", value: $model.scoringConfig.lengthTable.extraPerLetter, format: .number).frame(width: 90)
            }
        }
    }

    private func binding(_ len: Int) -> Binding<Int> {
        Binding(get: { model.scoringConfig.lengthTable.table[len] ?? 0 },
                set: { model.scoringConfig.lengthTable.table[len] = $0 })
    }

    private var tileValues: some View {
        Group {
            Section {
                Text("Score = dots on the word's tiles × points per dot × length multiplier. Dots are read from each tile on screen; the table below is only used when a tile's dots can't be read.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Points per dot") {
                    TextField("", value: $model.scoringConfig.tileValues.pointsPerDot, format: .number).frame(width: 70)
                }
            }
            Section("Length multiplier") {
                ForEach(model.scoringConfig.tileValues.lengthMultipliers.keys.sorted(), id: \.self) { len in
                    LabeledContent("\(len) letters") {
                        TextField("", value: Binding(
                            get: { model.scoringConfig.tileValues.lengthMultipliers[len] ?? 1 },
                            set: { model.scoringConfig.tileValues.lengthMultipliers[len] = $0 }),
                            format: .number).frame(width: 70)
                    }
                }
                LabeledContent("Each extra letter adds") {
                    TextField("", value: $model.scoringConfig.tileValues.extraMultiplierPerLetter, format: .number).frame(width: 70)
                }
            }
            Section("Fallback dots per letter") {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(70)), count: 5)) {
                    ForEach(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ"), id: \.self) { ch in
                        HStack(spacing: 4) {
                            Text(String(ch)).font(Theme.mono(12, .bold)).frame(width: 14)
                            TextField("", value: Binding(
                                get: { model.scoringConfig.tileValues.fallbackDots[String(ch)] ?? 1 },
                                set: { model.scoringConfig.tileValues.fallbackDots[String(ch)] = $0 }),
                                format: .number).frame(width: 40)
                        }
                    }
                }
            }
        }
    }

    private var letterValues: some View {
        Section("Letter values") {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(70)), count: 5)) {
                ForEach(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ"), id: \.self) { ch in
                    HStack(spacing: 4) {
                        Text(String(ch)).font(Theme.mono(12, .bold)).frame(width: 14)
                        TextField("", value: Binding(
                            get: { model.scoringConfig.letterValues.letterValues[String(ch)] ?? 1 },
                            set: { model.scoringConfig.letterValues.letterValues[String(ch)] = $0 }),
                            format: .number).frame(width: 40)
                    }
                }
            }
            LabeledContent("Length bonus per letter over 3") {
                TextField("", value: $model.scoringConfig.letterValues.lengthBonus, format: .number).frame(width: 70)
            }
        }
    }
}
