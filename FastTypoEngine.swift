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

// MARK: - Sub-2ms SymSpell + QWERTY Proximity + Punctuation/Case/Split Engine
class FastTypoEngine {
    private let spellChecker = NSSpellChecker.shared
    // True only for real fixes in other apps (not the Test tab), so practice text never teaches typos
    private var learning = false
    // Scores at or below this are near-certain typos and are never learned as words
    private let confidentTypoScore = 1.0
    // Confident typo -> fix pairs found in the current learning pass (lowercased)
    private var confidentFixes: [String: String] = [:]
    
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
        "dont": "don't", "doesnt": "doesn't", "didnt": "didn't", "im": "I'm", "ive": "I've"
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
        let lower = word.lowercased()
        if baseWhitelist.contains(lower) { return true }
        for rule in UserDictionaryStore.shared.customRules {
            if rule.replacement.lowercased() == lower { return true }
        }
        if word.count == 1 {
            return lower == "a" || lower == "i"
        }
        let range = spellChecker.checkSpelling(of: word, startingAt: 0)
        return range.location == NSNotFound
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
        
        var dp = Array(repeating: Array(repeating: 0.0, count: n + 1), count: m + 1)
        for i in 0...m { dp[i][0] = Double(i) }
        for j in 0...n { dp[0][j] = Double(j) }
        
