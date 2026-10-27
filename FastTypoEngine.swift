import Cocoa
import Carbon

// MARK: - Persistent Custom Dictionary & Replacement Rules (Wispr Flow Style Learning)
struct CustomRule: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var typo: String        // Optional trigger/typo (e.g., "ainlp", "maijkng") - if empty, acts as protected Vocabulary word
    var replacement: String // Target word/phrase (e.g., "AI/NLP", "making", "NuPhy")
    var learned: Bool = false // Added automatically from repeated use (shown with a "learned" tag)
}

extension CustomRule {
    // Older saved rules have no "learned" key; decode them as manual rules instead of failing
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        typo = try c.decode(String.self, forKey: .typo)
        replacement = try c.decode(String.self, forKey: .replacement)
        learned = try c.decodeIfPresent(Bool.self, forKey: .learned) ?? false
    }
}

class UserDictionaryStore: ObservableObject {
    static let shared = UserDictionaryStore()
    
    @Published var customRules: [CustomRule] = [] {
        didSet { save() }
    }
    
    private let storageKey = "typ0s_CustomRules_v1"
    private let legacyStorageKey = "TypoFlow_CustomRules_v1"   // pre-rename name; read once so saved words carry over
    
    init() {
        load()
    }
    
    func addRule(typo: String, replacement: String) {
        let cleanTypo = typo.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanRep = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanRep.isEmpty else { return }
        customRules.insert(CustomRule(typo: cleanTypo, replacement: cleanRep), at: 0)
    }
    
    func removeRule(id: UUID) {
        if let rule = customRules.first(where: { $0.id == id }), rule.learned {
            // Deleting something learned means "don't learn it again"
            if rule.typo.isEmpty {
                countsLock.lock()
                unknownCounts[rule.replacement.lowercased()] = Int.min
                UserDefaults.standard.set(unknownCounts, forKey: countsKey)
                countsLock.unlock()
            } else {
                typoCounts[rule.typo + "\u{1F}" + rule.replacement] = Int.min
                UserDefaults.standard.set(typoCounts, forKey: typoCountsKey)
            }
        }
        customRules.removeAll { $0.id == id }
    }

    // MARK: Auto-learning of repeated unknown words (names, slang, jargon)
    static let learnThreshold = 3
    private let countsKey = "Typos_UnknownWordCounts_v1"
    private lazy var unknownCounts: [String: Int] =
        UserDefaults.standard.dictionary(forKey: countsKey) as? [String: Int] ?? [:]
    private let countsLock = NSLock()
    private var lastSeen: [String: Date] = [:]

    /// Counts one sighting of a word the engine doesn't know. Returns true once it reaches the
    /// threshold and gets protected. Safe to call off the main thread (the clipboard fallback does).
    func noteUnknownWord(_ word: String) -> Bool {
        let key = word.lowercased()
        guard key.count >= 3, key.allSatisfy({ $0.isLetter }) else { return false }
        countsLock.lock()
        // Re-fixing the same text field shouldn't count the same word again: one sighting per minute
        let now = Date()
        if let last = lastSeen[key], now.timeIntervalSince(last) < 60 {
            let count = unknownCounts[key] ?? 0
            countsLock.unlock()
            return count >= UserDictionaryStore.learnThreshold
        }
        lastSeen[key] = now
        let count = (unknownCounts[key] ?? 0) &+ 1
        unknownCounts[key] = count
        UserDefaults.standard.set(unknownCounts, forKey: countsKey)
        countsLock.unlock()
        guard count == UserDictionaryStore.learnThreshold else { return count > UserDictionaryStore.learnThreshold }
        DispatchQueue.main.async {
            guard !self.customRules.contains(where: { $0.replacement.lowercased() == key }) else { return }
            self.customRules.insert(CustomRule(typo: "", replacement: word, learned: true), at: 0)
        }
        return true
    }
    
    // MARK: Learning your repeated typos (typo -> fix), with undo as the "that was wrong" signal
    static let typoLearnThreshold = 2      // seen twice (same paragraph or across fixes) = a habit
    static let undoWindow: TimeInterval = 8
    private let typoCountsKey = "Typos_TypoFixCounts_v1"
    private lazy var typoCounts: [String: Int] =
        UserDefaults.standard.dictionary(forKey: typoCountsKey) as? [String: Int] ?? [:]
    private var pendingFixes: [(typo: String, fix: String)] = []
    private var pendingCommit: DispatchWorkItem?
    
    /// Called after a real fix. The pairs only count if you don't press ⌘Z within the undo window.
    func notePendingFixes(_ pairs: [(typo: String, fix: String)]) {
        DispatchQueue.main.async {
            self.pendingFixes += pairs
            self.pendingCommit?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.commitPendingFixes() }
            self.pendingCommit = work
            DispatchQueue.main.asyncAfter(deadline: .now() + UserDictionaryStore.undoWindow, execute: work)
        }
    }
    
    /// ⌘Z right after a fix: the fix was unwanted, so learn nothing from it
    func cancelPendingFixes() {
        DispatchQueue.main.async {
            self.pendingCommit?.cancel()
            self.pendingCommit = nil
            self.pendingFixes = []
        }
    }
    
    private func commitPendingFixes() {
        for (typo, fix) in pendingFixes {
            let key = typo + "\u{1F}" + fix
            let count = (typoCounts[key] ?? 0) + 1
            typoCounts[key] = count
            let known = customRules.contains { $0.typo == typo }
            if count >= UserDictionaryStore.typoLearnThreshold && !known {
                customRules.insert(CustomRule(typo: typo, replacement: fix, learned: true), at: 0)
            }
        }
        UserDefaults.standard.set(typoCounts, forKey: typoCountsKey)
        pendingFixes = []
        pendingCommit = nil
    }
    
    private func save() {
        if let data = try? JSONEncoder().encode(customRules) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
    
    private func load() {
        let defaults = UserDefaults.standard
        if defaults.data(forKey: storageKey) == nil, let old = defaults.data(forKey: legacyStorageKey) {
            defaults.set(old, forKey: storageKey)
            defaults.removeObject(forKey: legacyStorageKey)
        }
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([CustomRule].self, from: data) {
            customRules = decoded
        }
    }
}

// MARK: - Wrong keyboard layout (e.g. typing English while Thai was accidentally switched on)
/// Maps each character of your other installed keyboard layouts back to the ABC/English character
/// on the same physical key, using the layout data macOS itself uses (UCKeyTranslate).
enum WrongLayoutFixer {
    /// foreign code point -> English character on the same key (with the same Shift state).
    /// Code points, not Characters: Thai vowels and tone marks merge with consonants into one Character.
    static let map: [Unicode.Scalar: Character] = build()

