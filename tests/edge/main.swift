import Foundation

// Edge cases: each line of tests/edge_cases.tsv (typed<TAB>expected) must come out as expected (Bold mode).
let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "tests/edge_cases.tsv"
guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { print("Edge cases: cannot read \(path)"); exit(1) }
let engine = FastTypoEngine()
var total = 0, passed = 0
for line in text.components(separatedBy: "\n") where !line.isEmpty && !line.hasPrefix("#") {
    let cols = line.components(separatedBy: "\t")
    guard cols.count == 2 else { continue }
    total += 1
    let got = engine.correctText(cols[0])
    if got == cols[1] { passed += 1 } else { print("FAIL  \(cols[0])\n  got:      \(got)\n  expected: \(cols[1])") }
}
print("Edge cases: \(passed)/\(total)")
exit(passed == total && total > 0 ? 0 : 1)
