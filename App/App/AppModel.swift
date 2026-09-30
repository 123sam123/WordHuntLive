import AppKit
import Combine
import SwiftUI
import WordHuntCore

/// Where boards come from.
enum FeedKind: String, CaseIterable, Identifiable {
    /// Typed-in static board; no vision at all.
    case manual
    /// Rendered fake phone screen run through the full vision pipeline.
    case simulator
    /// ScreenCaptureKit on a real window (iPhone Mirroring, QuickTime, …).
    case screen

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .manual: "Static board"
        case .simulator: "Simulated feed"
        case .screen: "Screen capture"
        }
    }
}

enum CaptureStatus: Equatable {
    case off, starting, running, paused, failed(String)

    var label: String {
        switch self {
        case .off: "Off"
        case .starting: "Starting"
        case .running: "Live"
        case .paused: "Paused"
        case .failed: "Error"
        }
    }
}

/// Main-actor view model. Owns settings, the dictionary, the current board and the
/// recommendation. Capture, vision and solving for live feeds run in `LivePipeline`
/// on its own queue; this object only mirrors the pipeline's snapshots.
@MainActor
final class AppModel: ObservableObject {
    // MARK: Board + recommendation

    @Published private(set) var board: BoardState = .empty()
    @Published private(set) var result: SolveResult = .empty
    @Published private(set) var playedWords: [String] = []
    @Published private(set) var rejected = RejectedWords(
        fileURL: CalibrationStore.defaultDirectory.appendingPathComponent("rejected-words.txt"))
    @Published var boardInputText: String
    @Published var boardInputError: String?

    var best: WordCandidate? { result.best }

    // MARK: Dictionary

    @Published private(set) var dictionaryStatus: String = "Loading dictionary…"
    @Published private(set) var dictionaryReady = false
    private let dictionaryManager = DictionaryManager()
    private var trie: Trie?

    // MARK: Settings (persisted)

    @Published var dictionarySource: DictionarySource {
        didSet { persist(dictionarySource, key: Keys.dictionarySource); Task { await loadDictionary() } }
    }
    @Published var minWordLength: Int {
        didSet { defaults.set(minWordLength, forKey: Keys.minLength); settingsChanged() }
    }
    @Published var scoringConfig: ScoringConfig {
        didSet {
            persist(scoringConfig, key: Keys.scoring)
            settingsChanged()
            simFeed?.setDotValues(simulatorDots)
        }
    }

    /// Dots shown for a tile: read from the screen, else the fallback table.
    func dotValue(_ tile: Tile) -> Int? {
        guard tile.isKnown else { return nil }
        return tile.value ?? scoringConfig.tileValues.fallbackDots[String(tile.letter)]
    }

    /// The simulator draws dots under letters while dot scoring is selected.
    private var simulatorDots: [Character: Int]? {
        guard scoringConfig.mode == .tileValues else { return nil }
        return scoringConfig.tileValues.fallbackDots.reduce(into: [:]) { $0[Character($1.key)] = $1.value }
    }
    @Published var excludePlayedWords: Bool {
        didSet { defaults.set(excludePlayedWords, forKey: Keys.excludePlayed); settingsChanged() }
    }
    @Published var showDebug: Bool {
        didSet { defaults.set(showDebug, forKey: Keys.debug) }
    }
    /// Keeps the window above iPhone Mirroring (and on every Space) so both are visible while playing.
    @Published var alwaysOnTop: Bool {
        didSet { defaults.set(alwaysOnTop, forKey: Keys.onTop); applyWindowLevel() }
    }
    @Published var simulatorMode: SimulatedFeed.Mode = .collapse {
        didSet { simFeed?.setMode(simulatorMode) }
    }

    // MARK: Capture

    @Published var feed: FeedKind = .screen {
        didSet { defaults.set(feed.rawValue, forKey: Keys.feed) }
    }
    @Published private(set) var captureStatus: CaptureStatus = .off
    @Published private(set) var captureTargets: [CaptureTarget] = []
    @Published var selectedTargetID: String?
    @Published private(set) var calibration: BoardCalibration?
    @Published var calibrationRequest: CalibrationRequest?
    @Published private(set) var trackerPhase: BoardTracker.Phase = .waiting
    @Published private(set) var recognitions: [GridCoord: LetterRecognitionResult] = [:]
    @Published var statusMessage: String?

