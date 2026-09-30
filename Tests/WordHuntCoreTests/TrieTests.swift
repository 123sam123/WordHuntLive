@testable import WordHuntCore
import XCTest

final class TrieTests: XCTestCase {
    func testConstructionCountsDistinctWords() {
        let trie = Trie(words: ["CAT", "CAR", "CART", "CAT", "DOG"])
        XCTAssertEqual(trie.wordCount, 4)
        XCTAssertTrue(trie.contains("CART"))
        XCTAssertTrue(trie.contains("cat"), "lookups are case-insensitive")
        XCTAssertFalse(trie.contains("CA"))
        XCTAssertFalse(trie.contains(""))
    }

    func testPrefixLookup() {
        let trie = Trie(words: ["STONE", "STORE"])
        XCTAssertTrue(trie.hasPrefix("ST"))
        XCTAssertTrue(trie.hasPrefix("STO"))
        XCTAssertTrue(trie.hasPrefix("STONE"))
        XCTAssertFalse(trie.hasPrefix("STX"))
        XCTAssertFalse(trie.hasPrefix("A"))
        XCTAssertNotNil(trie.node(for: "STO"))
        XCTAssertFalse(trie.isWord(trie.node(for: "STO")!))
    }

    func testIgnoresNonLetterWords() {
        let trie = Trie(words: ["DON'T", "OK"])
        XCTAssertEqual(trie.wordCount, 1)
        XCTAssertFalse(trie.hasPrefix("DON'"))
    }

    func testDictionaryNormalization() {
        let raw = ["  stone ", "Paris", "o'clock", "a", "STORE", "store", "# comment", "", "abcdefghijklmnopq"]
        XCTAssertEqual(DictionaryManager.normalize(raw), ["STONE", "STORE"])
    }

    func testBundledDictionaryLoads() async throws {
        let manager = DictionaryManager()
        let loaded = try await manager.load(.bundledEnable)
        XCTAssertGreaterThan(loaded.wordCount, 150_000)
        XCTAssertTrue(loaded.trie.contains("STONE"))
        XCTAssertTrue(loaded.trie.contains("STONES"))
        let reloaded = try await manager.reload()
        XCTAssertEqual(reloaded?.wordCount, loaded.wordCount)
    }
}

final class CommonDictionaryTests: XCTestCase {
    func testCommonListKeepsEverydayWordsAndDropsObscureOnes() async throws {
        let loaded = try await DictionaryManager().load(.bundledCommon)
        XCTAssertGreaterThan(loaded.wordCount, 40_000)
        for w in ["STONE", "STORE", "ASTEROID", "SPINACH", "DISPLAY", "PLASTER", "SNAILS", "HOLES"] {
            XCTAssertTrue(loaded.trie.contains(w), w)
        }
        // Real suggestions from the full ENABLE list that word games tend to reject.
        for w in ["MISUSER", "DICROTAL", "OESTRIN", "SALPIDS", "SIALIDS", "GLYCANS", "SPINACHY", "PLASTRON"] {
            XCTAssertFalse(loaded.trie.contains(w), w)
        }
    }

    func testRejectedWordsPersistAndAreExcluded() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        var rejected = RejectedWords(fileURL: url)
        rejected.add("store")
        XCTAssertEqual(RejectedWords(fileURL: url).words, ["STORE"])
        let rec = Recommender(solver: TrieBoardSolver(trie: Fixtures.trie), scoring: LengthTableScoring.wordHunt)
        XCTAssertEqual(rec.solve(Fixtures.board, excluding: rejected.words).best?.word, "ASTER")
        rejected.removeAll()
        XCTAssertTrue(RejectedWords(fileURL: url).words.isEmpty)
    }
}
