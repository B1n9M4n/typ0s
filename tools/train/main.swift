// Tunes the typo engine's knobs (TypoTuning) against real typo data, or scores the current settings.
//
// Build:  swiftc -O FastTypoEngine.swift WordModel.swift tools/train/main.swift -o build/train
// Score:  TYP0S_DICTIONARY=Dictionary build/train eval   <data.tsv>... [--limit N] [--fix bold|careful|rules]
// Tune:   TYP0S_DICTIONARY=Dictionary build/train search <data.tsv>... [--limit N]   (hill-climb the TypoTuning dials)
// Learn:  TYP0S_DICTIONARY=Dictionary build/train learn  <data.tsv>... [--out FixGate.swift]
//         (logistic regression that decides when a fix is safe; writes FixGate.swift)
// Rank:   TYP0S_DICTIONARY=Dictionary build/train learn-rank <data.tsv>... [--out RankModel.swift]
//         (softmax ranker that picks which word you meant; writes RankModel.swift. Retrain the gate after.)
//
// Use several kinds of data together: slips like yours (data/myslips_*.tsv), real misspellings
// (data/nonword_*.tsv) and real words typed as other real words (data/realslip_*.tsv).
//
// Each .tsv line is "typed sentence<TAB>correct sentence". The correct sentences double as clean
// text that must come back unchanged.
import Foundation

struct Score {
    var typos = 0, fixed = 0, wrong = 0, cleanSentences = 0, cleanDamaged = 0
    /// What we optimise: fixes count, wrong words cost twice as much, damaged clean text four times
    var objective: Double {
        Double(fixed) - 2 * Double(wrong) - 4 * Double(cleanDamaged)
    }
    var summary: String {
        let pct = { (a: Int, b: Int) in String(format: "%.1f%%", b == 0 ? 0 : Double(a) / Double(b) * 100) }
        return "fixed \(pct(fixed, typos)) of \(typos) typos · wrong words \(wrong) · clean sentences damaged \(cleanDamaged)/\(cleanSentences) (\(pct(cleanDamaged, cleanSentences)))"
    }
}

func load(_ path: String, limit: Int) -> [(String, String)] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fatalError("can't read \(path)") }
    let rows = text.split(separator: "\n").compactMap { line -> (String, String)? in
        let p = line.components(separatedBy: "\t")
        return p.count == 2 ? (p[0], p[1]) : nil
    }
    return Array(rows.prefix(limit))
}

func norm(_ token: String) -> String {
    token.lowercased().replacingOccurrences(of: "’", with: "'")
}

func score(_ rows: [(String, String)], _ engine: FastTypoEngine) -> Score {
    var s = Score()
    for (typed, correct) in rows {
        let want = correct.split(separator: " ").map { norm(String($0)) }
        let had = typed.split(separator: " ").map { norm(String($0)) }
        let got = engine.correctText(typed).split(separator: " ").map { norm(String($0)) }
        if had.count != want.count {
            // Space-bar slip: words were split or joined, so score the whole sentence as one typo
            s.typos += 1
            if got == want { s.fixed += 1 } else if got != had { s.wrong += 1 }
        } else {
        let typoIdx = (0..<want.count).filter { want[$0] != had[$0] }
        s.typos += typoIdx.count
        if got.count != want.count {
            s.wrong += 1
        } else {
            for i in 0..<want.count where got[i] != want[i] {
                if i < had.count && got[i] != had[i] { s.wrong += 1 }   // changed it, but to the wrong word
                else if !typoIdx.contains(i) { s.wrong += 1 }
            }
            s.fixed += typoIdx.filter { got[$0] == want[$0] }.count
        }
        }
        // The correct sentence must come back unchanged
        s.cleanSentences += 1
        if engine.correctText(correct).split(separator: " ").map({ norm(String($0)) }) != want { s.cleanDamaged += 1 }
    }
    return s
}

func evaluate(_ sets: [[(String, String)]]) -> (Score, [Score]) {
    let engine = FastTypoEngine()
    let parts = sets.map { score($0, engine) }
    var total = Score()
    for p in parts {
        total.typos += p.typos; total.fixed += p.fixed; total.wrong += p.wrong
        total.cleanSentences += p.cleanSentences; total.cleanDamaged += p.cleanDamaged
    }
    return (total, parts)
}

// MARK: - Learning the fix gate (logistic regression)

/// Letters (and inner apostrophes) of a token, lowercased: "forward/." -> "forward"
func letters(_ t: Substring) -> String {
    var s = Substring(t.replacingOccurrences(of: "’", with: "'"))
    while let f = s.first, !f.isLetter { s = s.dropFirst() }
    while let l = s.last, !l.isLetter { s = s.dropLast() }
    return String(s)
}

