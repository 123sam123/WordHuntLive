import Foundation

/// Where to load the word list from.
/// - `bundledCommon` (default): ~51k everyday words — ENABLE ∩ the 100k most frequent English words.
///   Games like GamePigeon Word Hunt reject many obscure Scrabble words, so this matches them far better.
/// - `bundledEnable`: the full ENABLE Scrabble list (~173k words, public domain).
public enum DictionarySource: Hashable, Codable, Sendable, Identifiable {
    case bundledCommon
    case bundledEnable
    case systemWords
    case file(URL)

    public var id: String {
        switch self {
        case .bundledCommon: "common"
        case .bundledEnable: "enable"
        case .systemWords: "system"
        case let .file(url): url.path
        }
    }

    public var displayName: String {
        switch self {
        case .bundledCommon: "Common words (recommended)"
        case .bundledEnable: "Full ENABLE Scrabble list"
        case .systemWords: "macOS /usr/share/dict/words"
        case let .file(url): url.lastPathComponent
        }
    }

    public var url: URL? {
        switch self {
        case .bundledCommon:
            Bundle.module.url(forResource: "common", withExtension: "txt", subdirectory: "Dictionaries")
        case .bundledEnable:
            Bundle.module.url(forResource: "enable", withExtension: "txt", subdirectory: "Dictionaries")
        case .systemWords:
            URL(fileURLWithPath: "/usr/share/dict/words")
        case let .file(url):
            url
        }
    }
}

public struct LoadedDictionary: Sendable {
    public var source: DictionarySource
    public var trie: Trie
    public var wordCount: Int { trie.wordCount }
    public var loadDuration: TimeInterval
}

public enum DictionaryError: Error, LocalizedError {
    case notFound(DictionarySource)
    case empty(DictionarySource)

    public var errorDescription: String? {
        switch self {
        case let .notFound(s): "Dictionary file not found: \(s.displayName)"
        case let .empty(s): "Dictionary has no usable words: \(s.displayName)"
        }
    }
}

/// Loads, cleans and indexes word lists. Loading runs off the caller's thread (actor).
public actor DictionaryManager {
    public struct Options: Sendable, Equatable {
        /// Words shorter than this are never stored (the solver has its own, usually larger, minimum).
        public var minLength = 2
        /// A 4x4 board can't hold more than 16 letters.
        public var maxLength = 16
        /// Skip entries that start with an uppercase letter (proper nouns in /usr/share/dict/words).
        public var excludeCapitalized = true
        public init() {}
    }

    public private(set) var current: LoadedDictionary?
    public var options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    /// Cleans raw lines: trims, drops comments/proper nouns/non-letters, uppercases, dedupes.
    /// Works on UTF-8 bytes — the bundled list is ~173k lines and this runs on every (re)load.
    public static func normalize<S: Sequence>(_ lines: S, options: Options = Options()) -> [String]
        where S.Element: StringProtocol {
        var seen = Set<String>()
        var out: [String] = []
        var buf: [UInt8] = []
        lineLoop: for raw in lines {
            buf.removeAll(keepingCapacity: true)
            var trailing = false // saw whitespace after the word; only more whitespace may follow
            for b in raw.utf8 {
                if isSpace(b) {
                    if !buf.isEmpty { trailing = true }
                    continue
                }
                if trailing { continue lineLoop }
                if buf.isEmpty {
                    if b == UInt8(ascii: "#") { continue lineLoop }
                    if options.excludeCapitalized, b >= 65, b <= 90 { continue lineLoop }
                }
                switch b {
                case 65...90: buf.append(b)
                case 97...122: buf.append(b - 32)
                default: continue lineLoop
                }
                if buf.count > options.maxLength { continue lineLoop }
            }
            guard buf.count >= options.minLength else { continue }
            let word = String(decoding: buf, as: UTF8.self)
            if seen.insert(word).inserted { out.append(word) }
        }
        return out
    }

    @inline(__always)
    private static func isSpace(_ b: UInt8) -> Bool { b == 32 || b == 9 || b == 10 || b == 13 }

    public static func buildTrie(from text: String, options: Options = Options()) -> Trie {
        let lines = text.utf8.split(separator: UInt8(ascii: "\n")).map { Substring($0) }
        return Trie(words: normalize(lines, options: options))
    }

    @discardableResult
    public func load(_ source: DictionarySource) throws -> LoadedDictionary {
        let start = Date()
        guard let url = source.url, FileManager.default.fileExists(atPath: url.path) else {
            throw DictionaryError.notFound(source)
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        let trie = Self.buildTrie(from: text, options: options)
        guard trie.wordCount > 0 else { throw DictionaryError.empty(source) }
        let loaded = LoadedDictionary(source: source, trie: trie, loadDuration: Date().timeIntervalSince(start))
        current = loaded
        return loaded
    }

    /// Re-reads the current source from disk (e.g. after editing the file).
    @discardableResult
    public func reload() throws -> LoadedDictionary? {
        guard let source = current?.source else { return nil }
        return try load(source)
    }
}
