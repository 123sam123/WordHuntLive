@testable import WordHuntCore
import XCTest

enum Fixtures {
    /// The deterministic board from the spec.
    static let boardText = """
    S T O N
    A E R I
    P L D C
    M B G H
    """

    static var board: BoardState { try! BoardState.parse(boardText) }

    /// Small, hand-checked dictionary for solver tests.
    static let words = ["STONE", "STORE", "TONE", "NOTE", "SEA", "TEA", "EAT", "SET", "TOE", "ORE",
                        "ROD", "LED", "PLED", "SEAL", "TEAL", "STAR", "RID", "IRE", "DIRE",
                        "ASTER", "RATE", "TOTE", "NOON", "LEAP", "PALE", "ZEBRA", "AT"]

    static var trie: Trie { Trie(words: words) }

    static var fullTrie: Trie = {
        let url = DictionarySource.bundledEnable.url!
        return DictionaryManager.buildTrie(from: try! String(contentsOf: url, encoding: .utf8))
    }()
}

extension Array where Element == GridCoord {
    static func path(_ pairs: (Int, Int)...) -> [GridCoord] { pairs.map { GridCoord($0.0, $0.1) } }
}
