import Cocoa
let root = CommandLine.arguments[1]
switch ProcessInfo.processInfo.environment["TYP0S_FIX"] { case "rules": FixGate.forceOff = true; case "careful": FixGate.mode = .careful; default: FixGate.mode = .bold }
let e = FastTypoEngine()
func words(_ s: String) -> [String] { s.components(separatedBy: " ") }
var exact = 0, total = 0, wordsRight = 0, wordsAll = 0, ms = 0.0
let tsv = try! String(contentsOfFile: root + "/tests/real_typos.tsv", encoding: .utf8)
for line in tsv.split(separator: "\n") where !line.hasPrefix("#") {
  let p = line.components(separatedBy: "\t"); guard p.count == 2 else { continue }
  let t0 = CFAbsoluteTimeGetCurrent(); let got = e.correctText(p[0]); ms += (CFAbsoluteTimeGetCurrent() - t0) * 1000
  total += 1; if got == p[1] { exact += 1 }
  let g = words(got), w = words(p[1])
  if g.count == w.count { wordsAll += w.count; wordsRight += zip(g, w).filter { $0 == $1 }.count } else { wordsAll += w.count }
  if got != p[1] && CommandLine.arguments.count > 2 { print("✗ got:  \(got)\n  want: \(p[1])") }
}
var regPass = 0, regTotal = 0
let reg = try! String(contentsOfFile: root + "/tests/regression.tsv", encoding: .utf8)
for line in reg.split(separator: "\n") where !line.hasPrefix("#") {
  let p = line.components(separatedBy: "\t"); guard p.count == 2 else { continue }
  regTotal += 1; let got = e.correctText(p[0]); if got == p[1] { regPass += 1 } else if CommandLine.arguments.count > 2 { print("✗ regression got:  \(got)\n             want: \(p[1])") }
}
print("Regression: \(regPass)/\(regTotal) pass")
var gPass = 0, gTotal = 0
let gram = try! String(contentsOfFile: root + "/tests/grammar.tsv", encoding: .utf8)
for line in gram.split(separator: "\n") where !line.hasPrefix("#") {
  let p = line.components(separatedBy: "\t"); guard p.count == 2 else { continue }
  gTotal += 1; let got = e.correctText(p[0]); if got == p[1] { gPass += 1 } else if CommandLine.arguments.count > 2 { print("✗ grammar got:  \(got)\n          want: \(p[1])") }
}
print("Grammar: \(gPass)/\(gTotal) pass")
var falsePos = 0
let clean = try! String(contentsOfFile: root + "/tests/clean_text.txt", encoding: .utf8)
for line in clean.split(separator: "\n") {
  let got = e.correctText(String(line)); if got != String(line) { falsePos += 1; if CommandLine.arguments.count > 2 { print("⚠ clean text changed:\n  \(line)\n  \(got)") } }
}
print("Real typos: \(exact)/\(total) sentences perfect, \(wordsRight)/\(wordsAll) words right (\(Int(Double(wordsRight)/Double(wordsAll)*100))%), avg \(String(format: "%.1f", ms/Double(total))) ms/sentence")
print("Clean text: \(falsePos) of \(clean.split(separator: "\n").count) lines wrongly changed")
