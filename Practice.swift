import SwiftUI

/// Typing practice on classic texts: the passage sits on screen and you type over it, word by word.
/// Backspace is off, like Freewrite, so your slips are the ones you really make. Because the passage shows
/// the word you meant, every run is a labelled example. Runs are only saved (PracticeData) for training typ0s
/// later; practising doesn't change how typ0s fixes.
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
        PracticeData.save(typed: typed.joined(separator: " "), meant: text)
        result = r
    }
}

/// What one run of a passage produced
struct PracticeResult {
    var wpm: Int
    var accuracy: Int                                  // % of words typed exactly right
    var slips: [(typed: String, meant: String)]       // words you got wrong, as typed

    static func make(typed: [String], words: [String], seconds: Double) -> PracticeResult {
        var right = 0
        var slips: [(String, String)] = []
        for (t, w) in zip(typed, words) {
            if core(t) == core(w) { right += 1 } else { slips.append((t, w)) }   // capitals and punctuation aren't typos
        }
        let chars = typed.joined(separator: " ").count
        return PracticeResult(wpm: Int(Double(chars) / 5 / (seconds / 60)),
                              accuracy: words.isEmpty ? 0 : right * 100 / words.count,
                              slips: slips)
    }

    /// Lowercase letters and apostrophes only, for comparing words
    static func core(_ s: String) -> String {
        String(s.lowercased().map { $0 == "’" ? "'" : $0 }.filter { $0.isLetter || $0 == "'" })
    }
}

/// Your practice runs, kept on this Mac only for training and testing typ0s later:
/// one line per run, what you typed, a tab, then the passage (the same typed⇥expected shape as typ0s's test data)
enum PracticeData {
    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("typ0s", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("practice.tsv")
    }

    static func save(typed: String, meant: String) {
        let clean = { (s: String) in s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
        let line = clean(typed) + "\t" + clean(meant) + "\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// How many runs and slipped words are saved so far
    static func totals() -> (runs: Int, slips: Int) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return (0, 0) }
        var runs = 0, slips = 0
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            runs += 1
            let t = parts[0].split(separator: " "), m = parts[1].split(separator: " ")
            slips += zip(t, m).filter { PracticeResult.core(String($0)) != PracticeResult.core(String($1)) }.count
        }
        return (runs, slips)
    }
}

/// The score after a passage: speed, accuracy, your slips, and how much practice data is saved
struct PracticeResultView: View {
    let result: PracticeResult
    var again: () -> Void
    var next: () -> Void
    private let saved = PracticeData.totals()

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
            VStack(alignment: .leading, spacing: 6) {
                Text("> saved for training: \(saved.runs) \(saved.runs == 1 ? "run" : "runs"), \(saved.slips) slipped words")
                    .font(.terminal(11)).foregroundColor(Retro.cyan)
                Text("Kept on this Mac only. Practising doesn't change how typ0s fixes.")
                    .font(.terminal(11)).foregroundColor(Retro.cream.opacity(0.7))
            }
            Spacer()
            HStack(spacing: 12) {
                Button("Next text", action: next).buttonStyle(RetroButtonStyle(lit: true)).keyboardShortcut(.return, modifiers: [])
                Button("Again", action: again).buttonStyle(RetroButtonStyle())
                Spacer()
                Button("Show data") { NSWorkspace.shared.activateFileViewerSelecting([PracticeData.url]) }
                    .buttonStyle(RetroButtonStyle())
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
