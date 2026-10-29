import Foundation

/// How common English words and word pairs are, from the bundled word lists in Dictionary/
/// (SymSpell frequency dictionaries, MIT; counts from Google Books Ngram, CC BY 3.0).
/// Used to pick "anything" over "scything", and "I think" over "I thin".
final class WordModel {
    static let shared = WordModel()

    /// log10 of how often each word appears ("the" ≈ 10.4, "newt" ≈ 6.0)
    private var words: [String: Float] = [:]
    /// log10 of how often each word pair appears, keyed by a 64-bit hash of "first second"
    /// (numbers instead of 243k strings keeps memory small for a menu bar app)
    private var pairs: [UInt64: Float] = [:]
    private(set) var isLoaded = false

    /// Contractions aren't in the lists; treat them as very common words
    static let contractions: Set<String> = [
        "don't", "doesn't", "didn't", "can't", "won't", "isn't", "aren't", "wasn't", "weren't",
        "haven't", "hasn't", "hadn't", "couldn't", "wouldn't", "shouldn't", "mustn't", "needn't",
        "it's", "i'm", "i've", "i'll", "i'd", "you're", "you've", "you'll", "you'd",
        "we're", "we've", "we'll", "we'd", "they're", "they've", "they'll", "they'd",
        "he's", "she's", "he'll", "she'll", "he'd", "she'd", "that's", "there's", "here's",
        "what's", "who's", "where's", "how's", "let's", "y'all", "ain't"
    ]
    /// Contractions typed without the apostrophe, only where that isn't also a real word
    /// ("dont" -> "don't", but not "wont", "cant", "its", "well", "were", "ill")
    static let bareContractions: [String: String] = [
        "dont": "don't", "doesnt": "doesn't", "didnt": "didn't", "isnt": "isn't", "arent": "aren't",
        "wasnt": "wasn't", "werent": "weren't", "havent": "haven't", "hasnt": "hasn't", "hadnt": "hadn't",
        "couldnt": "couldn't", "wouldnt": "wouldn't", "shouldnt": "shouldn't", "im": "I'm", "ive": "I've",
        "youre": "you're", "theyre": "they're", "thats": "that's", "whats": "what's", "theres": "there's"
    ]

    init(directory: URL? = WordModel.locate()) {
        guard let dir = directory else { return }
        Self.read(dir.appendingPathComponent("words.txt")) { key, value in words[key] = value }
        pairs.reserveCapacity(250_000)
        Self.read(dir.appendingPathComponent("bigrams.txt")) { key, value in pairs[Self.hash(key)] = value }
        for c in Self.contractions { words[c] = 8.5 }   // the list gives them a token count; they're very common
        isLoaded = !words.isEmpty
    }

    /// Dictionary/ inside the app bundle, or TYP0S_DICTIONARY for tests run outside the app
    static func locate() -> URL? {
        if let path = ProcessInfo.processInfo.environment["TYP0S_DICTIONARY"] { return URL(fileURLWithPath: path) }
        return Bundle.main.resourceURL?.appendingPathComponent("Dictionary")
    }

    /// Each line is "text count" (the text may contain one space for pairs)
    private static func read(_ url: URL, _ store: (String, Float) -> Void) {
        guard let data = try? Data(contentsOf: url) else { return }
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let space = line.lastIndex(of: " "), let count = Double(line[line.index(after: space)...]) else { continue }
            var key = String(line[..<space]).lowercased()
            if key.hasPrefix("\u{FEFF}") { key.removeFirst() }
            store(key, Float(log10(max(count, 1))))
        }
    }

    /// FNV-1a: a fast, stable 64-bit hash (collisions among 243k pairs are vanishingly unlikely)
    private static func hash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }

    func contains(_ word: String) -> Bool { words[word] != nil }

    /// A US/UK spelling of a listed word ("analyze" for "analyse", "favorite" for "favourite"):
    /// the lists lean one way, so the other spelling is a correct word too, not a typo
    func containsSpellingVariant(_ word: String) -> Bool {
        guard word.count >= 6 else { return false }
        let pairs = [("ize", "ise"), ("ise", "ize"), ("yze", "yse"), ("yse", "yze")]
        for (a, b) in pairs where word.contains(a) {
            if contains(word.replacingOccurrences(of: a, with: b)) { return true }
        }
        let c = Array(word)
        for i in 3..<(c.count - 1) where c[i] == "o" && c[i + 1] == "r" {   // or -> our
            var v = c; v.insert("u", at: i + 1)
            if contains(String(v)) { return true }
        }
        if c.count >= 7 {
            for i in 3..<(c.count - 2) where c[i] == "o" && c[i + 1] == "u" && c[i + 2] == "r" {   // our -> or
                var v = c; v.remove(at: i + 1)
                if contains(String(v)) { return true }
            }
        }
        return false
    }

    /// log10 frequency, or nil for words not in the list
    func logFrequency(_ word: String) -> Float? { words[word] }

    /// log10 count of a word pair, or nil if the pair isn't in the list
    func pairLog(_ first: String, _ second: String) -> Float? { pairs[Self.hash(first + " " + second)] }

    /// How strongly two words go together (0 when the pair is unknown or rare)
    func pairStrength(_ first: String, _ second: String) -> Float {
        guard let f = pairs[Self.hash(first + " " + second)] else { return 0 }
        return min(3, max(0, f - 4))   // capped: context breaks ties, it doesn't override the typed letters
    }
}