func learnGate(_ sets: [[(String, String)]], out: String) {
    FixGate.forceOff = true
    let engine = FastTypoEngine()
    var X: [[Double]] = [], y: [Double] = [], isClean: [Bool] = []
    func add(_ typed: String, gold: String, prev: String?, next: String?) {
        guard !typed.isEmpty, typed.allSatisfy({ $0.isLetter || $0 == "'" }), !engine.isValidWord(typed),
              let ex = engine.gateExample(typed, prev: prev, next: next) else { return }
        let clean = typed.lowercased() == gold.lowercased()   // correct but unknown (a name, "etcd"): fixing it is wrong
        X.append(ex.features); isClean.append(clean)
        y.append(!clean && ex.candidate == gold.lowercased() ? 1 : 0)
    }
    for rows in sets {
        for (typedSentence, goldSentence) in rows {
            let a = typedSentence.split(separator: " "), b = goldSentence.split(separator: " ")
            guard a.count == b.count else { continue }
            let gold = b.map(letters)
            func ctx(_ j: Int) -> String? { (0..<gold.count).contains(j) && engine.isValidWord(gold[j]) ? gold[j].lowercased() : nil }
            for i in 0..<a.count {
                // Like the engine: a capitalised unknown word mid-sentence is taken as a name and never reaches the gate
                let start = i == 0 || a[i - 1].reversed().prefix { !$0.isLetter && !$0.isNumber }.contains { ".!?".contains($0) }
                if !start, a[i].first?.isUppercase == true { continue }
                add(letters(a[i]), gold: gold[i], prev: ctx(i - 1), next: ctx(i + 1))
            }
        }
    }
    let n = X.count, d = X.first?.count ?? 0
    print("examples: \(n) (\(Int(y.reduce(0, +))) right fixes, \(isClean.filter { $0 }.count) correct-but-unknown words)")

    // Hold back every 5th example to pick the Bold / Careful cut-offs
    let trainIdx = (0..<n).filter { $0 % 5 != 0 }, valIdx = (0..<n).filter { $0 % 5 == 0 }
    var mean = [Double](repeating: 0, count: d), scale = [Double](repeating: 1, count: d)
    for j in 0..<d {
        let col = trainIdx.map { X[$0][j] }
        mean[j] = col.reduce(0, +) / Double(col.count)
        let v = col.map { ($0 - mean[j]) * ($0 - mean[j]) }.reduce(0, +) / Double(col.count)
        scale[j] = v > 1e-9 ? sqrt(v) : 1
    }
    let Z = X.map { row in (0..<d).map { (row[$0] - mean[$0]) / scale[$0] } }
    func prob(_ w: [Double], _ b: Double, _ z: [Double]) -> Double {
        var s = b; for j in 0..<d { s += w[j] * z[j] }; return 1 / (1 + exp(-s))
    }
    // Plain gradient descent on log-loss with a little L2
    var w = [Double](repeating: 0, count: d), b = 0.0
    for step in 1...800 {
        var gw = [Double](repeating: 0, count: d), gb = 0.0
        for i in trainIdx {
            let e = prob(w, b, Z[i]) - y[i]
            for j in 0..<d { gw[j] += e * Z[i][j] }
            gb += e
        }
        let m = Double(trainIdx.count)
        for j in 0..<d { w[j] -= 0.5 * (gw[j] / m + 0.001 * w[j]) }
        b -= 0.5 * gb / m
        if step % 200 == 0 {
            let loss = trainIdx.map { i -> Double in let p = min(max(prob(w, b, Z[i]), 1e-9), 1 - 1e-9); return -(y[i] * log(p) + (1 - y[i]) * log(1 - p)) }.reduce(0, +) / m
            print(String(format: "  step %d  log-loss %.4f", step, loss))
        }
    }
    // Pick cut-offs on 5-fold out-of-fold chances over all examples (fold 0 is the model above),
    // smoothing the objective over +/-0.02, so one lucky step on a small slice can't win
    let folds = 5
    var oof = [Double](repeating: 0, count: n)
    for k in 0..<folds {
        var fw = [Double](repeating: 0, count: d), fb = 0.0
        if k == 0 { fw = w; fb = b } else {
            let idx = (0..<n).filter { $0 % folds != k }
            for _ in 1...800 {
                var gw = [Double](repeating: 0, count: d), gb = 0.0
                for i in idx { let e = prob(fw, fb, Z[i]) - y[i]; for j in 0..<d { gw[j] += e * Z[i][j] }; gb += e }
                let m = Double(idx.count)
                for j in 0..<d { fw[j] -= 0.5 * (gw[j] / m + 0.001 * fw[j]) }
                fb -= 0.5 * gb / m
            }
        }
        for i in stride(from: k, to: n, by: folds) { oof[i] = prob(fw, fb, Z[i]) }
    }
    let allIdx = Array(0..<n)
    func pick(wrongCost: Double, cleanCost: Double) -> (Double, Int, Int, Int) {
        var raw: [(Double, Int, Int, Int, Double)] = []
        for t in stride(from: 0.05, through: 0.95, by: 0.01) {
            var fixed = 0, wrong = 0, damaged = 0
            for i in allIdx where oof[i] >= t {
                if y[i] == 1 { fixed += 1 } else if isClean[i] { damaged += 1 } else { wrong += 1 }
            }
            raw.append((t, fixed, wrong, damaged, Double(fixed) - wrongCost * Double(wrong) - cleanCost * Double(damaged)))
        }
        var best = (0.5, 0, 0, 0), bestObj = -Double.infinity
        for k in raw.indices {
            let win = raw[max(0, k - 2)...min(raw.count - 1, k + 2)]
            let obj = win.map { $0.4 }.reduce(0, +) / Double(win.count)
            if obj > bestObj { bestObj = obj; best = (raw[k].0, raw[k].1, raw[k].2, raw[k].3) }
        }
        return best
    }
    let bold = pick(wrongCost: 1.5, cleanCost: 3), careful = pick(wrongCost: 4, cleanCost: 8)   // Careful: a wrong fix costs 4 right ones
    let rights = allIdx.filter { y[$0] == 1 }.count
    print(String(format: "Bold    cut-off %.2f: fixes %d of %d right fixes, %d wrong fixes, %d correct words touched", bold.0, bold.1, rights, bold.2, bold.3))
    print(String(format: "Careful cut-off %.2f: fixes %d of %d right fixes, %d wrong fixes, %d correct words touched", careful.0, careful.1, rights, careful.2, careful.3))
    let names = ["slip cost", "cost per letter", "lead over runner-up", "word frequency", "fits left word", "fits right word",
                 "length", "candidates in reach", "macOS knows it", "capitalised", "contraction", "known stem + ending"]
    print("Learned weights (bigger = more confident to fix):")
    for j in 0..<d { print(String(format: "  %+.3f  %@", w[j], names[j] as NSString)) }

    let fmt = { (a: [Double]) in a.map { String(format: "%.6f", $0) }.joined(separator: ", ") }
    let file = """
    import Foundation

    /// Learned "is this fix right?" model (logistic regression over \(d) facts about a fix).
    /// Generated by `tools/train learn` from real typo data. Don't edit by hand; retrain instead.
    /// Facts, in order: \(names.joined(separator: ", ")).
    enum FixGate {
        /// Bold fixes more of your messy words; Careful only fixes when it's very sure
        enum Mode: String { case bold, careful }
        static var mode: Mode = .bold
        static var threshold: Double { mode == .bold ? boldThreshold : carefulThreshold }
        static var forceOff = false   // training/testing: use the hand-written rules instead
        static var isTrained: Bool { !weights.isEmpty && !forceOff }

        static let boldThreshold = \(String(format: "%.2f", bold.0))
        static let carefulThreshold = \(String(format: "%.2f", careful.0))
        static let mean: [Double] = [\(fmt(mean))]
        static let scale: [Double] = [\(fmt(scale))]
        static let weights: [Double] = [\(fmt(w))]
        static let bias = \(String(format: "%.6f", b))

        /// Chance (0-1) that fixing to the best candidate is right
        static func probability(_ x: [Double]) -> Double {
            var z = bias
            for i in 0..<weights.count { z += weights[i] * (x[i] - mean[i]) / scale[i] }
            return 1 / (1 + exp(-z))
        }
    }

    """
    try! file.write(toFile: out, atomically: true, encoding: .utf8)
    print("wrote \(out)")
}

