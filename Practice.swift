import SwiftUI

/// Typing practice on classic texts: the passage sits on screen and you type over it, word by word.
/// Backspace is off, like Freewrite, so your slips are the ones you really make. Because the passage shows
/// the word you meant, every slip is a certain example: typ0s learns typo → word rules and your hands' habits.
struct PracticeLane: View {
    let text: String
    var onNext: () -> Void

    private var words: [String] { text.split(separator: " ").map(String.init) }

    @State private var typed: [String] = [""]     // finished words, then the one being typed
    @State private var started: Date? = nil
    @State private var result: PracticeResult? = nil
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let result {
                PracticeResultView(result: result, again: reset, next: { reset(); onNext() })
            } else {
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    Text(lane())
                        .font(.terminal(17))
                        .lineSpacing(7)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .padding(14)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(focused ? Retro.cyan.opacity(0.6) : Retro.cream.opacity(0.3), lineWidth: 1.5))
                .contentShape(Rectangle())
                .onTapGesture { focused = true }

                HStack {
                    Text(focused ? "> type the passage. backspace is off, like Freewrite"
                                 : "> click the text to start typing")
                        .font(.terminal(11)).foregroundColor(Retro.cyan)
                    Spacer()
                    Text("\(typed.count - 1) / \(words.count) words")
                        .font(.terminal(11)).foregroundColor(Retro.cream.opacity(0.7))
                    Button("Next text") { reset(); onNext() }.buttonStyle(RetroButtonStyle())
                }
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down, action: key)
        .onAppear { focused = true }
        .onChange(of: text) { reset() }
    }

    private func reset() {
        typed = [""]; started = nil; result = nil; focused = true
    }

    private func key(_ press: KeyPress) -> KeyPress.Result {
        guard result == nil else { return .ignored }
        if press.modifiers.contains(.command) || press.modifiers.contains(.control) { return .ignored }
        if press.key == .delete || press.key == .deleteForward { return .handled }   // backspace is off
        if press.key == .return || press.key == .tab || press.key == .escape { return .ignored }
        // Printable characters only: arrow and function keys arrive as private-use characters
        let chars = press.characters.filter { c in
            c == " " || (!c.isWhitespace && c.unicodeScalars.allSatisfy { $0.value >= 0x20 && !(0xF700...0xF8FF).contains($0.value) })
        }
        guard !chars.isEmpty else { return .ignored }
        if started == nil { started = Date() }
        for c in chars {
            if c == " " {
                guard !(typed.last ?? "").isEmpty else { continue }   // a double space doesn't skip a word
                if typed.count >= words.count { finish(); return .handled }
                typed.append("")
            } else {
                typed[typed.count - 1].append(c)
                // The last word finishes as soon as it's long enough, no space needed
                if typed.count == words.count, typed.last!.count >= words.last!.count { finish(); return .handled }
            }
        }
        return .handled
    }

    /// The passage with what you've typed laid over it: right letters cream, wrong ones orange,
    /// extra letters red, the next letter under a cyan block, the rest dim
    private func lane() -> AttributedString {
        var out = AttributedString()
        let current = typed.count - 1
        let blinkOn = Int(Date().timeIntervalSinceReferenceDate * 2) % 2 == 0
        for (i, word) in words.enumerated() {
            let target = Array(word)
            if i > current {
                var a = AttributedString(word); a.foregroundColor = Retro.cream.opacity(0.35); out += a
            } else {
                let mine = Array(typed[i])
                for (k, ch) in target.enumerated() {
                    var a = AttributedString(String(ch))
                    if k < mine.count {
                        a.foregroundColor = mine[k] == ch ? Retro.cream : Retro.orange
                        if mine[k] != ch { a.underlineStyle = .single }
                    } else {
                        a.foregroundColor = Retro.cream.opacity(i == current ? 0.35 : 0.55)
                        if i < current { a.underlineStyle = .single }   // letters you skipped
                        if i == current && k == mine.count && blinkOn { a.backgroundColor = Retro.cyan.opacity(0.55) }
                    }
                    out += a
                }
                if mine.count > target.count {
                    var a = AttributedString(String(mine[target.count...])); a.foregroundColor = Retro.red.opacity(0.85)
                    out += a
                }
            }
            if i < words.count - 1 {
                var space = AttributedString(" ")
                if i == current && typed[i].count >= target.count && blinkOn { space.backgroundColor = Retro.cyan.opacity(0.55) }
                out += space
            }
        }
        return out
    }

    private func finish() {
        let seconds = max(1, Date().timeIntervalSince(started ?? Date()))
        let r = PracticeResult.make(typed: typed, words: words, seconds: seconds)
        r.learn()
        result = r
    }
}

