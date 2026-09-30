import Foundation

/// Words the game refused. Persisted as a plain word-per-line file so it can be edited by
/// hand; rejected words are never recommended again, whatever dictionary is loaded.
public struct RejectedWords: Sendable {
    public let fileURL: URL
    public private(set) var words: Set<String> = []

    public init(fileURL: URL) {
        self.fileURL = fileURL
        if let text = try? String(contentsOf: fileURL, encoding: .utf8) {
            let options = DictionaryManager.Options()
            words = Set(DictionaryManager.normalize(text.split(whereSeparator: \.isNewline), options: options))
        }
    }

    public mutating func add(_ word: String) {
        guard words.insert(word.uppercased()).inserted else { return }
        save()
    }

    public mutating func remove(_ word: String) {
        guard words.remove(word.uppercased()) != nil else { return }
        save()
    }

    public mutating func removeAll() {
        words.removeAll()
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = "# Words the game rejected — one per line. Never recommended again.\n"
            + words.sorted().map { $0.lowercased() }.joined(separator: "\n") + "\n"
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