    private static func build() -> [Unicode.Scalar: Character] {
        guard let english = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let englishKeys = keyTable(english) else { return [:] }
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
                      kTISPropertyInputSourceIsSelectCapable as String: true] as CFDictionary
        guard let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else { return [:] }
        var result: [Unicode.Scalar: Character] = [:]
        for source in sources where !isASCIICapable(source) {
            guard let keys = keyTable(source) else { continue }   // input methods (e.g. Pinyin) have no fixed key table
            for (slot, foreign) in keys {
                guard let en = englishKeys[slot].flatMap({ Character($0) }),
                      !foreign.isASCII, result[foreign] == nil else { continue }
                result[foreign] = en
            }
        }
        return result
    }

    private static func isASCIICapable(_ source: TISInputSource) -> Bool {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(ptr).takeUnretainedValue())
    }

    /// (keyCode * 2 + shift) -> code point produced by that key in this layout
    private static func keyTable(_ source: TISInputSource) -> [Int: Unicode.Scalar]? {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var table: [Int: Unicode.Scalar] = [:]
        data.withUnsafeBytes { raw in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            for keyCode in 0..<51 where keyCode != 49 {   // letter, number and punctuation keys (not space)
                for shift in [false, true] {
                    var dead: UInt32 = 0
                    var length = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    let mods: UInt32 = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
                    let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDown), mods,
                                                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                                &dead, chars.count, &length, &chars)
                    if status == noErr, length == 1, let c = Unicode.Scalar(chars[0]) {
                        table[keyCode * 2 + (shift ? 1 : 0)] = c
                    }
                }
            }
        }
        return table.isEmpty ? nil : table
    }

    /// True when most of the token was typed in another layout
    static func looksForeign(_ token: String) -> Bool {
        let scalars = token.unicodeScalars
        let hits = scalars.filter { map[$0] != nil }.count
        return hits > 0 && hits * 2 >= scalars.count
    }

    static func toEnglish(_ token: String) -> String {
        var out = ""
        for u in token.unicodeScalars {
            if let en = map[u] { out.append(en) } else { out.unicodeScalars.append(u) }
        }
        return out
    }
}

// MARK: - Tuning
/// Every number the engine uses to judge a typo, in one place. tools/train.swift searches these
/// against real typo data; the defaults below are the best values it found.
struct TypoTuning {
    // Keyboard slip costs (lower = more likely typo)
    var neighborKey = 0.48        // hit the key next to the right one
    var farKeyScale = 0.6         // a far-away key costs distance × this…
    var farKeyMax = 1.45          // …up to this
    var bledKey = 0.46            // extra key that sits next to a neighbouring letter ("nbest")
    var extraKey = 0.67           // any other extra key
    var missedKey = 0.51          // a key that didn't register
    var swappedKeys = 0.32        // two keys in the wrong order
    var swapAcrossBleed = 0.65    // swapped with a bled key in between ("ijk")
    var lastKeyNotReached = 0.5   // stopped one key short ("whe" -> "when")
    // Choosing between candidate words
    var frequencyWeight = 0.3     // prefer common words
    var contextWeight = 0.1      // prefer words that fit their neighbours
    var deeperSearchAbove = 0.7   // look further when the best match costs more than this
    var deepSearchAbove = 1.2     // search three slips deep when the best match still costs more than this…
    var deepSearchMinLength = 6   // …and the word has at least this many letters
    // When to leave a word alone
    var limitShort = 1.0          // max cost for words of 1-3 letters
    var limitMid = 1.6            // 4-5 letters
    var limitLong = 2.2           // 6+ letters
    var tieCost = 1.0             // a match costing more than this…
    var tieMargin = 0.14           // …must beat the runner-up by this much
    var spellcheckerSlip = 0.5    // words macOS knows but our list doesn't: only fix slips cheaper than this
    // Real word typed as another real word ("form" -> "from"): swap only on overwhelming context
    var realWordMargin: Float = .infinity   // how much better (log10) the other word must fit; infinity = off
    var realWordSlipPenalty: Float = 0.7    // subtract slip cost × this from the other word's fit
}

// MARK: - Typo engine: keyboard-aware edit distance + word frequency + word-pair context
class FastTypoEngine {
    static var tuning = TypoTuning()
    /// Light grammar and accidental punctuation fixes (settings: "Light grammar")
    static var grammarEnabled = true

    private let spellChecker = NSSpellChecker.shared
    // True only for real fixes in other apps (not the Test tab), so practice text never teaches typos
    private var learning = false
    // Scores at or below this are near-certain typos and are never learned as words
    private let confidentTypoScore = 1.0
    // Confident typo -> fix pairs found in the current learning pass (lowercased)
    private var confidentFixes: [String: String] = [:]
    // The text being fixed uses curly apostrophes (Freewrite, Notes): keep them curly in our output
    private var preferCurly = false
    
    init() {
        _ = WrongLayoutFixer.map   // read the keyboard layouts once, on the thread that creates the engine (main)
    }
    
    // Physical QWERTY 2D coordinates (Row, Column) with NuPhy Air75 stagger
    private let qwertyCoords: [Character: (Double, Double)] = [
        "q": (0, 0.0), "w": (0, 1.0), "e": (0, 2.0), "r": (0, 3.0), "t": (0, 4.0),
        "y": (0, 5.0), "u": (0, 6.0), "i": (0, 7.0), "o": (0, 8.0), "p": (0, 9.0),
        "[": (0, 10.0), "]": (0, 11.0), "\\": (0, 12.0),
        "a": (1, 0.25), "s": (1, 1.25), "d": (1, 2.25), "f": (1, 3.25), "g": (1, 4.25),
        "h": (1, 5.25), "j": (1, 6.25), "k": (1, 7.25), "l": (1, 8.25), ";": (1, 9.25), "'": (1, 10.25),
        "z": (2, 0.75), "x": (2, 1.75), "c": (2, 2.75), "v": (2, 3.75), "b": (2, 4.75),
        "n": (2, 5.75), "m": (2, 6.75), ",": (2, 7.75), ".": (2, 8.75), "/": (2, 9.75)
    ]
    
    private let baseWhitelist: Set<String> = [
        "wyt", "idk", "tbh", "imo", "imho", "rn", "irl", "afaik", "ngl", "fr", "btw", "omg", "lol", "lmao", "nuphy", "tauri", "symspell", "wispr", "ai", "nlp", "ux", "ui", "llm"
    ]
    
    // Common English misspellings everyone makes. Your own habits are learned into the dictionary instead.
    private let instantFixes: [String: String] = [
        "teh": "the", "hte": "the", "thsi": "this", "tihs": "this", "adn": "and", "nad": "and",
        "taht": "that", "thta": "that", "waht": "what", "hwat": "what", "wiht": "with", "whit": "with",
        "jsut": "just", "jstu": "just", "fomr": "from", "hvae": "have", "ahve": "have",
        "knwo": "know", "nkow": "know", "abuot": "about", "abotu": "about",
        "woudl": "would", "shoudl": "should", "coudl": "could", "wich": "which",
        "becuase": "because", "beacuse": "because", "definately": "definitely", "recieve": "receive",
        "seperate": "separate", "occured": "occurred", "untill": "until", "runing": "running",
        "espically": "especially", "somoene": "someone", "autometically": "automatically",
        "dont": "don't", "doesnt": "doesn't", "didnt": "didn't", "im": "I'm", "ive": "I've",
        "foward": "forward", "fowards": "forwards", "alot": "a lot"
    ]
    