// MARK: - Learning the ranker (softmax over candidates)

func learnRanker(_ sets: [[(String, String)]], out: String) {
    RankModel.forceOff = true
    FixGate.forceOff = true
    let engine = FastTypoEngine()
    var examples: [(gold: Int, feats: [[Double]])] = []
    for rows in sets {
        for (typedSentence, goldSentence) in rows {
            let a = typedSentence.split(separator: " "), b = goldSentence.split(separator: " ")
            guard a.count == b.count else { continue }
            let gold = b.map(letters)
            func ctx(_ j: Int) -> String? { (0..<gold.count).contains(j) && engine.isValidWord(gold[j]) ? gold[j].lowercased() : nil }
            for i in 0..<a.count {
                let typed = letters(a[i]), want = gold[i].lowercased()
                guard !typed.isEmpty, typed.lowercased() != want, typed.allSatisfy({ $0.isLetter || $0 == "'" }),
                      !engine.isValidWord(typed),
                      let ex = engine.rankExample(typed, gold: want, prev: ctx(i - 1), next: ctx(i + 1)),
                      let g = ex.keys.firstIndex(of: want) else { continue }
                examples.append((g, ex.features))
            }
        }
    }
    let d = examples.first?.feats.first?.count ?? 0
    print("ranking examples: \(examples.count) typos, \(examples.map { $0.feats.count }.reduce(0, +)) candidates")
    // Standardise each fact over all candidates
    var mean = [Double](repeating: 0, count: d), scale = [Double](repeating: 1, count: d), count = 0.0
    for ex in examples { for f in ex.feats { count += 1; for j in 0..<d { mean[j] += f[j] } } }
    for j in 0..<d { mean[j] /= count }
    for j in 0..<d {
        var v = 0.0
        for ex in examples { for f in ex.feats { v += (f[j] - mean[j]) * (f[j] - mean[j]) } }
        v /= count; scale[j] = v > 1e-9 ? sqrt(v) : 1
    }
    let Z = examples.map { ex in (ex.gold, ex.feats.map { f in (0..<d).map { (f[$0] - mean[$0]) / scale[$0] } }) }
    let trainZ = Z.enumerated().filter { $0.offset % 5 != 0 }.map { $0.element }
    let valZ = Z.enumerated().filter { $0.offset % 5 == 0 }.map { $0.element }
    func top1(_ w: [Double], _ data: [(Int, [[Double]])]) -> Double {
        var right = 0
        for (g, fs) in data {
            let scores = fs.map { f in (0..<d).map { w[$0] * f[$0] }.reduce(0, +) }
            if scores.indices.max(by: { scores[$0] < scores[$1] }) == g { right += 1 }
        }
        return Double(right) / Double(max(1, data.count))
    }
    // Start from the hand formula's shape (cheap slip, common word, good context), then learn
    var w = [Double](repeating: 0, count: d)
    w[0] = -1; w[1] = 0.3; w[2] = 0.1; w[3] = 0.1
    print(String(format: "hand-shaped start: picks the right word %.1f%% of the time (held-back)", top1(w, valZ) * 100))
    for step in 1...300 {
        var grad = [Double](repeating: 0, count: d)
        for (g, fs) in trainZ {
            let scores = fs.map { f in (0..<d).map { w[$0] * f[$0] }.reduce(0, +) }
            let mx = scores.max()!
            let ex = scores.map { exp($0 - mx) }, sum = ex.reduce(0, +)
            for (k, f) in fs.enumerated() {
                let p = ex[k] / sum
                for j in 0..<d { grad[j] += ((k == g ? 1 : 0) - p) * f[j] }
            }
        }
        for j in 0..<d { w[j] += 0.5 * (grad[j] / Double(trainZ.count) - 0.001 * w[j]) }
        if step % 100 == 0 { print(String(format: "  step %d  picks right word %.1f%% (train) %.1f%% (held-back)", step, top1(w, trainZ) * 100, top1(w, valZ) * 100)) }
    }
    let names = ["slip cost", "word frequency", "fits left word", "fits right word", "length change",
                 "same first letter", "same last letter", "stopped one key short", "contraction", "left association", "right association", "left pair unseen", "right pair unseen", "rarity"]
    print("Learned weights (bigger = more likely the intended word):")
    for j in 0..<d { print(String(format: "  %+.3f  %@", w[j], names[j] as NSString)) }
    let fmt = { (a: [Double]) in a.map { String(format: "%.6f", $0) }.joined(separator: ", ") }
    let file = """
    import Foundation

    /// Learned "which word did you mean?" model: a score for each candidate word (higher = more likely),
    /// from 9 facts about it. Generated by `tools/train learn-rank`. Don't edit by hand; retrain instead.
    /// Facts, in order: \(names.joined(separator: ", ")).
    enum RankModel {
        static var forceOff = false   // training/testing: use the hand-written formula instead
        static var isTrained: Bool { !weights.isEmpty && !forceOff }

        static let mean: [Double] = [\(fmt(mean))]
        static let scale: [Double] = [\(fmt(scale))]
        static let weights: [Double] = [\(fmt(w))]

        static func score(_ x: [Double]) -> Double {
            var z = 0.0
            for i in 0..<weights.count { z += weights[i] * (x[i] - mean[i]) / scale[i] }
            return z
        }
    }

    """
    try! file.write(toFile: out, atomically: true, encoding: .utf8)
    print("wrote \(out)")
}