    struct CalibrationRequest: Identifiable {
        let id = UUID()
        let image: CGImage
        let sourceID: String
        let sourceName: String
        let initial: BoardGeometry?
    }

    private var pipeline: LivePipeline?
    private var source: (any FrameSource)?
    private var simFeed: SimulatedFeed?
    private let calibrationStore = CalibrationStore()
    let templateRecognizer = TemplateLetterRecognizer()
    private var learnedTemplatesURL: URL {
        CalibrationStore.defaultDirectory.appendingPathComponent("learned-glyphs.json")
    }

    var isCapturing: Bool {
        switch captureStatus {
        case .running, .paused, .starting: true
        default: false
        }
    }

    // MARK: Metrics

    @Published private(set) var timings = PipelineTimings()
    @Published private(set) var solverLatency: TimeInterval = 0

    // MARK: Manual simulation

    private var simGame: SimulatedGame?
    private var simSeed: UInt64 = 1

    private let defaults = UserDefaults.standard
    private var keyMonitor: Any?

    enum Keys {
        static let dictionarySource = "dictionarySource"
        static let minLength = "minWordLength"
        static let scoring = "scoringConfig"
        static let excludePlayed = "excludePlayedWords"
        static let debug = "showDebug"
        static let boardText = "boardInputText"
        static let target = "captureTargetID"
        static let onTop = "alwaysOnTop"
        static let feed = "feedKind"
        static let migratedCommon = "migratedToCommonDictionary"
    }

    init() {
        // The full ENABLE list suggested too many words games reject; move old installs to the common list once.
        let savedSource = Self.load(DictionarySource.self, key: Keys.dictionarySource)
        if savedSource == .bundledEnable, !UserDefaults.standard.bool(forKey: Keys.migratedCommon) {
            dictionarySource = .bundledCommon
        } else {
            dictionarySource = savedSource ?? .bundledCommon
        }
        UserDefaults.standard.set(true, forKey: Keys.migratedCommon)
        let savedMin = defaults.integer(forKey: Keys.minLength)
        minWordLength = savedMin >= 2 ? savedMin : 3
        scoringConfig = Self.load(ScoringConfig.self, key: Keys.scoring) ?? ScoringConfig()
        excludePlayedWords = defaults.object(forKey: Keys.excludePlayed) as? Bool ?? true
        showDebug = defaults.bool(forKey: Keys.debug)
        alwaysOnTop = defaults.object(forKey: Keys.onTop) as? Bool ?? true
        boardInputText = defaults.string(forKey: Keys.boardText) ?? "S T O N\nA E R I\nP L D C\nM B G H"
        selectedTargetID = defaults.string(forKey: Keys.target)
        feed = FeedKind(rawValue: defaults.string(forKey: Keys.feed) ?? "") ?? .screen
        templateRecognizer.loadLearned(from: learnedTemplatesURL)
        installKeyMonitor()
        Task { await loadDictionary() }
        DebugSnapshot.scheduleIfRequested()
        runDevScriptIfRequested()
    }

    /// Development aid: `WHL_AUTOSTART=simulator` starts the simulated feed on launch, and
    /// `WHL_AUTOPLAY=1.5` "plays" the recommended word after that many seconds.
    private func runDevScriptIfRequested() {
        let env = ProcessInfo.processInfo.environment
        if env["WHL_DEBUG_PANEL"] == "1" { showDebug = true }
        if let mode = env["WHL_SCORING"].flatMap(ScoringConfig.Mode.init(rawValue:)) { scoringConfig.mode = mode }
        guard env["WHL_AUTOSTART"] == "simulator" else { return }
        Task {
            while !dictionaryReady { try? await Task.sleep(for: .milliseconds(50)) }
            feed = .simulator
            startCapture()
            if let delay = Double(env["WHL_AUTOPLAY"] ?? "") {
                try? await Task.sleep(for: .seconds(delay))
                simulatePlay()
            }
        }
    }

    // MARK: Dictionary

    func loadDictionary() async {
        dictionaryReady = false
        dictionaryStatus = "Loading \(dictionarySource.displayName)…"
        do {
            let loaded = try await dictionaryManager.load(dictionarySource)
            trie = loaded.trie
            dictionaryReady = true
            dictionaryStatus = "\(loaded.wordCount.formatted()) words · \(dictionarySource.displayName)"
            if board.version == 0, feed == .manual { applyBoardText() } else { settingsChanged() }
        } catch {
            dictionaryStatus = error.localizedDescription
        }
    }

