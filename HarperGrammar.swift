import Foundation

/// Grammar fixes from Harper (https://writewithharper.com, Apache-2.0): a fast, offline,
/// rule-based checker. typ0s runs its `harper-cli` after fixing the typos and applies only
/// the grammar suggestions it trusts ("we was" -> "we were", "could of" -> "could have").
/// Spelling, style and formatting advice is ignored: typ0s fixes spelling itself, and
/// freewriting shouldn't be restyled.
enum HarperGrammar {
    /// Off unless the setting turns it on (training and tests run without it)
    static var enabled = false

    /// harper-cli bundled in the app by build.sh, or one installed with Homebrew (`brew install harper`)
    static let binary: URL? = {
        var places = ["/opt/homebrew/bin/harper-cli", "/usr/local/bin/harper-cli"]
        places.insert(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/harper-cli").path, at: 0)
        return places.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }()
    static var isAvailable: Bool { binary != nil }

    /// Kinds of advice that are about grammar, not style
    static let trustedKinds: Set<String> = ["Agreement", "Grammar", "Word Choice", "Miscellaneous", "Repetition", "Usage", "Typo"]
    /// Rules inside those kinds that restyle correct text or overlap with typ0s's own fixes
    static let skippedRules: Set<String> = ["CompoundNouns", "PhrasalVerbAsCompoundNoun", "SplitWords", "CommaFixes"]
    /// Single rules from other kinds that are worth having
    static let extraRules: Set<String> = ["CapitalizePersonalPronouns", "ItsContraction", "ItsPossessive"]

    /// The text with Harper's trusted grammar fixes applied, or the text unchanged if Harper
    /// isn't there, is slow, or finds nothing
    static func fix(_ text: String) -> String {
        guard enabled, let binary, text.contains(where: { $0.isLetter }) else { return text }
        guard let lints = lint(text, binary: binary) else { return text }

        // Harper counts positions in Unicode scalars
        var scalars = Array(text.unicodeScalars)
        let curly = text.contains("’")   // Freewrite types curly apostrophes; match them
        var edits: [(start: Int, end: Int, with: String)] = []
        for l in lints {
            guard let rule = l["rule"] as? String, let kind = l["kind"] as? String,
                  (trustedKinds.contains(kind) && !skippedRules.contains(rule)) || extraRules.contains(rule),
                  let span = l["span"] as? [String: Any],
                  let start = span["char_start"] as? Int, let end = span["char_end"] as? Int,
                  start >= 0, start < end, end <= scalars.count,
                  let suggestions = l["suggestions"] as? [String], let first = suggestions.first,
                  // several different fixes ("apart from" or "a part of"?) means Harper is guessing
                  suggestions.count == 1 || extraRules.contains(rule),
                  var replacement = replacementText(first) else { continue }
            if curly { replacement = replacement.replacingOccurrences(of: "'", with: "’") }
            // keep a capital the writer typed ("Apart" stays capitalised)
            if scalars[start].properties.isUppercase, let c = replacement.first, c.isLowercase {
                replacement = c.uppercased() + replacement.dropFirst()
            }
            edits.append((start, end, replacement))
        }
        // Apply from the end so earlier positions stay valid; skip edits that overlap
        var lastStart = Int.max
        for e in edits.sorted(by: { $0.start > $1.start }) where e.end <= lastStart {
            scalars.replaceSubrange(e.start..<e.end, with: Array(e.with.unicodeScalars))
            lastStart = e.start
        }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: scalars)
        return String(out)
    }

    /// "Replace with: “were”" -> "were" (other kinds of suggestion are skipped)
    static func replacementText(_ suggestion: String) -> String? {
        let prefix = "Replace with: “"
        guard suggestion.hasPrefix(prefix), suggestion.hasSuffix("”") else { return nil }
        return String(suggestion.dropFirst(prefix.count).dropLast())
    }

    /// A harper-cli that exits early must not take typ0s down with a broken pipe
    private static let ignoreBrokenPipes: Void = { signal(SIGPIPE, SIG_IGN) }()

    /// Runs harper-cli on the text; nil if it fails or takes longer than a second
    static func lint(_ text: String, binary: URL) -> [[String: Any]]? {
        _ = ignoreBrokenPipes
        let p = Process()
        p.executableURL = binary
        p.arguments = ["lint", "--format", "json", "--quiet", "--no-parallel"]
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        // Write and read at the same time, both inside the time limit
        let writer = input.fileHandleForWriting
        DispatchQueue.global(qos: .userInitiated).async {
            try? writer.write(contentsOf: Data(text.utf8))
            try? writer.close()
        }
        var data = Data()
        let reader = DispatchWorkItem { data = output.fileHandleForReading.readDataToEndOfFile() }
        DispatchQueue.global(qos: .userInitiated).async(execute: reader)
        if reader.wait(timeout: .now() + 1.0) == .timedOut { p.terminate(); return nil }
        p.waitUntilExit()

        guard let files = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        return files.flatMap { $0["lints"] as? [[String: Any]] ?? [] }
    }
}

extension FastTypoEngine {
    /// Typos first, then Harper's grammar fixes when that setting is on
    func fixAll(_ text: String, learn: Bool = false) -> String {
        HarperGrammar.fix(correctText(text, learn: learn))
    }
}
