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

// MARK: - Typo engine: keyboard-aware edit distance + word frequency + word-pair context
class FastTypoEngine {
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
        "foward": "forward", "fowards": "forwards"
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
        if model.isLoaded { return model.contains(lower) }
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

    /// The most likely intended word: cheap keyboard mistakes, a common word, and one that fits its neighbours
    private func bestCandidate(for word: String, prev: String?, next: String?) -> (word: String, cost: Double)? {
        var pool = candidates(for: word)
        let first = rank(pool, for: word, prev: prev, next: next)
        if let f = first, f.cost <= 0.7 { return f }
        // Nothing very close: also try with one bled-in key removed first ("trhkn" -> "thkn" -> "think")
        guard word.count <= 9 else { return first }
        for skeleton in generateMotorSkeletons(word) { pool.formUnion(candidates(for: skeleton)) }
        return rank(pool, for: word, prev: prev, next: next)
    }

    private func rank(_ pool: Set<String>, for word: String, prev: String?, next: String?) -> (word: String, cost: Double)? {
        guard !pool.isEmpty else { return nil }
        let model = WordModel.shared
        var best: (word: String, cost: Double, score: Double)?
        var runnerUp = Double.infinity
        for c in pool {
            let target = WordModel.bareContractions[c] ?? c
            let key = target.lowercased()
            var cost = weightedEditDistance(from: word, to: c)
            if c.count == word.count + 1 && c.hasPrefix(word) { cost = min(cost, 0.5) }   // "whe" -> "when": last key not reached
            var score = cost - 0.3 * Double(model.logFrequency(key) ?? 5)
            if let p = prev { score -= 0.15 * Double(model.pairStrength(p, key)) }
            if let n = next { score -= 0.15 * Double(model.pairStrength(key, n)) }
            if best == nil || score < best!.score {
                if let b = best { runnerUp = b.score }
                best = (target, cost, score)
            } else if score < runnerUp {
                runnerUp = score
            }
        }
        guard let b = best else { return nil }
        // Not a close match and another word is nearly as likely: we'd be guessing, so don't
        if b.cost > 1.0 && runnerUp - b.score < 0.3 { return nil }
        return (b.word, b.cost)
    }

    /// How many keystroke mistakes we accept for a word of this length
    private func costLimit(_ length: Int) -> Double {
        length <= 3 ? 1.0 : (length <= 5 ? 1.6 : 2.2)
    }

