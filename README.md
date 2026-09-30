# Word Hunt Live

Local macOS companion for 4×4 word-grid games. It watches a mirrored iPhone window, reads the
board, and shows the single best word plus the exact tile path to drag. It never touches the
phone or the game: no input injection, no automation, no network. All processing is on-device.

## Build & run

```sh
scripts/build.sh --run      # xcodegen + Release build + launch
swift test                  # unit/integration tests for WordHuntCore
```

Requires macOS 14+ and Xcode 16+. `xcodegen` (`brew install xcodegen`) is optional; it's only
needed if you change `project.yml`. You can also just open `WordHuntLive.xcodeproj` and press ⌘R.

### First run on a new Mac

1. `git clone https://github.com/123sam123/WordHuntLive.git && cd WordHuntLive && scripts/build.sh --run`
   (this installs the app to /Applications and opens it).
2. Signing: with an Apple Development certificate in your keychain the script signs with it;
   otherwise it signs ad-hoc, which works but macOS will re-ask for Screen Recording after each rebuild.
   If Xcode complains about the bundle identifier, change `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`.
3. Mirror the phone into a window: plug it in by cable, open QuickTime Player → File → New Movie
   Recording → click ⌄ next to the record button → pick the iPhone entry *without* "Camera".
   The phone must be unlocked and must trust the Mac.
4. In Word Hunt Live pick **Screen capture**, choose the QuickTime window, **Start Capture**, and
   allow Screen Recording when asked (then quit and reopen the app once).

## Using it

1. **Static board** (default): type a board in the Simulation panel → best word + path appear instantly.
   *Simulate collapse* plays the word in a collapsing-board game.
2. **Simulated feed**: *Start Capture* renders a fake phone screen at 60 fps and runs the full
   vision pipeline on it. *Simulate play* animates the drag (and collapse), and the pipeline has to
   notice, re-read the changed tiles and re-solve on its own.
3. **Screen capture**: open iPhone Mirroring (or QuickTime movie recording of the phone), choose
   *Screen capture*, pick the window, *Start Capture*, then drag a box around the 4×4 grid (R).
   Calibrations are saved per window in `~/Library/Application Support/WordHuntLive/`.
   Once the board reads correctly, press **Board is correct** so the recognizer learns the game's font.

Shortcuts: Space pause/resume · R recalibrate · D debug panel · Esc stop capture · Return/N "played, next word".
Click any tile to correct it (also teaches the recognizer).

## Layout

```
Sources/WordHuntCore/   (Swift package — everything except UI)
  Models/      GridCoord, Tile, BoardState, WordCandidate/PathPoint
  Board/       BoardGeometry, BoardCalibration + CalibrationStore
  Dictionary/  Trie (flat arrays), DictionaryManager; Resources/Dictionaries/enable.txt
  Solver/      WordSolver protocol, TrieBoardSolver (DFS + trie pruning), PathValidator
  Scoring/     ScoringEngine protocol, LengthTableScoring, LetterValueScoring, GestureComplexity, Recommender
  Vision/      Frame (BGRA), GrayImage sampling, TileFingerprint, GlyphNormalizer
  OCR/         LetterRecognizer protocol, TemplateLetterRecognizer, VisionLetterRecognizer, Composite, Scripted mock
  Tracking/    BoardTracker state machine (motion → settle → OCR changed tiles → vote)
  Capture/     FrameSource protocol, ScreenCaptureSource (ScreenCaptureKit), SimulatedFeed
  Pipeline/    LivePipeline (capture → track → OCR → solve → snapshot)
  Simulation/  SimulatedGame (collapse rules), BoardRenderer (fake phone frames)
App/            SwiftUI app (AppModel, views, BoardPathView overlay)
Tests/          XCTest suite
```

The dictionary is a plain word-per-line file; swap it in Settings (⌘,) or replace `enable.txt`.
The default list, `common.txt`, is the ENABLE entries that also appear among the 100,000 most
frequent words in the OpenSubtitles 2018 frequency list
([hermitdave/FrequencyWords](https://github.com/hermitdave/FrequencyWords)); games reject many
obscure Scrabble words, and this list avoids them. Press X on any suggestion the game refuses and
it's never suggested again (`~/Library/Application Support/WordHuntLive/rejected-words.txt`).

Scoring modes: GamePigeon Word Hunt's length table, tile dots × length multiplier (dots are read
from each tile on screen), or Scrabble-style letter values.

Default scoring is GamePigeon Word Hunt's length table (3→100 … 8→2200, +400/letter) and is editable.