// Knobs the search may move, with the factors to try around the current value
typealias Knob = (name: String, get: (TypoTuning) -> Double, set: (inout TypoTuning, Double) -> Void)
let knobs: [Knob] = [
    ("neighborKey", { $0.neighborKey }, { $0.neighborKey = $1 }),
    ("bledKey", { $0.bledKey }, { $0.bledKey = $1 }),
    ("extraKey", { $0.extraKey }, { $0.extraKey = $1 }),
    ("missedKey", { $0.missedKey }, { $0.missedKey = $1 }),
    ("swappedKeys", { $0.swappedKeys }, { $0.swappedKeys = $1 }),
    ("lastKeyNotReached", { $0.lastKeyNotReached }, { $0.lastKeyNotReached = $1 }),
    ("frequencyWeight", { $0.frequencyWeight }, { $0.frequencyWeight = $1 }),
    ("contextWeight", { $0.contextWeight }, { $0.contextWeight = $1 }),
    ("limitShort", { $0.limitShort }, { $0.limitShort = $1 }),
    ("limitMid", { $0.limitMid }, { $0.limitMid = $1 }),
    ("limitLong", { $0.limitLong }, { $0.limitLong = $1 }),
    ("tieCost", { $0.tieCost }, { $0.tieCost = $1 }),
    ("tieMargin", { $0.tieMargin }, { $0.tieMargin = $1 }),
    ("spellcheckerSlip", { $0.spellcheckerSlip }, { $0.spellcheckerSlip = $1 }),
    ("realWordMargin", { Double($0.realWordMargin) }, { $0.realWordMargin = Float($1) }),
    ("realWordSlipPenalty", { Double($0.realWordSlipPenalty) }, { $0.realWordSlipPenalty = Float($1) }),
]