    // Deduplicate adjacent identical or neighbor-bleed letters to generate strong phonetic/motor stems
    // e.g. "maijkng" -> strips neighbor 'j' next to 'i'/'k' -> "maikng" -> "making"
    private func generateMotorSkeletons(_ word: String) -> [String] {
        var results: [String] = []
        let chars = Array(word.lowercased())
        guard chars.count >= 3 else { return results }
        
        // Try removing each single internal character that is physically adjacent on QWERTY to its left or right neighbor!
        for i in 0..<chars.count {
            let prevAdj = (i > 0) && (qwertyKeyDistance(chars[i], chars[i - 1]) <= 0.55)
            let nextAdj = (i + 1 < chars.count) && (qwertyKeyDistance(chars[i], chars[i + 1]) <= 0.55)
            if prevAdj || nextAdj {
                var copy = chars
                copy.remove(at: i)
                results.append(String(copy))
            }
        }
        return results
    }
    
    func isValidWord(_ word: String) -> Bool {
        if word.isEmpty { return true }
        let lower = word.lowercased().replacingOccurrences(of: "’", with: "'")
        if baseWhitelist.contains(lower) { return true }
        for rule in UserDictionaryStore.shared.customRules where rule.replacement.lowercased() == lower { return true }
        if lower.count == 1 { return lower == "a" || lower == "i" }
        let model = WordModel.shared
        if model.isLoaded { return model.contains(lower) || model.containsSpellingVariant(lower) }
        return spellCheckerKnows(word)   // fallback if the word lists are missing
    }

    private func spellCheckerKnows(_ word: String) -> Bool {
        spellChecker.checkSpelling(of: word, startingAt: 0).location == NSNotFound
    }

    // MARK: Candidates

    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz")

    /// Every string one keystroke mistake away: a key dropped, two keys swapped, a wrong key, an extra key
    private func edits1(_ w: [Character]) -> [String] {
        var out: [String] = []
        let n = w.count
        out.reserveCapacity(54 * n + 26)
        for i in 0..<n { var c = w; c.remove(at: i); out.append(String(c)) }
        if n > 1 { for i in 0..<(n - 1) where w[i] != w[i + 1] { var c = w; c.swapAt(i, i + 1); out.append(String(c)) } }
        for i in 0..<n { for a in Self.alphabet where a != w[i] { var c = w; c[i] = a; out.append(String(c)) } }
        for i in 0...n { for a in Self.alphabet { var c = w; c.insert(a, at: i); out.append(String(c)) } }
        return out
    }

    private func isCandidateWord(_ s: String) -> Bool {
        s.count > 1 ? (WordModel.shared.contains(s) || WordModel.bareContractions[s] != nil) : (s == "a" || s == "i")
    }

    /// Real words within reach: one mistake, or two where one of them is an extra or swapped key
    private func candidates(for word: String) -> Set<String> {
        let w = Array(word)
        var found = Set<String>()
        for e in edits1(w) where isCandidateWord(e) { found.insert(e) }
        guard w.count >= 3 else { return found }
        var firstSteps = Set<String>()
        for i in 0..<w.count { var c = w; c.remove(at: i); firstSteps.insert(String(c)) }
        for i in 0..<(w.count - 1) where w[i] != w[i + 1] { var c = w; c.swapAt(i, i + 1); firstSteps.insert(String(c)) }
        for step in firstSteps { for e in edits1(Array(step)) where isCandidateWord(e) { found.insert(e) } }
        return found
    }

    /// Dropped or swapped keys: the cheap first steps of a slip search
    private func dropsAndSwaps(_ word: String) -> Set<String> {
        let w = Array(word)
        var out = Set<String>()
        for i in 0..<w.count { var c = w; c.remove(at: i); out.insert(String(c)) }
        if w.count > 1 { for i in 0..<(w.count - 1) where w[i] != w[i + 1] { var c = w; c.swapAt(i, i + 1); out.insert(String(c)) } }
        return out
    }

    /// Three slips deep, for long messy words ("snythinig", "probsbiligy"): two drops/swaps, then any one edit.
    /// Slow (tens of thousands of lookups), so only used when nothing within two slips fits.
    private func candidates3(for word: String) -> Set<String> {
        var found = Set<String>()
        var seen = Set<String>()
        for first in dropsAndSwaps(word) {
            for second in dropsAndSwaps(first) where seen.insert(second).inserted {
                for e in edits1(Array(second)) where isCandidateWord(e) { found.insert(e) }
            }
        }
        return found
    }

    /// The most likely intended word: cheap keyboard mistakes, a common word, and one that fits its neighbours
    /// The best candidate for a misspelled word, plus the facts the learned fix gate looks at
    struct Candidate {
        var word: String
        var cost: Double          // keyboard slip cost from what was typed
        var score: Double         // cost minus frequency and context bonuses (lower is better)
        var runnerUpGap: Double   // how far ahead of the second-best word it is
        var poolSize: Int         // how many real words were within reach
    }

    private func bestCandidate(for word: String, prev: String?, next: String?) -> Candidate? {
        var pool = candidates(for: word)
        let first = rank(pool, for: word, prev: prev, next: next)
        if let f = first, f.cost <= Self.tuning.deeperSearchAbove { return f }
        // Nothing very close: also try with one bled-in key removed first ("trhkn" -> "thkn" -> "think")
        if word.count <= 9 {
            for skeleton in generateMotorSkeletons(word) { pool.formUnion(candidates(for: skeleton)) }
        }
        let second = rank(pool, for: word, prev: prev, next: next)
        // Still nothing good for a long word: search three slips deep
        guard word.count >= Self.tuning.deepSearchMinLength, (second?.cost ?? .infinity) > Self.tuning.deepSearchAbove else { return second }
        pool.formUnion(candidates3(for: word))
        return rank(pool, for: word, prev: prev, next: next)
    }

    private func rank(_ pool: Set<String>, for word: String, prev: String?, next: String?) -> Candidate? {
        guard !pool.isEmpty else { return nil }
        let model = WordModel.shared
        let t = Self.tuning
        var best: Candidate?
        var runnerUp = Double.infinity
        for c in pool.sorted() {   // sorted: the same answer every run (Set order is random)
            let target = WordModel.bareContractions[c] ?? c
            let key = target.lowercased()
            var cost = weightedEditDistance(from: word, to: c)
            if c.count == word.count + 1 && c.hasPrefix(word) { cost = min(cost, t.lastKeyNotReached) }   // "whe" -> "when"
            var score: Double
            if RankModel.isTrained {
                score = -RankModel.score(rankFeatures(word, c, key: key, cost: cost, prev: prev, next: next))   // lower is better
            } else {
                score = cost - t.frequencyWeight * Double(model.logFrequency(key) ?? 5)
                if let p = prev { score -= t.contextWeight * Double(model.pairStrength(p, key)) }
                if let n = next { score -= t.contextWeight * Double(model.pairStrength(key, n)) }
            }
            if best == nil || score < best!.score {
                if let b = best { runnerUp = b.score }
                best = Candidate(word: target, cost: cost, score: score, runnerUpGap: 0, poolSize: pool.count)
            } else if score < runnerUp {
                runnerUp = score
            }
        }
        guard var b = best else { return nil }
        b.runnerUpGap = runnerUp.isFinite ? runnerUp - b.score : 3
        return b
    }