        for i in 1...m {
            for j in 1...n {
                let subCost = qwertyKeyDistance(s[i - 1], t[j - 1])
                var delCost = 0.95
                if (i > 1 && qwertyKeyDistance(s[i - 1], s[i - 2]) <= 0.55) ||
                   (i < m && qwertyKeyDistance(s[i - 1], s[i]) <= 0.55) {
                    delCost = 0.40 // Adjacent key-bleed (like 'n' in 'nlife', 'w' in 'tewrm', 'y' in 'uyse', 'j' in 'maijkng')
                }
                
                dp[i][j] = min(
                    dp[i - 1][j] + delCost,
                    dp[i][j - 1] + 0.85,
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
    
    func fixSingleWord(_ rawWord: String) -> String {
        // Numbers, versions, times ("5", "v2", "10am") are never typos to fix
        if rawWord.contains(where: { $0.isNumber }) { return rawWord }
        // Other scripts (Thai, Chinese, ...) are real writing, not English typos
        if rawWord.unicodeScalars.contains(where: { $0.value > 0x024F && CharacterSet.letters.contains($0) }) { return rawWord }
        let lower = rawWord.lowercased()
        
        // 1. Check User's Custom Learned Dictionary first!
        for rule in UserDictionaryStore.shared.customRules {
            if !rule.typo.isEmpty && rule.typo == lower {
                let plain = rule.replacement == rule.replacement.lowercased()
                return plain ? preserveCase(original: rawWord, corrected: rule.replacement) : rule.replacement
            }
            if rule.replacement.lowercased() == lower {
                return rule.replacement // Preserve exact user casing (e.g. "NuPhy", "AI/NLP")
            }
        }
        
        if baseWhitelist.contains(lower) {
            if lower == "ai" || lower == "nlp" || lower == "ui" || lower == "ux" {
                return rawWord.uppercased()
            }
            return rawWord
        }
        
        // 2. Check Instant O(1) Mechanical Lookup Table
        if let direct = instantFixes[lower] {
            return preserveCase(original: rawWord, corrected: direct)
        }
        
        // 3. Compound Acronym / Hyphen Check (e.g. "AI-NLP" -> "AI/NLP")
        if rawWord.contains("-") {
            let parts = rawWord.components(separatedBy: "-")
            if parts.count == 2 && parts[0].count <= 4 && parts[1].count <= 4 &&
               parts[0].uppercased() == parts[0] && parts[1].uppercased() == parts[1] {
                return "\(parts[0])/\(parts[1])"
            }
            let fixedParts = parts.map { fixSingleWord($0) }
            return fixedParts.joined(separator: "-")
        }
        
        // 4. Strip internal accidental punctuation like 'ap[rt' -> 'aprt'
        let strippedInternalPunct = rawWord.filter { $0.isLetter || $0 == "'" }
        if strippedInternalPunct.count != rawWord.count && isValidWord(strippedInternalPunct) {
            return preserveCase(original: rawWord, corrected: strippedInternalPunct)
        }
        
        if isValidWord(rawWord) {
            return preserveCase(original: rawWord, corrected: rawWord)
        }
        
        // 5. Gather candidates from raw word, stripped word, and motor-skeletons (removing adjacent key-bleeds!)
        var candidatePool: [String] = []
        var seen = Set<String>()
        
        func addCandidates(for query: String) {
            let nsRange = NSRange(location: 0, length: (query as NSString).length)
            if let guesses = spellChecker.guesses(forWordRange: nsRange, in: query, language: "en_US", inSpellDocumentWithTag: 0) {
                for g in guesses {
                    if !seen.contains(g.lowercased()) {
                        seen.insert(g.lowercased())
                        candidatePool.append(g)
                    }
                }
            }
        }
        
        addCandidates(for: rawWord)
        if strippedInternalPunct != rawWord {
            addCandidates(for: strippedInternalPunct)
        }
        
        for skel in generateMotorSkeletons(strippedInternalPunct) {
            if isValidWord(skel) && !seen.contains(skel.lowercased()) {
                seen.insert(skel.lowercased())
                candidatePool.insert(skel, at: 0)
            }
            addCandidates(for: skel)
        }
        
        guard !candidatePool.isEmpty else {
            if learning { _ = UserDictionaryStore.shared.noteUnknownWord(rawWord) }
            return rawWord
        }
        
        var bestCandidate = rawWord
        var bestScore = Double.infinity
        
        for (index, candidate) in candidatePool.prefix(18).enumerated() {
            let dist = weightedEditDistance(from: strippedInternalPunct, to: candidate)
            let rankPenalty = Double(index) * 0.05
            // Prefer same-length or -1 length (key-bleed removal) over short fragments
            let lenDiff = abs(candidate.count - strippedInternalPunct.count)
            let lenPenalty = lenDiff > 2 ? Double(lenDiff) * 0.35 : 0.0
            let score = dist + rankPenalty + lenPenalty
            if score < bestScore {
                bestScore = score
                bestCandidate = candidate
            }
        }
        
        // A close match is a typo. A weak or missing match is probably a word we don't know
        // (a name, slang): count it, and stop "fixing" it once it has been seen often enough.
        if bestScore > confidentTypoScore && learning
            && UserDictionaryStore.shared.noteUnknownWord(strippedInternalPunct) {
            return rawWord
        }
        if bestScore <= 2.45 {
            if learning && bestScore <= confidentTypoScore && bestCandidate.lowercased() != lower {
                confidentFixes[lower] = bestCandidate.lowercased()
            }
            return preserveCase(original: rawWord, corrected: bestCandidate)
        }
        return rawWord
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

    // Spacebar slips ("righ tnow" -> "right now", "th e" -> "the").
    // Only fires when BOTH words are invalid: one bad word next to a good one is an ordinary typo for fixSingleWord.
    func fixSplitWords(_ tokens: [Token]) -> [Token] {
        guard tokens.count > 1 else { return tokens }
        var result: [Token] = []
        var i = 0

        while i < tokens.count {
            if i + 1 < tokens.count {
                let t1 = tokens[i]
                let t2 = tokens[i + 1]
                let w1 = t1.core
                let w2 = t2.core

                // Never reach across punctuation ("righ. tnow"), into numbers, or into known typos
                let eligible = t1.suf.isEmpty && t2.pre.isEmpty
                    && !w1.isEmpty && !w2.isEmpty
                    && w1.allSatisfy({ $0.isLetter }) && w2.allSatisfy({ $0.isLetter })
                    && !hasKnownFix(w1) && !hasKnownFix(w2)
                    && !isValidWord(w1) && !isValidWord(w2)

                if eligible {
                    // Space came one key too early: "giv eit" -> "give it"
                    if w2.count > 1 {
                        let newW1 = w1 + String(w2.prefix(1))
                        let newW2 = String(w2.dropFirst())
                        if isSolidPiece(newW1) && isSolidPiece(newW2) {
                            result.append(Token(pre: t1.pre, core: newW1, suf: ""))
                            result.append(Token(pre: "", core: newW2, suf: t2.suf))
                            i += 2
                            continue
                        }
                    }
                    // Space came one key too late: "righ tnow" -> "right now"
                    if w1.count > 1 {
                        let newW1 = String(w1.dropLast())
                        let newW2 = String(w1.suffix(1)) + w2
                        if isSolidPiece(newW1) && isSolidPiece(newW2) {
                            result.append(Token(pre: t1.pre, core: newW1, suf: ""))
                            result.append(Token(pre: "", core: newW2, suf: t2.suf))
                            i += 2
                            continue
                        }
                    }
                    // Stray space inside one word: "th e" -> "the"
                    let joined = w1 + w2
                    if isValidWord(joined.lowercased()) {
                        result.append(Token(pre: t1.pre, core: joined, suf: t2.suf))
                        i += 2
                        continue
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
            line = line.replacingOccurrences(of: #"\.{2}(?!\.)"#, with: ".", options: .regularExpression)
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
                tokens.append(Token(pre: pre, core: String(s), suf: suf))
            }

            var finalTokens: [String] = []
            var capitalizeNext = false // Only auto-capitalize after a period/!/? inside the line (or standalone 'i')

            for token in fixSplitWords(tokens) {
                var w = token.core
                let pre = token.pre
                let suf = token.suf

                if !w.isEmpty {
                    let raw = w
                    if let cached = memo[raw] { w = cached } else { w = fixSingleWord(raw); memo[raw] = w }
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