/// What one run of a passage produced, and what typ0s learns from it
struct PracticeResult {
    var wpm: Int
    var accuracy: Int                                  // % of words typed exactly right
    var slips: [(typed: String, meant: String)]       // words you got wrong, as typed
    var keySlips: [KeyHabits.Slip]
    private static let engine = FastTypoEngine()

    static func make(typed: [String], words: [String], seconds: Double) -> PracticeResult {
        var right = 0
        var slips: [(String, String)] = []
        var keys: [KeyHabits.Slip] = []
        for (t, w) in zip(typed, words) {
            if t == w { right += 1; continue }
            let (tc, wc) = (core(t), core(w))
            if tc == wc { right += 1; continue }        // only punctuation or capitals differ: not a typo
            slips.append((t, w))
            keys += KeyHabits.slips(typed: tc, meant: wc)
        }
        let chars = typed.joined(separator: " ").count
        return PracticeResult(wpm: Int(Double(chars) / 5 / (seconds / 60)),
                              accuracy: words.isEmpty ? 0 : right * 100 / words.count,
                              slips: slips, keySlips: keys)
    }

    /// Lowercase letters and apostrophes only, for comparing words
    static func core(_ s: String) -> String {
        String(s.lowercased().map { $0 == "’" ? "'" : $0 }.filter { $0.isLetter || $0 == "'" })
    }

    /// Hand habits learn from every slip. Typo rules only come from typos that aren't real words
    /// ("form" for "from" would break the real word "form"), and still need to be seen twice.
    func learn() {
        KeyHabits.shared.record(keySlips)
        let pairs = slips.compactMap { s -> (typo: String, fix: String)? in
            let (t, m) = (Self.core(s.typed), Self.core(s.meant))
            guard !t.isEmpty, !m.isEmpty, !Self.engine.isValidWord(t), !KeyHabits.slips(typed: t, meant: m).isEmpty
            else { return nil }
            return (t, m)
        }
        UserDictionaryStore.shared.notePracticeFixes(pairs)
    }
}

/// The score after a passage: speed, accuracy, your slips, and the habits typ0s now knows about
struct PracticeResultView: View {
    let result: PracticeResult
    var again: () -> Void
    var next: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 28) {
                stat("\(result.wpm)", "wpm")
                stat("\(result.accuracy)%", "words right")
                stat("\(result.slips.count)", result.slips.count == 1 ? "slip" : "slips")
            }
            if !result.slips.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("> this run").font(.terminal(11)).foregroundColor(Retro.cyan)
                    ForEach(Array(result.slips.prefix(5).enumerated()), id: \.offset) { _, s in
                        HStack(spacing: 8) {
                            Text(s.typed).foregroundColor(Retro.orange)
                            Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)).foregroundColor(Retro.cream.opacity(0.5))
                            Text(s.meant).foregroundColor(Retro.cream)
                        }
                        .font(.terminal(14))
                    }
                }
            }
            let habits = KeyHabits.shared.top(4)
            if !habits.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("> your hands' habits, now part of fixing").font(.terminal(11)).foregroundColor(Retro.cyan)
                    ForEach(Array(habits.enumerated()), id: \.offset) { _, h in
                        Text("\(h.label)  ×\(h.count)").font(.terminal(13)).foregroundColor(Retro.cream.opacity(0.85))
                    }
                }
            }
            Spacer()
            HStack(spacing: 12) {
                Button("Next text", action: next).buttonStyle(RetroButtonStyle(lit: true)).keyboardShortcut(.return, modifiers: [])
                Button("Again", action: again).buttonStyle(RetroButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.retro(40)).foregroundColor(Retro.cream).retroGlow(Retro.cream, 0.7)
            Text(label).font(.terminal(11)).foregroundColor(Retro.cream.opacity(0.7))
        }
    }
}