    func reloadDictionary() {
        Task { await loadDictionary() }
    }

    func chooseDictionaryFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a word list (one word per line)"
        if panel.runModal() == .OK, let url = panel.url {
            dictionarySource = .file(url)
        }
    }

    // MARK: Solving

    private var recommender: Recommender? {
        guard let trie else { return nil }
        return Recommender(solver: TrieBoardSolver(trie: trie), scoring: scoringConfig.makeEngine(), minLength: minWordLength)
    }

    private func settingsChanged() {
        if let pipeline {
            pipeline.update(recommender: recommender, excludePlayed: excludePlayedWords)
        } else {
            resolve()
        }
    }

    /// Re-runs the solver on the current board (manual mode). Sub-millisecond, so inline.
    func resolve() {
        guard let recommender else { return }
        let excluded = rejected.words.union(excludePlayedWords ? Set(playedWords) : [])
        let r = recommender.solve(board, excluding: excluded)
        result = r
        solverLatency = r.duration
    }

    private func setBoard(_ newBoard: BoardState) {
        board = newBoard
        resolve()
    }

    // MARK: Played words

    /// "I played it" — excludes the current best word and shows the next one.
    func markBestPlayed() {
        guard let word = best?.word else { return }
        if let pipeline {
            pipeline.markPlayed(word)
        } else if !playedWords.contains(word) {
            playedWords.append(word)
            resolve()
        }
    }

    /// "The game didn't accept that" — never suggest it again and show the next word.
    func rejectBest() {
        guard let word = best?.word else { return }
        rejected.add(word)
        statusMessage = "“\(word)” won't be suggested again (\(rejected.words.count) rejected)."
        if let pipeline { pipeline.update(blocked: rejected.words) } else { resolve() }
    }

    func clearRejected() {
        rejected.removeAll()
        if let pipeline { pipeline.update(blocked: rejected.words) } else { resolve() }
    }

    func revealRejectedFile() {
        NSWorkspace.shared.activateFileViewerSelecting([rejected.fileURL])
    }

    func resetPlayedWords() {
        if let pipeline {
            pipeline.resetPlayed()
        } else {
            playedWords.removeAll()
            resolve()
        }
    }

    // MARK: Static board input

    func applyBoardText() {
        do {
            let parsed = try BoardState.parse(boardInputText)
            boardInputError = nil
            defaults.set(boardInputText, forKey: Keys.boardText)
            if feed == .simulator, let simFeed {
                simFeed.setBoard(parsed, seed: simSeed)
                pipeline?.reset()
                return
            }
            simGame = SimulatedGame(board: parsed, seed: simSeed)
            playedWords.removeAll()
            setBoard(parsed)
        } catch {
            boardInputError = error.localizedDescription
        }
    }

    func randomizeBoard() {
        simSeed &+= 1
        let game = SimulatedGame.random(seed: UInt64(Date().timeIntervalSince1970) &+ simSeed)
        boardInputText = game.board.gridText
        applyBoardText()
    }

    /// Simulates the user playing the recommended word.
    /// - Simulated feed: the fake phone animates the drag (and collapse), and the vision
    ///   pipeline has to notice, re-read the changed tiles and re-solve on its own.
    /// - Static board: the collapse is applied directly to the board state.
    func simulatePlay() {
        guard let word = best else { return }
        if feed == .simulator, let simFeed {
            simFeed.play(word.coordinates)
            return
        }
        var game = simGame ?? SimulatedGame(board: board, seed: simSeed)
        let collapse = game.collapse(word.coordinates)
        simGame = game
        var next = board
        next.apply(game.board.tiles.map { BoardState.LetterUpdate(coord: $0.coord, letter: $0.letter, confidence: 1) })
        for c in collapse.changed { next.setState(.new, at: c) }
        boardInputText = next.gridText
        if !playedWords.contains(word.word) { playedWords.append(word.word) }
        setBoard(next)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            var settled = self.board
            for c in collapse.changed { settled.setState(.stable, at: c) }
            self.board = settled
        }
    }

    /// Manual correction of a single tile (clicking a tile in the board view).
    func correctTile(_ coord: GridCoord, to letter: Character) {
        if let pipeline {
            pipeline.correct(coord, letter: letter)
            saveLearnedSoon()
            return
        }
        var next = board
        next.apply([.init(coord: coord, letter: letter, confidence: 1)])
        boardInputText = next.gridText
        simGame = SimulatedGame(board: next, seed: simSeed)
        setBoard(next)
    }

    /// The user confirms the board on screen is read correctly: learn the game's glyphs.
    func learnFromBoard() {
        pipeline?.learnCurrentBoard { [weak self] n in
            Task { @MainActor in
                self?.statusMessage = "Learned \(n) tile glyphs from this board."
                self?.saveLearnedSoon()
            }
        }
    }

    func forgetLearnedGlyphs() {
        templateRecognizer.forgetLearned()
        try? FileManager.default.removeItem(at: learnedTemplatesURL)
        statusMessage = "Forgot learned glyphs."
    }

    private func saveLearnedSoon() {
        let url = learnedTemplatesURL
        let rec = templateRecognizer
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(200))
            try? rec.saveLearned(to: url)
        }
    }

    // MARK: Capture targets

    func refreshTargets() {
        Task {
            do {
                captureTargets = try await ScreenCaptureSource.availableTargets()
                let current = captureTargets.first { $0.id == selectedTargetID }
                if current == nil || current?.isLikelyPhoneMirror == false,
                   let mirror = captureTargets.first(where: \.isLikelyPhoneMirror) {
                    selectedTargetID = mirror.id
                } else if current == nil {
                    selectedTargetID = captureTargets.first?.id
                }
            } catch {
                captureStatus = .failed(error.localizedDescription)
                statusMessage = error.localizedDescription
            }
        }
    }

    var selectedTarget: CaptureTarget? { captureTargets.first { $0.id == selectedTargetID } }

    // MARK: Capture lifecycle

    func startCapture() {
        guard !isCapturing else { return }
        switch feed {
        case .manual:
            feed = .screen
            startScreenCapture()
        case .simulator:
            startSimulator()
        case .screen:
            startScreenCapture()
        }
    }

    private func makePipeline(geometry: BoardGeometry) -> LivePipeline {
        let recognizer = CompositeLetterRecognizer(primary: templateRecognizer, fallback: VisionLetterRecognizer(), threshold: 0.7)
        let p = LivePipeline(geometry: geometry, recognizer: recognizer, recommender: recommender)
        p.learner = templateRecognizer
        p.update(blocked: rejected.words)
        p.update(recommender: recommender, excludePlayed: excludePlayedWords)
        p.onSnapshot = { [weak self] snap in
            Task { @MainActor in self?.apply(snap) }
        }
        return p
    }

    private func apply(_ snap: PipelineSnapshot) {
        guard pipeline != nil else { return }
        if snap.board != board { board = snap.board }
        if snap.result.best != result.best || snap.result.boardVersion != result.boardVersion
            || snap.result.ranked.count != result.ranked.count {
            result = snap.result
        }
        if snap.playedWords != playedWords { playedWords = snap.playedWords }
        timings = snap.timings
        solverLatency = snap.timings.solve
        trackerPhase = snap.phase
        if showDebug { recognitions = snap.recognitions }
    }

    private func startSimulator() {
        let parsed = (try? BoardState.parse(boardInputText)) ?? Fixtures.defaultBoard
        let feedSource = SimulatedFeed(board: parsed, mode: simulatorMode, seed: simSeed)
        feedSource.setDotValues(simulatorDots)
        let geometry = BoardGeometry(boardRect: feedSource.renderer.normalizedBoardRect, tileInset: 0.08)
        calibration = BoardCalibration(sourceID: "simulator", sourceName: "Simulator", geometry: geometry)
        run(source: feedSource, geometry: geometry)
        simFeed = feedSource
    }

    private func startScreenCapture() {
        guard let target = selectedTarget else {
            statusMessage = "Choose a window to capture first."
            refreshTargets()
            return
        }
        defaults.set(target.id, forKey: Keys.target)
        let saved = calibrationStore.load(sourceID: target.id)
        calibration = saved
        // Without a calibration the pipeline runs on a placeholder; we ask for one on the first frame.
        let geometry = saved?.geometry ?? BoardGeometry(boardRect: CGRect(x: 0.1, y: 0.35, width: 0.8, height: 0.37))
        let capture = ScreenCaptureSource(target: target)
        capture.onStop = { [weak self] error in
            Task { @MainActor in
                self?.teardown()
                self?.captureStatus = .failed(error?.localizedDescription ?? "Capture stopped")
            }
        }
        run(source: capture, geometry: geometry)
        if saved == nil {
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                recalibrate()
            }
        }
    }

    private func run(source newSource: any FrameSource, geometry: BoardGeometry) {
        playedWords.removeAll()
        board = .empty()
        result = .empty
        let p = makePipeline(geometry: geometry)
        newSource.onFrame = { [weak p] frame in p?.submit(frame) }
        pipeline = p
        source = newSource
        captureStatus = .starting
        Task {
            do {
                try await newSource.start()
                if captureStatus == .starting { captureStatus = .running }
            } catch {
                teardown()
                captureStatus = .failed(error.localizedDescription)
                statusMessage = error.localizedDescription
            }
        }
    }

    func stopCapture() {
        guard isCapturing || pipeline != nil else { return }
        teardown()
        captureStatus = .off
        timings = PipelineTimings()
        trackerPhase = .waiting
        if feed != .screen {
            feed = .manual
            applyBoardText()
        }
    }

    private func teardown() {
        let old = source
        source = nil
        pipeline?.onSnapshot = nil
        pipeline = nil
        simFeed = nil
        Task { await old?.stop() }
    }

    func togglePause() {
        guard let pipeline else { return }
        switch captureStatus {
        case .running:
            pipeline.isPaused = true
            captureStatus = .paused
        case .paused:
            pipeline.isPaused = false
            captureStatus = .running
        default: break
        }
    }

    // MARK: Calibration

    /// Opens the calibration sheet on the latest captured frame.
    func recalibrate() {
        guard let pipeline, let frame = pipeline.currentFrame(), let image = frame.cgImage() else {
            statusMessage = isCapturing ? "Waiting for the first frame…" : "Start capture first, then calibrate."
            return
        }
        let (id, name): (String, String) = feed == .simulator ? ("simulator", "Simulator")
            : (selectedTarget?.id ?? "unknown", selectedTarget?.displayName ?? "Capture")
        calibrationRequest = CalibrationRequest(image: image, sourceID: id, sourceName: name, initial: calibration?.geometry)
    }

    func confirmCalibration(_ cal: BoardCalibration) {
        calibration = cal
        if cal.sourceID != "simulator" { try? calibrationStore.save(cal) }
        pipeline?.update(geometry: cal.geometry)
        statusMessage = "Board calibrated."
    }

    /// Latest frame cropped to the board, for the debug panel.
    func boardPreview() -> (CGImage, BoardGeometry)? {
        guard let frame = pipeline?.currentFrame(), let cal = calibration else { return nil }
        let px = cal.geometry.scaled(toWidth: CGFloat(frame.width), height: CGFloat(frame.height))
        let crop = px.boardRect.insetBy(dx: -px.boardRect.width * 0.03, dy: -px.boardRect.height * 0.03)
        guard let img = frame.cgImage(cropping: crop) else { return nil }
        var local = px
        local.boardRect = px.boardRect.offsetBy(dx: -crop.minX, dy: -crop.minY)
        return (img, local)
    }

    // MARK: Window

    func applyWindowLevel() {
        guard let window = NSApp.windows.first(where: { $0.title == "Word Hunt Live" }) else { return }
        window.level = alwaysOnTop ? .floating : .normal
        if alwaysOnTop {
            window.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
        } else {
            window.collectionBehavior.remove([.canJoinAllSpaces, .fullScreenAuxiliary])
        }
    }

    // MARK: Keyboard shortcuts

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Don't steal keys from text fields, sheets, or ⌘/⌃/⌥ shortcuts.
            if NSApp.keyWindow?.firstResponder is NSText { return event }
            if NSApp.keyWindow?.sheetParent != nil || NSApp.keyWindow?.attachedSheet != nil { return event }
            if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    /// Returns true if the key was handled.
    func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 49: togglePause(); return true // space
        case 53: stopCapture(); return true // esc
        case 36, 76: markBestPlayed(); return true // return / enter
        case 51, 117: rejectBest(); return true // delete / forward-delete
        default: break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "r": recalibrate(); return true
        case "d": showDebug.toggle(); return true
        case "n": markBestPlayed(); return true
        case "x": rejectBest(); return true
        default: return false
        }
    }

    // MARK: Persistence helpers

    private func persist<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

enum Fixtures {
    static let defaultBoard = try! BoardState.parse("STON AERI PLDC MBGH")
}
