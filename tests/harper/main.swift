import Foundation

// Harper grammar step: input -> expected after typ0s fixes typos and Harper fixes grammar.
// Skipped (exit 0) when harper-cli isn't installed.
guard HarperGrammar.isAvailable else { print("Harper: skipped (harper-cli not installed)"); exit(0) }
HarperGrammar.enabled = true
let engine = FastTypoEngine()
let cases: [(String, String)] = [
    ("we was out of milk.", "we were out of milk."),
    ("He go to school every day.", "He goes to school every day."),
    ("You should of known.", "You should have known."),
    ("it can require other services in it's constructor.", "it can require other services in its constructor."),
    ("It’s fine and its a apple, i think.", "It’s fine and it’s an apple, I think."),   // keeps curly apostrophes
    ("Apart of that, it works.", "Apart of that, it works."),                            // ambiguous: left alone
    ("Please run the image through an optimizing tool.", "Please run the image through an optimizing tool."),
    ("I think the best ideas come when you don't stop.", "I think the best ideas come when you don't stop."),
]
var failed = 0
for (input, expected) in cases {
    let got = engine.fixAll(input)
    if got != expected { failed += 1; print("FAIL  \(input)\n  got:      \(got)\n  expected: \(expected)") }
}
HarperGrammar.enabled = false
if engine.fixAll("we was out") != engine.correctText("we was out") { failed += 1; print("FAIL  Harper ran while switched off") }
print("Harper: \(cases.count + 1 - failed)/\(cases.count + 1) pass")
exit(failed == 0 ? 0 : 1)