    /// The 9 facts the learned ranker weighs for candidate `c` (spelled as found, `key` = the word it stands for)
    func rankFeatures(_ word: String, _ c: String, key: String, cost: Double, prev: String?, next: String?) -> [Double] {
        let m = WordModel.shared
        return [
            cost,
            Double(m.logFrequency(key) ?? 5),
            Double(prev.map { m.pairStrength($0, key) } ?? 0),
            Double(next.map { m.pairStrength(key, $0) } ?? 0),
            Double(abs(c.count - word.count)),
            c.first == word.first ? 1 : 0,
            c.last == word.last ? 1 : 0,
            c.count == word.count + 1 && c.hasPrefix(word) ? 1 : 0,
            WordModel.contractions.contains(key) ? 1 : 0,
            prev.map { pairAssociation($0, key) } ?? 0,
            next.map { pairAssociation(key, $0) } ?? 0,
            prev.map { m.pairLog($0, key) == nil ? 1 : 0 } ?? 0,
            next.map { m.pairLog(key, $0) == nil ? 1 : 0 } ?? 0,
        ]
    }

    /// How much more often two words appear together than chance would give (log10 scale, 0 if the pair is unknown).
    /// Unlike pairStrength it doesn't reward common words just for being common.
    func pairAssociation(_ a: String, _ b: String) -> Double {
        let m = WordModel.shared
        guard let pair = m.pairLog(a, b), let fa = m.logFrequency(a), let fb = m.logFrequency(b) else { return 0 }
        return Double(min(4, max(-2, pair - fa - fb + 12)))
    }

    /// For training the ranker: every candidate within reach of a typed word, with its facts
    func rankExample(_ typed: String, gold: String, prev: String?, next: String?) -> (keys: [String], features: [[Double]])? {
        let word = typed.lowercased()
        var pool = candidates(for: word)
        if word.count <= 9 { for skeleton in generateMotorSkeletons(word) { pool.formUnion(candidates(for: skeleton)) } }
        func has(_ p: Set<String>) -> Bool { p.contains { (WordModel.bareContractions[$0] ?? $0).lowercased() == gold } }
        if !has(pool) && word.count >= Self.tuning.deepSearchMinLength { pool.formUnion(candidates3(for: word)) }
        guard pool.count >= 2, has(pool) else { return nil }
        var keys: [String] = [], feats: [[Double]] = []
        for c in pool.sorted() {   // sorted: the same answer every run (Set order is random)
            let key = (WordModel.bareContractions[c] ?? c).lowercased()
            var cost = weightedEditDistance(from: word, to: c)
            if c.count == word.count + 1 && c.hasPrefix(word) { cost = min(cost, Self.tuning.lastKeyNotReached) }
            keys.append(key); feats.append(rankFeatures(word, c, key: key, cost: cost, prev: prev, next: next))
        }
        return (keys, feats)
    }

    /// Hand-written rule (used until the fix gate is trained): a weak match nearly tied with another word is a guess
    private func isGuess(_ c: Candidate) -> Bool {
        c.cost > Self.tuning.tieCost && c.runnerUpGap < Self.tuning.tieMargin
    }

    /// The 12 facts the learned fix gate weighs, for fixing `word` (as typed) to candidate `c`
    func gateFeatures(_ word: String, _ c: Candidate, prev: String?, next: String?, original: String) -> [Double] {
        let m = WordModel.shared
        let key = c.word.lowercased()
        let length = Double(max(1, word.count))
        return [
            c.cost,
            c.cost / length,
            min(3, c.runnerUpGap),
            Double(m.logFrequency(key) ?? 5),
            Double(prev.map { m.pairStrength($0, key) } ?? 0),
            Double(next.map { m.pairStrength(key, $0) } ?? 0),
            length,
            log2(Double(c.poolSize) + 1),
            spellCheckerKnows(original) ? 1 : 0,
            original.first?.isUppercase == true ? 1 : 0,
            WordModel.contractions.contains(key) ? 1 : 0,
            inflectedStemFrequency(word),
        ]
    }

    /// If the typed word looks like a known word plus a common ending ("colors", "app's", "bundled"),
    /// how common that stem is (0 if not). Such words are often correct, just missing from the list.
    func inflectedStemFrequency(_ word: String) -> Double {
        let m = WordModel.shared
        var best: Float = 0
        for suffix in ["'s", "s'", "s", "es", "ed", "d", "ing", "er", "ers", "ly", "ness", "ment"] where word.hasSuffix(suffix) {
            let stem = String(word.dropLast(suffix.count))
            guard stem.count >= 3 else { continue }
            for s in [stem, stem + "e"] { if let f = m.logFrequency(s), f > best { best = f } }
        }
        return Double(best)
    }

    /// For training: the best candidate for a typed word and the gate's facts about it (nil if no candidate)
    func gateExample(_ typed: String, prev: String?, next: String?) -> (candidate: String, features: [Double])? {
        let word = typed.lowercased()
        guard let c = bestCandidate(for: word, prev: prev, next: next) else { return nil }
        return (c.word.lowercased(), gateFeatures(word, c, prev: prev, next: next, original: typed))
    }

    /// For training/diagnostics: why a misspelled word did or didn't become `target`
    func diagnose(_ word: String, target: String, prev: String?, next: String?) -> String {
        let w = word.lowercased()
        var pool = candidates(for: w)
        let reach1 = pool.contains(target) || WordModel.bareContractions.first(where: { $0.value == target })
            .map { pool.contains($0.key) } == true
        if !reach1 { for s in generateMotorSkeletons(w) { pool.formUnion(candidates(for: s)) } }
        if !pool.contains(target) { return "unreachable" }
        guard let best = bestCandidate(for: w, prev: prev, next: next), !isGuess(best) else { return "abstained (tie)" }
        if best.word.lowercased() != target { return "chose wrong word" }
        if best.cost > costLimit(w.count) { return "over cost limit" }
        return "ok"
    }

    /// How many keystroke mistakes we accept for a word of this length
    private func costLimit(_ length: Int) -> Double {
        let t = Self.tuning
        return length <= 3 ? t.limitShort : (length <= 5 ? t.limitMid : t.limitLong)
    }