    func qwertyKeyDistance(_ c1: Character, _ c2: Character) -> Double {
        if c1 == c2 { return 0.0 }
        guard let p1 = qwertyCoords[c1], let p2 = qwertyCoords[c2] else {
            return 1.4
        }
        let dx = p1.0 - p2.0
        let dy = p1.1 - p2.1
        let dist = sqrt(dx * dx + dy * dy)
        return dist <= 1.35 ? 0.42 : min(dist * 0.6, 1.45)
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
                return 0.40 // Adjacent key-bleed (like 'n' in 'nlife', 'w' in 'tewrm', 'y' in 'uyse', 'j' in 'maijkng')
            }
            return 0.95
        }
        var dp = Array(repeating: Array(repeating: 0.0, count: n + 1), count: m + 1)
        for i in 1...m { dp[i][0] = dp[i - 1][0] + delCost(i) }   // leading bleed ("nbewt") is as cheap as anywhere else
        for j in 1...n { dp[0][j] = Double(j) * 0.65 }

        for i in 1...m {
            for j in 1...n {
                let subCost = qwertyKeyDistance(s[i - 1], t[j - 1])
                let delCost = delCost(i)
                
                dp[i][j] = min(
                    dp[i - 1][j] + delCost,
                    dp[i][j - 1] + 0.65,   // a key that didn't register (very common when typing fast)
                    dp[i - 1][j - 1] + subCost
                )
                
                // Transposition (e.g. 'ik' -> 'ki' in 'maijkng' -> 'making', 'el' -> 'le' in 'uselful')
                if i > 1 && j > 1 && s[i - 1] == t[j - 2] && s[i - 2] == t[j - 1] {
                    dp[i][j] = min(dp[i][j], dp[i - 2][j - 2] + 0.38)
                }
                // Transposition across 1 neighbor bleed char (e.g. 'ijk' where 'j' bled between 'i' and 'k'!)
                if i > 2 && j > 1 && s[i - 1] == t[j - 2] && s[i - 3] == t[j - 1] {
                    dp[i][j] = min(dp[i][j], dp[i - 3][j - 2] + 0.65)
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
        // Words macOS knows but our list doesn't (rare words, names): only fix tiny slips
        if WordModel.shared.isLoaded && best.cost > 0.5 && spellCheckerKnows(letters) { return rawWord }
        // A weak match is probably a word we don't know (slang, a name): count it, stop "fixing" it once seen enough
        if best.cost > confidentTypoScore && learning && UserDictionaryStore.shared.noteUnknownWord(letters) { return rawWord }
        guard best.cost <= costLimit(word.count) else { return rawWord }
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

    /// A close real word for a joined fragment ("thnk" -> "think"), or nil
    private func closeFix(_ word: String) -> String? {
        let lower = word.lowercased()
        if isValidWord(lower) { return word }
        guard let best = bestCandidate(for: lower, prev: nil, next: nil), best.cost <= 1.0 else { return nil }
        return best.word
    }

    // Spacebar slips: a stray letter ("thn k", "b est", "anythin g"), a space in the wrong place ("ou tof"),
    // or one word split in two ("th e"). Never touches two real words, numbers, or punctuation between words.
    func fixSplitWords(_ tokens: [Token]) -> [Token] {
        guard tokens.count > 1 else { return tokens }
        var result: [Token] = []
        var i = 0
        let model = WordModel.shared

        while i < tokens.count {
            if i + 1 < tokens.count {
                let t1 = tokens[i]
                let t2 = tokens[i + 1]
                let w1 = t1.core
                let w2 = t2.core
                let eligible = t1.suf.isEmpty && t2.pre.isEmpty && !w1.isEmpty && !w2.isEmpty
                    && w1.allSatisfy({ $0.isLetter }) && w2.allSatisfy({ $0.isLetter })
                    && !hasKnownFix(w1) && !hasKnownFix(w2)

                if eligible {
                    let k1 = isValidWord(w1), k2 = isValidWord(w2)
                    let orphan1 = w1.count == 1 && !k1, orphan2 = w2.count == 1 && !k2

                    // A stray letter, or two broken halves: join them ("b est" -> "best", "thn k" -> "think").
                    // Only glue onto a real word if the result is exactly a word ("the b" stays apart).
                    if orphan1 || orphan2 || (!k1 && !k2) {
                        let joinedWord = w1 + w2
                        let fixed: String? = isValidWord(joinedWord) ? joinedWord : ((k1 || k2) ? nil : closeFix(joinedWord))
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

            var finalTokens: [String] = []
            var capitalizeNext = false // Only auto-capitalize after a period/!/? inside the line (or standalone 'i')
            var sentenceStart = true
            var prevWord: String? = nil   // the previous fixed word, for word-pair context

            let joined = fixSplitWords(tokens)
            for (idx, token) in joined.enumerated() {
                var w = token.core
                let pre = token.pre
                let suf = token.suf

                if !w.isEmpty {
                    let raw = w
                    var next: String? = nil
                    if idx + 1 < joined.count, token.suf.isEmpty {
                        let n = joined[idx + 1].core.lowercased()
                        if isValidWord(n) { next = n }
                    }
                    let memoKey = "\(prevWord ?? "")|\(raw)|\(next ?? "")|\(sentenceStart)"
                    if let cached = memo[memoKey] { w = cached } else {
                        w = fixSingleWord(raw, prev: prevWord, next: next, sentenceStart: sentenceStart)
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
                
                if suf.contains(".") || suf.contains("!") || suf.contains("?") {
                    capitalizeNext = true
                    sentenceStart = true
                    prevWord = nil
                } else if !w.isEmpty {
                    capitalizeNext = false
                }
                
                finalTokens.append(pre + w + suf)
            }
            
            correctedLines.append(finalTokens.joined(separator: " "))
        }
        
        return correctedLines.joined(separator: "\n")
    }
}