setvbuf(stdout, nil, _IOLBF, 0)   // print progress lines as they happen, even when piped
var args = Array(CommandLine.arguments.dropFirst())
var limit = Int.max
if let i = args.firstIndex(of: "--limit"), i + 1 < args.count { limit = Int(args[i + 1]) ?? .max; args.removeSubrange(i...(i + 1)) }
guard args.count >= 2 else { print("usage: train eval|search <data.tsv>... [--limit N]"); exit(1) }
if let i = args.firstIndex(of: "--fix"), i + 1 < args.count {
    switch args[i + 1] {
    case "rules": FixGate.forceOff = true
    case "careful": FixGate.mode = .careful
    default: FixGate.mode = .bold
    }
    args.removeSubrange(i...(i + 1))
}
if let i = args.firstIndex(of: "--no-grammar") { FastTypoEngine.grammarEnabled = false; args.remove(at: i) }
var outPath = "FixGate.swift"
if let i = args.firstIndex(of: "--out"), i + 1 < args.count { outPath = args[i + 1]; args.removeSubrange(i...(i + 1)) }
let mode = args[0]
let files = Array(args.dropFirst())
let sets = files.map { load($0, limit: limit) }

if mode == "learn" { learnGate(sets, out: outPath); exit(0) }
if mode == "learn-rank" { learnRanker(sets, out: outPath == "FixGate.swift" ? "RankModel.swift" : outPath); exit(0) }

if mode == "eval" {
    let (total, parts) = evaluate(sets)
    for (file, part) in zip(files, parts) { print("\((file as NSString).lastPathComponent): \(part.summary)") }
    print("objective \(total.objective)")
    exit(0)
}

// Search: start real-word checking at a strict margin, then nudge every knob until nothing helps
var best = FastTypoEngine.tuning
if !best.realWordMargin.isFinite { best.realWordMargin = 6 }
FastTypoEngine.tuning = best
var bestScore = evaluate(sets).0
print("start: \(bestScore.summary) · objective \(bestScore.objective)")
for round in 1...3 {
    var improved = false
    for knob in knobs {
        for factor in [0.7, 0.85, 1.15, 1.3] {
            var trial = best
            knob.set(&trial, knob.get(best) * factor)
            FastTypoEngine.tuning = trial
            let s = evaluate(sets).0
            if s.objective > bestScore.objective {
                best = trial; bestScore = s; improved = true
                print("round \(round): \(knob.name) -> \(String(format: "%.3f", knob.get(best))) · \(s.summary) · objective \(s.objective)")
            }
        }
    }
    if !improved { break }
}
print("\nBest settings:")
for knob in knobs { print("  \(knob.name) = \(String(format: "%.3f", knob.get(best)))") }