    func qwertyKeyDistance(_ c1: Character, _ c2: Character) -> Double {
        if c1 == c2 { return 0.0 }
        guard let p1 = qwertyCoords[c1], let p2 = qwertyCoords[c2] else {
            return 1.4
        }
        let dx = p1.0 - p2.0
        let dy = p1.1 - p2.1
        let dist = sqrt(dx * dx + dy * dy)
        let t = Self.tuning
        return dist <= 1.35 ? t.neighborKey : min(dist * t.farKeyScale, t.farKeyMax)
    }
    
    func weightedEditDistance(from source: String, to target: String) -> Double {
        let s = Array(source.lowercased())
        let t = Array(target.lowercased())
        let m = s.count
        let n = t.count
        if m == 0 { return Double(n) }
        if n == 0 { return Double(m) }
        
        // Removing a typed key is cheap when it sits next to a neighbouring key (it bled in while typing)
        func delCost(_ i: Int) -> Double {
            if (i > 1 && qwertyKeyDistance(s[i - 1], s[i - 2]) <= 0.55) ||
               (i < m && qwertyKeyDistance(s[i - 1], s[i]) <= 0.55) {
                return Self.tuning.bledKey // Adjacent key-bleed (like 'n' in 'nlife', 'w' in 'tewrm', 'y' in 'uyse')
            }
            return Self.tuning.extraKey
        }
        var dp = Array(repeating: Array(repeating: 0.0, count: n + 1), count: m + 1)
        for i in 1...m { dp[i][0] = dp[i - 1][0] + delCost(i) }   // leading bleed ("nbewt") is as cheap as anywhere else
        let missed = Self.tuning.missedKey
        for j in 1...n { dp[0][j] = Double(j) * missed }

        for i in 1...m {
            for j in 1...n {
                let subCost = qwertyKeyDistance(s[i - 1], t[j - 1])
                let delCost = delCost(i)
                
                dp[i][j] = min(
                    dp[i - 1][j] + delCost,
                    dp[i][j - 1] + missed,   // a key that didn't register (very common when typing fast)
                    dp[i - 1][j - 1] + subCost
                )
                
                // Transposition (e.g. 'ik' -> 'ki' in 'maijkng' -> 'making', 'el' -> 'le' in 'uselful')
                if i > 1 && j > 1 && s[i - 1] == t[j - 2] && s[i - 2] == t[j - 1] {
                    dp[i][j] = min(dp[i][j], dp[i - 2][j - 2] + Self.tuning.swappedKeys)
                }
                // Transposition across 1 neighbor bleed char (e.g. 'ijk' where 'j' bled between 'i' and 'k'!)
                if i > 2 && j > 1 && s[i - 1] == t[j - 2] && s[i - 3] == t[j - 1] {
                    dp[i][j] = min(dp[i][j], dp[i - 3][j - 2] + Self.tuning.swapAcrossBleed)
                }
            }
        }
        return dp[m][n]
    }
    
    func fixSingleWord(_ rawWord: String, prev: String? = nil, next: String? = nil, sentenceStart: Bool = true) -> String {
        // Numbers, versions, times ("5", "v2", "10am") are never typos to fix
        if rawWord.contains(where: { $0.isNumber }) { return rawWord }
        // URLs, emails, file names, code
        if rawWord.contains(where: { "./@:_#".contains($0) }) { return rawWord }
        // Other scripts (Thai, Chinese, ...) are real writing, not English typos
        if rawWord.unicodeScalars.contains(where: { $0.value > 0x024F && CharacterSet.letters.contains($0) }) { return rawWord }

        let curly = rawWord.contains("’") || preferCurly
        let normalized = rawWord.replacingOccurrences(of: "’", with: "'")
        let lower = normalized.lowercased()
        func result(_ w: String) -> String {
            let cased = preserveCase(original: rawWord, corrected: w)
            return curly ? cased.replacingOccurrences(of: "'", with: "’") : cased
        }

        // 1. Your own rules and protected words
        for rule in UserDictionaryStore.shared.customRules {
            if !rule.typo.isEmpty && rule.typo == lower {
                let plain = rule.replacement == rule.replacement.lowercased()
                return plain ? result(rule.replacement) : rule.replacement
            }
            if rule.replacement.lowercased() == lower {
                return rule.replacement // Preserve exact user casing (e.g. "NuPhy", "AI/NLP")
            }
        }

        if baseWhitelist.contains(lower) {
            if lower == "ai" || lower == "nlp" || lower == "ui" || lower == "ux" { return rawWord.uppercased() }
            return rawWord
        }

        // 2. Well-known misspellings
        if let direct = instantFixes[lower] { return result(direct) }

        // 3. Hyphenated words: fix each part (and "AI-NLP" -> "AI/NLP")
        if rawWord.contains("-") {
            let parts = rawWord.components(separatedBy: "-")
            if parts.count == 2 && parts[0].count <= 4 && parts[1].count <= 4 &&
               parts[0].uppercased() == parts[0] && parts[1].uppercased() == parts[1] &&
               parts.allSatisfy({ $0.count >= 2 && $0.allSatisfy { $0.isLetter } }) {
                return "\(parts[0])/\(parts[1])"
            }
            return parts.map { fixSingleWord($0, sentenceStart: sentenceStart) }.joined(separator: "-")
        }

        // 4. Letters only: keys that bled in from punctuation ("m,oving", "kep[e") are dropped
        let letters = normalized.filter { $0.isLetter || $0 == "'" }
        let word = letters.lowercased()
        if word.isEmpty { return rawWord }
        if isValidWord(word) { return letters == normalized ? rawWord : result(letters) }
        if let contraction = WordModel.bareContractions[word] { return result(contraction) }   // "dont" -> "don't"

        // A capitalised unknown word mid-sentence is probably a name: leave it
        if !sentenceStart, let first = rawWord.first, first.isUppercase { return rawWord }

        guard let best = bestCandidate(for: word, prev: prev, next: next) else {
            if learning { _ = UserDictionaryStore.shared.noteUnknownWord(letters) }
            return rawWord
        }
        let safe: Bool
        if FixGate.isTrained {
            // The learned gate: fix only if the chance this fix is right clears the Bold / Careful bar
            let p = FixGate.probability(gateFeatures(word, best, prev: prev, next: next, original: letters))
            safe = p >= FixGate.threshold && best.cost <= 3.0
        } else {
            // Hand-written rules: macOS knows it (rare word, name), a near-tie, or too many slips -> leave it
            let macKnows = WordModel.shared.isLoaded && best.cost > Self.tuning.spellcheckerSlip && spellCheckerKnows(letters)
            safe = !macKnows && !isGuess(best) && best.cost <= costLimit(word.count)
        }
        // A weak match is probably a word we don't know (slang, a name): count it, stop "fixing" it once seen enough
        if (!safe || best.cost > confidentTypoScore) && learning && UserDictionaryStore.shared.noteUnknownWord(letters) { return rawWord }
        guard safe else { return rawWord }
        if learning && best.cost <= confidentTypoScore && best.word.lowercased() != lower {
            confidentFixes[lower] = best.word.lowercased()
        }
        return result(best.word)
    }

