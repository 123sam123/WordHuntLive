import Foundation

/// A compact A–Z prefix tree stored in flat arrays (26 child slots per node).
/// Immutable after construction, so it's freely shareable across threads.
public struct Trie: Sendable {
    public typealias Node = Int32
    public static let root: Node = 0
    static let alphabet = 26

    /// `children[node * 26 + letter]` is the child node, or 0 (root is never a child).
    private var children: [Node]
    private var terminal: [Bool]
    public private(set) var wordCount: Int

    public init<S: Sequence>(words: S) where S.Element == String {
        children = Array(repeating: 0, count: Trie.alphabet)
        terminal = [false]
        wordCount = 0
        children.reserveCapacity(Trie.alphabet * 1024)
        for w in words { insert(w) }
    }

    public var nodeCount: Int { terminal.count }

    /// Letter index for an uppercase A–Z character, nil otherwise.
    @inline(__always)
    public static func index(of ch: Character) -> Int? {
        guard let a = ch.asciiValue, a >= 65, a <= 90 else { return nil }
        return Int(a - 65)
    }

    private mutating func insert(_ word: String) {
        var node = Trie.root
        for var byte in word.utf8 {
            if byte >= 97, byte <= 122 { byte -= 32 } // lowercase → uppercase
            guard byte >= 65, byte <= 90 else { return }
            let slot = Int(node) * Trie.alphabet + Int(byte - 65)
            var next = children[slot]
            if next == 0 {
                next = Node(terminal.count)
                terminal.append(false)
                children.append(contentsOf: repeatElement(0, count: Trie.alphabet))
                children[slot] = next
            }
            node = next
        }
        if node != Trie.root, !terminal[Int(node)] {
            terminal[Int(node)] = true
            wordCount += 1
        }
    }

    @inline(__always)
    public func child(of node: Node, letterIndex: Int) -> Node? {
        let n = children[Int(node) * Trie.alphabet + letterIndex]
        return n == 0 ? nil : n
    }

    @inline(__always)
    public func isWord(_ node: Node) -> Bool { terminal[Int(node)] }

    /// The node reached by `prefix`, or nil if no word starts with it.
    public func node(for prefix: String) -> Node? {
        var node = Trie.root
        for ch in prefix.uppercased() {
            guard let li = Trie.index(of: ch), let next = child(of: node, letterIndex: li) else { return nil }
            node = next
        }
        return node
    }

    public func contains(_ word: String) -> Bool {
        guard !word.isEmpty, let n = node(for: word) else { return false }
        return isWord(n)
    }

    public func hasPrefix(_ prefix: String) -> Bool { node(for: prefix) != nil }
}