    // Smart Case Normalization: Fixes accidental caps-bleed ("APplication" -> "Application") while preserving true acronyms ("AI", "NLP")
    func preserveCase(original: String, corrected: String) -> String {
        if original.isEmpty || corrected.isEmpty { return corrected }
        
        // Keep short all-caps acronyms intact
        if original == original.uppercased() && original.count <= 4 {
            return corrected.uppercased()
        }
        
        // Fix accidental multi-cap start like "APplication" -> "Application"
        let origChars = Array(original)
        if origChars.count >= 3 && origChars[0].isUppercase && origChars[1].isUppercase && origChars[2].isLowercase {
            return corrected.prefix(1).uppercased() + corrected.dropFirst().lowercased()
        }
        
        if let firstOrig = original.first, firstOrig.isUppercase {
            // Preserve internal slashes if corrected has them (like "AI/NLP")
            if corrected.contains("/") { return corrected }
            return corrected.prefix(1).uppercased() + corrected.dropFirst()
        }
        return corrected
    }
    
    // A word plus the punctuation stripped from its edges, so splits/joins never lose or misplace it
    struct Token {
        var pre: String
        var core: String
        var suf: String
    }

    // Pieces produced by a split must be real words: 2+ letters, or "a"/"I"
    private func isSolidPiece(_ word: String) -> Bool {
        let lower = word.lowercased()
        if word.count == 1 { return lower == "a" || lower == "i" }
        return isValidWord(lower)
    }

    // Words we already know how to fix on their own (e.g. "adn", "teh") must not be split or joined
    private func hasKnownFix(_ word: String) -> Bool {
        let lower = word.lowercased()
        if instantFixes[lower] != nil { return true }
        return UserDictionaryStore.shared.customRules.contains { !$0.typo.isEmpty && $0.typo == lower }
    }

    // MARK: Light grammar and accidental punctuation

    /// Spaces before punctuation, mixed or doubled marks, and a period before a stray letter
    func tidyPunctuation(_ line: String) -> String {
        var l = line
        let rules: [(String, String)] = [
            (#"(?<=\S)\s+([,.;:!?])(?=\s|$)"#, "$1"),          // "good ." -> "good."  "wait , what" -> "wait, what"
            (#"[,;:]\.(?!\.)"#, "."),                           // "fine,." -> "fine."
            (#",{2,}"#, ","),                                    // ",," -> ","
            (#"(\p{L})\. ([b-hj-z])(?= |$)"#, "$1 $2"),         // "anythin. g and" -> "anythin g and" (then joined)
        ]
        for (pattern, template) in rules {
            l = l.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return l
    }

    /// A short fragment ending in "." followed by a lowercase word that strongly belongs with it
    /// ("I think. the") is a slip. Measured by how much more often the two words go together than chance (PMI).
    private func isAccidentalPeriod(after word: String, next: Token, wordsSoFar: Int) -> Bool {
        let a = word.lowercased(), b = next.core.lowercased()
        guard wordsSoFar <= 3, next.pre.isEmpty, let first = next.core.first, first.isLowercase,
              isValidWord(a), isValidWord(b) else { return false }
        let m = WordModel.shared
        guard let pair = m.pairLog(a, b), let fa = m.logFrequency(a), let fb = m.logFrequency(b) else { return false }
        return pair - fa - fb + 12 >= 1.8
    }

    /// Does this word start with a vowel sound ("an hour", "a university")?
    private func startsWithVowelSound(_ word: String) -> Bool {
        let w = word.lowercased()
        if ["hour", "honest", "honor", "honour", "heir"].contains(where: { w.hasPrefix($0) }) { return true }
        if ["uni", "use", "usu", "ute", "uti", "uro", "one", "once", "eu", "ewe", "ufo", "ubi"].contains(where: { w.hasPrefix($0) }) { return false }
        return w.first.map { "aeiou".contains($0) } ?? false
    }

    /// a/an, doubled words ("the the"), "could of" -> "could have". Only near-certain rules.
    func lightGrammar(_ tokens: [Token]) -> [Token] {
        var out: [Token] = []
        let keepDoubled: Set<String> = ["had", "that", "is", "do", "very", "so", "really", "no", "yes", "ha", "bye", "blah",
                                        "many", "far", "again", "more", "long", "much", "bang", "knock", "well"]
        let notNouns: Set<String> = ["and", "or", "is", "as", "if", "in", "of", "on", "at", "it", "an", "a", "the", "to"]
        for (i, token) in tokens.enumerated() {
            var t = token
            let lower = t.core.lowercased()
            // Doubled word: drop the second copy, keep its punctuation
            if let prev = out.last, prev.suf.isEmpty, t.pre.isEmpty, !lower.isEmpty,
               prev.core.lowercased() == lower, lower.allSatisfy({ $0.isLetter }), !keepDoubled.contains(lower) {
                out[out.count - 1].suf = t.suf
                continue
            }
            // "could of" -> "could have"
            if lower == "of", let prev = out.last, prev.suf.isEmpty,
               ["could", "should", "would", "must", "might"].contains(prev.core.lowercased()) {
                t.core = "have"
            }
            // a / an before the next word's sound
            if (lower == "a" || lower == "an"), t.suf.isEmpty, i + 1 < tokens.count {
                let next = tokens[i + 1]
                let nl = next.core.lowercased()
                // Skip words said letter by letter (no vowel: "rpm", "sql")
                if next.pre.isEmpty, next.core == nl, isValidWord(nl), nl.count > 1, !notNouns.contains(nl),
                   nl.contains(where: { "aeiouy".contains($0) }) {
                    let want = startsWithVowelSound(nl) ? "an" : "a"
                    if lower != want { t.core = t.core.first!.isUppercase ? want.capitalized : want }
                }
            }
            out.append(t)
        }
        return out
    }

    // MARK: Real word typed as another real word

    /// One typing slip apart: a neighbour key, two swapped keys, or a doubled / bled / dropped key.
    /// Word endings (plural, -ed, -al) don't count: that's grammar, not a slip.
    private func isKeyboardSlip(_ x: String, _ y: String) -> Bool {
        if x.hasPrefix(y) || y.hasPrefix(x) { return false }
        let a = Array(x), b = Array(y)
        if a.count == b.count {
            let d = (0..<a.count).filter { a[$0] != b[$0] }
            if d.count == 1 { return qwertyKeyDistance(a[d[0]], b[d[0]]) <= 0.55 }
            if d.count == 2 && d[1] == d[0] + 1 { return a[d[0]] == b[d[1]] && a[d[1]] == b[d[0]] }
            return false
        }
        guard abs(a.count - b.count) == 1 else { return false }
        let (long, short) = a.count > b.count ? (a, b) : (b, a)
        for i in 0..<long.count {
            var rest = long; rest.remove(at: i)
            if rest == short {
                let neighbours = [i - 1, i + 1].filter { $0 >= 0 && $0 < long.count }.map { long[$0] }
                return neighbours.contains { $0 == long[i] || qwertyKeyDistance($0, long[i]) <= 0.55 }
            }
        }
        return false
    }

    /// How well a word fits between its neighbours (log10 pair counts; unseen pairs estimated
    /// from how common each word is on its own, minus a penalty for never being seen together)
    private func fit(_ w: String, prev: String, next: String) -> Float {
        let m = WordModel.shared
        let lw = m.logFrequency(w) ?? 3
        let left = m.pairLog(prev, w) ?? ((m.logFrequency(prev) ?? 3) + lw - 13)
        let right = m.pairLog(w, next) ?? (lw + (m.logFrequency(next) ?? 3) - 13)
        return left + right
    }

    /// "form" -> "from", "beast" -> "best": only when the other word fits its neighbours overwhelmingly better
    private func realWordFix(_ word: String, prev: String?, next: String?) -> String? {
        let t = Self.tuning
        guard t.realWordMargin.isFinite, let p = prev, let n = next,
              (2...10).contains(word.count), word.allSatisfy({ $0.isLetter }) else { return nil }
        let model = WordModel.shared
        let current = fit(word, prev: p, next: n)
        var best: (word: String, fit: Float)?
        for c in Set(edits1(Array(word))) where c != word && model.contains(c) && isKeyboardSlip(word, c) {
            let f = fit(c, prev: p, next: n) - Float(weightedEditDistance(from: word, to: c)) * t.realWordSlipPenalty
            if f > current + t.realWordMargin && (best == nil || f > best!.fit) { best = (c, f) }
        }
        return best?.word
    }

    /// A close real word for a joined fragment ("thnk" -> "think"), or nil
    private func closeFix(_ word: String, prev: String? = nil, next: String? = nil) -> String? {
        let lower = word.lowercased()
        if isValidWord(lower) { return word }
        guard let best = bestCandidate(for: lower, prev: prev, next: next), best.cost <= 1.0, !isGuess(best) else { return nil }
        return best.word
    }

    // Spacebar slips: a stray letter ("thn k", "b est", "anythin g"), a space in the wrong place ("ou tof"),
    // or one word split in two ("th e"). Never touches two real words, numbers, or punctuation between words.
    func fixSplitWords(_ tokens: [Token]) -> [Token] {
        guard tokens.count > 1 else { return tokens }
        var result: [Token] = []
        var i = 0
        let model = WordModel.shared
        // Apostrophes may sit inside either half ("w e'll", "i t's", "you'r e")
        func isApostrophe(_ c: Character) -> Bool { c == "'" || c == "’" }

        while i < tokens.count {
            if i + 1 < tokens.count {
                let t1 = tokens[i]
                let t2 = tokens[i + 1]
                let w1 = t1.core
                let w2 = t2.core
                // Capitals mean names, variables or languages ("X is", "in C mode"): never glue those.
                // Only the usual capital at the start of the first word is allowed ("Thn k").
                let eligible = t1.suf.isEmpty && t2.pre.isEmpty && w1.count + w2.count > 2
                    && w1.allSatisfy({ $0.isLetter || isApostrophe($0) }) && w2.allSatisfy({ $0.isLetter || isApostrophe($0) })
                    && w1.dropFirst().allSatisfy({ $0.isLowercase || isApostrophe($0) }) && w2.allSatisfy({ $0.isLowercase || isApostrophe($0) })
                    && !(w1.count == 1 && w1.first!.isUppercase)
                    && !hasKnownFix(w1) && !hasKnownFix(w2)

                if eligible {
                    let k1 = isValidWord(w1), k2 = isValidWord(w2)
                    let orphan1 = w1.count == 1 && !k1, orphan2 = w2.count == 1 && !k2

                    // "a" or "i" split off the front of a word ("a ccessed", "i nclude"): join when that makes a word
                    if w1.count == 1, k1, !k2, isValidWord(w1 + w2) {
                        result.append(Token(pre: t1.pre, core: w1 + w2, suf: t2.suf))
                        i += 2
                        continue
                    }
                    // ...or split off the end of a common word ("dat a", "comm a")
                    if w2.count == 1, k2, !k1, isValidWord(w1 + w2), (model.logFrequency((w1 + w2).lowercased()) ?? 0) >= 6 {
                        result.append(Token(pre: t1.pre, core: w1 + w2, suf: t2.suf))
                        i += 2
                        continue
                    }
                    // A stray letter, or two broken halves: join them ("b est" -> "best", "thn k" -> "think").
                    // Only glue onto a real word if the result is exactly a word ("the b" stays apart).
                    if orphan1 || orphan2 || (!k1 && !k2) {
                        let joinedWord = w1 + w2
                        // The words around the pair tell "I thn k the" (think) from "thank"
                        let before = result.last.map { $0.core.lowercased() }.flatMap { isValidWord($0) ? $0 : nil }
                        let after = i + 2 < tokens.count ? tokens[i + 2].core.lowercased() : nil
                        var fixed: String? = isValidWord(joinedWord) ? joinedWord
                            : ((k1 || k2) ? nil : closeFix(joinedWord, prev: before, next: after.flatMap { isValidWord($0) ? $0 : nil }))
                        // A stray letter that makes an exact word with the NEXT word belongs there ("multipel p urposes")
                        if orphan2, let left = fixed, i + 2 < tokens.count, tokens[i + 1].suf.isEmpty, tokens[i + 2].pre.isEmpty,
                           isValidWord(w2 + tokens[i + 2].core), !isValidWord(joinedWord) {
                            let rightFreq = model.logFrequency((w2 + tokens[i + 2].core).lowercased()) ?? 0
                            let leftFreq = model.logFrequency(left.lowercased()) ?? 0
                            if rightFreq >= leftFreq - 1 { fixed = nil }   // "gand" is too rare to beat "anything"
                        }
                        // Gluing a stray letter onto a correct word must not turn it into a rarer word ("in k" -> "ink")
                        if let f = fixed, k1 || k2 {
                            let base = (k1 ? w1 : w2).lowercased()
                            let fl = model.logFrequency(f.lowercased()) ?? 0, bl = model.logFrequency(base) ?? 0
                            if fl < bl - 1.5 { fixed = nil }
                        }
                        if let fixed {
                            result.append(Token(pre: t1.pre, core: fixed, suf: t2.suf))
                            i += 2
                            continue
                        }
                    }
                    // The space landed one key off: "ou tof" -> "out of", "righ tnow" -> "right now"
                    if !k1 || !k2 {
                        let moves: [(String, String)] = [
                            (w1 + String(w2.prefix(1)), String(w2.dropFirst())),
                            (String(w1.dropLast()), String(w1.suffix(1)) + w2)
                        ]
                        if let (a, b) = moves.first(where: { a, b in
                            isSolidPiece(a) && isSolidPiece(b)
                                && ((!k1 && !k2) || model.pairStrength(a.lowercased(), b.lowercased()) >= 2)
                        }) {
                            result.append(Token(pre: t1.pre, core: a, suf: ""))
                            result.append(Token(pre: "", core: b, suf: t2.suf))
                            i += 2
                            continue
                        }
                    }
                }
            }
            result.append(tokens[i])
            i += 1
        }
        return result
    }

    /// Converts runs of words typed in the wrong layout, but only when the result reads as English,
    /// so real writing in that language is left alone
    func fixWrongLayout(_ line: String) -> String {
        guard !WrongLayoutFixer.map.isEmpty, line.unicodeScalars.contains(where: { WrongLayoutFixer.map[$0] != nil }) else { return line }
        var tokens = line.components(separatedBy: " ")
        var i = 0
        while i < tokens.count {
            guard WrongLayoutFixer.looksForeign(tokens[i]) else { i += 1; continue }
            var j = i
            while j < tokens.count && WrongLayoutFixer.looksForeign(tokens[j]) { j += 1 }
            let converted = tokens[i..<j].map(WrongLayoutFixer.toEnglish)
            if readsAsEnglish(converted) { tokens.replaceSubrange(i..<j, with: converted) }
            i = j
        }
        return tokens.joined(separator: " ")
    }
    
    /// Most words are English, or are close typos of English words
    private func readsAsEnglish(_ words: [String]) -> Bool {
        let wasLearning = learning
        learning = false                  // just checking: don't count anything toward learning
        defer { learning = wasLearning }
        let cores = words.flatMap { $0.split(separator: " ").map(String.init) }
            .map { $0.filter { $0.isLetter || $0 == "'" } }.filter { !$0.isEmpty }
        guard !cores.isEmpty else { return false }
        let good = cores.filter { isValidWord($0) || (fixSingleWord($0) != $0 && isValidWord(fixSingleWord($0))) }.count
        return Double(good) / Double(cores.count) >= 0.6
    }
    
    // Full pipeline: strips stray backslash artifacts ("\d "), fixes double periods ("..  " -> ". "), split words, QWERTY typos, and sentence capitalization!
    func correctText(_ text: String, learn: Bool = false) -> String {
        learning = learn
        confidentFixes = [:]
        preferCurly = text.contains("’")
        var memo: [String: String] = [:]          // raw word -> fixed word, so repeats are fixed identically
        var seenTypos: [(typo: String, fix: String)] = []
        defer {
            if learning && !seenTypos.isEmpty { UserDictionaryStore.shared.notePendingFixes(seenTypos) }
            learning = false
        }
        let lines = text.components(separatedBy: "\n")
        var correctedLines: [String] = []
        
        for var line in lines {
            // 0. Words typed while another keyboard layout was switched on ("ฟหะ" -> "the" on Thai)
            line = fixWrongLayout(line)
            
            // 1. Strip accidental leading backslash-keystroke artifacts like "\d " or "\" at start of freewriting line
            if let range = line.range(of: #"^\\[a-zA-Z]?\s*"#, options: .regularExpression) {
                line.removeSubrange(range)
            }
            
            // 2. Collapse accidental double-periods (".." -> ".") and multiple spaces after period ("..  " -> ". ")
            line = line.replacingOccurrences(of: #"(?<!\.)\.\.(?!\.)"#, with: ".", options: .regularExpression)   // ".." but never "..."
            line = line.replacingOccurrences(of: #"([.!?])\s{2,}"#, with: "$1 ", options: .regularExpression)
            if Self.grammarEnabled { line = tidyPunctuation(line) }
            
            let rawWords = line.components(separatedBy: " ")
            var tokens: [Token] = []

            for token in rawWords {
                var s = token[...]
                var pre = ""
                var suf = ""
                while let first = s.first, !first.isLetter && !first.isNumber {
                    pre.append(first)
                    s = s.dropFirst()
                }
                while let last = s.last, !last.isLetter && !last.isNumber {
                    suf.insert(last, at: suf.startIndex)
                    s = s.dropLast()
                }
                // Symbol keys that bled into a word while typing ("keep[", "forward/.", "=we")
                if !s.isEmpty {
                    let bleed: Set<Character> = ["[", "]", "\\", "/", "=", "`"]
                    pre.removeAll { bleed.contains($0) }
                    suf.removeAll { bleed.contains($0) }
                }
                tokens.append(Token(pre: pre, core: String(s), suf: suf))
            }

            var finalTokens: [Token] = []
            var capitalizeNext = false // Only auto-capitalize after a period/!/? inside the line (or standalone 'i')
            var sentenceStart = true
            var prevWord: String? = nil   // the previous fixed word, for word-pair context
            var wordsInSentence = 0

            let joined = fixSplitWords(tokens)
            for (idx, token) in joined.enumerated() {
                var w = token.core
                let pre = token.pre
                var suf = token.suf

                if !w.isEmpty {
                    let raw = w
                    wordsInSentence += 1
                    var next: String? = nil
                    if idx + 1 < joined.count, token.suf.isEmpty {
                        let n = joined[idx + 1].core.lowercased()
                        if isValidWord(n) { next = n }
                    }
                    let memoKey = "\(prevWord ?? "")|\(raw)|\(next ?? "")|\(sentenceStart)"
                    if let cached = memo[memoKey] { w = cached } else {
                        w = fixSingleWord(raw, prev: prevWord, next: next, sentenceStart: sentenceStart)
                        // Spelled right but maybe the wrong word: check it against its neighbours
                        if w == raw, isValidWord(raw), let alt = realWordFix(raw.lowercased(), prev: prevWord, next: next) {
                            w = preserveCase(original: raw, corrected: alt)
                        }
                        memo[memoKey] = w
                    }
                    prevWord = w.lowercased().replacingOccurrences(of: "’", with: "'")
                    sentenceStart = false
                    // Every occurrence counts, so a typo repeated in one paragraph is learned right away
                    if learning, let fix = confidentFixes[raw.lowercased()] { seenTypos.append((raw.lowercased(), fix)) }
                    if w == "i" { w = "I" }
                    if capitalizeNext, let first = w.first, first.isLowercase {
                        w = w.prefix(1).uppercased() + w.dropFirst()
                        capitalizeNext = false
                    }
                }
                
                // A period that slipped in mid-thought: "I think. the best ideas" -> "I think the best ideas"
                if Self.grammarEnabled, suf == ".", idx + 1 < joined.count,
                   isAccidentalPeriod(after: w, next: joined[idx + 1], wordsSoFar: wordsInSentence) {
                    suf = ""
                }

                if suf.contains(".") || suf.contains("!") || suf.contains("?") {
                    capitalizeNext = true
                    sentenceStart = true
                    prevWord = nil
                    wordsInSentence = 0
                } else if !w.isEmpty {
                    capitalizeNext = false
                }
                
                finalTokens.append(Token(pre: pre, core: w, suf: suf))
            }
            if Self.grammarEnabled { finalTokens = lightGrammar(finalTokens) }
            correctedLines.append(finalTokens.map { $0.pre + $0.core + $0.suf }.joined(separator: " "))
        }
        
        return correctedLines.joined(separator: "\n")
    }
}
