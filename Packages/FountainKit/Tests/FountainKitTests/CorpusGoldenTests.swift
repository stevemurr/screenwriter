import Foundation
import Testing
@testable import FountainKit

// The reference corpus is the regression suite, not sample data. These tests
// run the parser and the linter over every `.fountain` file in
// `~/Code/github.com/stevemurr/screenplays` and pin the result, line by line,
// so that a future loosening of the leniency rules cannot quietly reclassify
// somebody's screenplay.
//
// The corpus is not in this repository and is not redistributable, so every
// test here has to survive its absence. It skips rather than fails, the way
// `ScriptParserPerformanceTests` does.
//
//   Regenerate every golden:
//     REGENERATE_GOLDENS=1 swift test --package-path Packages/FountainKit
//
//   Point the tests at a different tree (used to prove the skip path works):
//     SCREENPLAYS_CORPUS=/nowhere swift test --package-path Packages/FountainKit

/// Where the corpus is and what is in it.
enum Corpus {

    /// Overridable so the graceful-skip path is reachable without deleting
    /// anybody's screenplays.
    static let root: URL = {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["SCREENPLAYS_CORPUS"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Code/github.com/stevemurr/screenplays")
    }()

    /// Set `REGENERATE_GOLDENS=1` to rewrite the fixtures in place instead of
    /// comparing against them. Read exactly one thing before doing that: the
    /// diff. A golden that changed because the parser improved is a commit; a
    /// golden that changed because nobody looked is a regression.
    static let isRegenerating = ProcessInfo.processInfo.environment["REGENERATE_GOLDENS"] == "1"

    /// Every `.fountain` in the corpus, relative to `root`, sorted so the
    /// parameterised cases are reported in a stable order. Empty when the
    /// corpus is not on this machine.
    static let relativePaths: [String] = {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let enumerator = FileManager.default.enumerator(
                  at: root,
                  includingPropertiesForKeys: [.isRegularFileKey],
                  options: [.skipsHiddenFiles]
              )
        else { return [] }

        let rootComponents = root.standardizedFileURL.pathComponents
        var paths: [String] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "fountain" else { continue }
            let components = url.standardizedFileURL.pathComponents
            guard components.count > rootComponents.count else { continue }
            paths.append(components.dropFirst(rootComponents.count).joined(separator: "/"))
        }
        return paths.sorted()
    }()

    /// Golden fixtures live next to this file. Located through `#filePath`
    /// rather than a resource bundle so that `REGENERATE_GOLDENS=1` can rewrite
    /// them in the working tree, which a copied bundle cannot do.
    static let goldenDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)
        .appendingPathComponent("Golden", isDirectory: true)

    static func source(of relativePath: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    static func goldenURL(for relativePath: String) -> URL {
        goldenDirectory.appendingPathComponent("\(slug(for: relativePath)).txt")
    }

    /// `Anal Informant/anal-informant.fountain` → `Anal_Informant_anal-informant`.
    /// Keeps the directory in the name, because five scripts in the corpus are
    /// called `script.fountain`.
    static func slug(for relativePath: String) -> String {
        var stem = relativePath
        if stem.hasSuffix(".fountain") { stem.removeLast(".fountain".count) }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-."))
        return String(stem.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }

    /// Records the corpus being absent as a *known* issue, which keeps the suite
    /// green on a checkout without it while still saying out loud that the
    /// strongest tests in the package did not run.
    static func recordAbsence(_ comment: String = "") {
        withKnownIssue("Reference corpus not present at \(root.path); corpus tests skipped. \(comment)") {
            Issue.record("Reference corpus absent.")
        }
    }
}

/// The pinned form of a parse: enough to catch any reclassification, small
/// enough to read in a diff.
enum CorpusDigest {

    /// Bump when the format changes, so a stale golden fails loudly rather than
    /// comparing two different things.
    static let formatVersion = 1

    static func make(relativePath: String, source: String) -> String {
        let script = ScriptParser.parse(source)
        let diagnostics = Linter.lint(script)
        var lines: [String] = []

        lines.append("# Golden digest v\(formatVersion) — do not hand-edit.")
        lines.append("# REGENERATE_GOLDENS=1 swift test --package-path Packages/FountainKit")
        lines.append("source: \(relativePath)")
        lines.append("lines: \(LineIndex(source: source).count)")
        lines.append("elements: \(script.elements.count)")
        lines.append("scenes: \(script.scenes.count)")
        lines.append("sections: \(script.sections.count)")
        lines.append("outlineNodes: \(flattened(script.sections).count)")
        lines.append("characters: \(script.characters.count)")
        // Keys only. `TitlePage.range` is deliberately not pinned — it is a
        // derived offset that legitimately moves when the title-page block's
        // bounds are refined, and pinning it would turn an improvement into a
        // seventeen-file diff.
        lines.append(
            "titlePage: " + (script.titlePage.map { $0.entries.map(\.key).joined(separator: "|") } ?? "none")
        )

        lines.append("")
        lines.append("[cast]")
        lines.append(contentsOf: script.characters)

        lines.append("")
        lines.append("[kinds] <firstLine>[-<lastLine>]:<elementKind>, one entry per run")
        lines.append(contentsOf: kindRuns(script.elements))

        lines.append("")
        lines.append("[scenes] <index> <number|-> <heading>")
        for scene in script.scenes {
            lines.append("\(scene.index) \(scene.number ?? "-") \(scene.heading)")
        }

        lines.append("")
        lines.append("[outline] <depth> <title>")
        for node in flattened(script.sections) {
            lines.append("\(node.depth) \(node.title)")
        }

        lines.append("")
        lines.append("[lint] <rule> <count>")
        let counts = Linter.counts(diagnostics)
        for rule in LintRule.allCases where counts[rule] != nil {
            lines.append("\(rule.rawValue) \(counts[rule] ?? 0)")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// Consecutive lines of the same kind collapse into one entry. The corpus is
    /// 13,792 lines and roughly half of them are blank separators; writing every
    /// one out individually made the fixtures larger than the scripts.
    private static func kindRuns(_ elements: [Element]) -> [String] {
        var runs: [String] = []
        var index = 0
        while index < elements.count {
            let kind = elements[index].kind
            let start = elements[index].lineIndex
            var end = start
            while index + 1 < elements.count, elements[index + 1].kind == kind {
                index += 1
                end = elements[index].lineIndex
            }
            runs.append(start == end ? "\(start):\(kind.rawValue)" : "\(start)-\(end):\(kind.rawValue)")
            index += 1
        }
        return runs
    }

    /// The section tree in document order, depth first.
    private static func flattened(_ nodes: [SectionNode]) -> [SectionNode] {
        nodes.flatMap { [$0] + flattened($0.children) }
    }
}

@Suite("Corpus goldens")
struct CorpusGoldenTests {

    @Test("The reference corpus holds the 17 scripts these rules were tuned against")
    func corpusIsIntact() throws {
        guard !Corpus.relativePaths.isEmpty else { return Corpus.recordAbsence() }

        #expect(Corpus.relativePaths.count == 17)
        #expect(Corpus.relativePaths.contains("Anal Informant/anal-informant.fountain"))
        #expect(Corpus.relativePaths.contains("THICK/THICK-10.16.fountain"))

        // A golden left behind by a script that has since been renamed would
        // never be compared against anything, and would rot silently.
        let goldens = (try? FileManager.default.contentsOfDirectory(
            at: Corpus.goldenDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        let expected = Set(Corpus.relativePaths.map { Corpus.goldenURL(for: $0).lastPathComponent })
        let present = Set(goldens.filter { $0.pathExtension == "txt" }.map(\.lastPathComponent))
        #expect(
            present.subtracting(expected).isEmpty,
            "Stale goldens with no matching script, delete them: \(present.subtracting(expected).sorted())"
        )
        #expect(
            expected.subtracting(present).isEmpty,
            "Scripts with no golden: \(expected.subtracting(present).sorted())"
        )
    }

    /// One reported case per script, so a failure names the screenplay that
    /// changed rather than "the corpus".
    @Test("A corpus script still parses to its golden digest", arguments: Corpus.relativePaths)
    func matchesGolden(_ relativePath: String) throws {
        let digest = CorpusDigest.make(
            relativePath: relativePath,
            source: try Corpus.source(of: relativePath)
        )
        let url = Corpus.goldenURL(for: relativePath)

        if Corpus.isRegenerating {
            try FileManager.default.createDirectory(
                at: Corpus.goldenDirectory,
                withIntermediateDirectories: true
            )
            try digest.write(to: url, atomically: true, encoding: .utf8)
            return
        }

        let golden = try #require(
            try? String(contentsOf: url, encoding: .utf8),
            """
            No golden for \(relativePath) at \(url.path). \
            Regenerate with REGENERATE_GOLDENS=1 swift test --package-path Packages/FountainKit
            """
        )
        guard digest != golden else { return }

        // Report the first divergence rather than diffing two 60 KB strings into
        // the failure message.
        let actual = digest.split(separator: "\n", omittingEmptySubsequences: false)
        let expected = golden.split(separator: "\n", omittingEmptySubsequences: false)
        for (offset, pair) in zip(actual, expected).enumerated() where pair.0 != pair.1 {
            Issue.record(
                """
                \(relativePath) no longer matches its golden at digest line \(offset + 1):
                  golden: \(pair.1)
                  parsed: \(pair.0)
                """
            )
            return
        }
        Issue.record(
            "\(relativePath): golden has \(expected.count) digest lines, this parse produced \(actual.count)."
        )
    }

    /// Load-bearing for M8: moving a scene means moving one contiguous range,
    /// which only works if every UTF-16 unit of the document belongs to exactly
    /// one element. Proving it on hand-written fixtures is not the same as
    /// proving it on 13,792 lines of somebody's real writing.
    @Test("Element ranges tile a corpus script exactly", arguments: Corpus.relativePaths)
    func rangesTile(_ relativePath: String) throws {
        let source = try Corpus.source(of: relativePath)
        let ns = source as NSString
        let script = ScriptParser.parse(source)
        let length = ns.length

        var cursor = 0
        var failure: String?
        for (offset, element) in script.elements.enumerated() {
            if element.range.length < 0 || element.range.location < 0 {
                failure = "element \(offset) (\(element.kind)) has a negative range \(element.range)"
                break
            }
            if element.range.location != cursor {
                failure = """
                element \(offset) (\(element.kind)) starts at \(element.range.location) \
                but the previous element ended at \(cursor) — \
                \(element.range.location > cursor ? "a gap" : "an overlap")
                """
                break
            }
            if element.range.location + element.range.length > length {
                failure = "element \(offset) (\(element.kind)) range \(element.range) runs past \(length)"
                break
            }
            cursor = element.range.location + element.range.length
        }

        #expect(failure == nil, "\(relativePath): \(failure ?? "")")
        #expect(cursor == length, "\(relativePath): elements cover \(cursor) of \(length) UTF-16 units.")

        let rebuilt = script.elements.map { ns.substring(with: $0.range) }.joined()
        if rebuilt != source {
            Issue.record("\(relativePath): concatenating the element ranges does not reproduce the source.")
        }
    }

    /// A diagnostic that points outside the document crashes a text view rather
    /// than advising anybody.
    @Test("Every diagnostic on a corpus script points inside it", arguments: Corpus.relativePaths)
    func diagnosticRangesAreInBounds(_ relativePath: String) throws {
        let source = try Corpus.source(of: relativePath)
        let length = (source as NSString).length
        let diagnostics = Linter.lint(ScriptParser.parse(source))

        let broken = diagnostics.first {
            $0.range.location < 0 || $0.range.length < 0 || $0.range.location + $0.range.length > length
        }
        #expect(
            broken == nil,
            "\(relativePath): \(broken?.rule.rawValue ?? "") points at \(broken?.range.location ?? 0) in a \(length)-unit document."
        )
        #expect(
            diagnostics.allSatisfy { $0.lineIndex >= 0 },
            "\(relativePath): a diagnostic carries a negative line index."
        )
    }

    /// Measured directly from the files, not inferred. These are the numbers
    /// `CLAUDE.md` quotes, and the reason it can quote them.
    @Test("The measured corpus counts still hold")
    func measuredCounts() throws {
        guard !Corpus.relativePaths.isEmpty else { return Corpus.recordAbsence() }

        let informant = ScriptParser.parse(try Corpus.source(of: "Anal Informant/anal-informant.fountain"))
        #expect(informant.scenes.count == 95)
        #expect(informant.sections.count == 4)

        let thick = ScriptParser.parse(try Corpus.source(of: "THICK/THICK-10.16.fountain"))
        #expect(thick.scenes.count == 37)

        // Rule 7: a title page is never inferred. Only 7 of the 17 have one, and
        // `CUT TO:` at the head of a script must not become front matter.
        var withTitlePage: [String] = []
        for path in Corpus.relativePaths
        where ScriptParser.parse(try Corpus.source(of: path)).titlePage != nil {
            withTitlePage.append(path)
        }
        #expect(withTitlePage.count == 7, "Scripts with a title page: \(withTitlePage)")
    }

    /// The evidence that the lint rules are tuned rather than guessed at.
    ///
    /// Two of the eight report nothing here, and that is the point of running
    /// them over 13,792 lines of real writing:
    ///
    /// * `slugline-as-section` fires 42 times across exactly six Trophy Boyz
    ///   episodes — all of which are `.highland` bundles, which FountainKit
    ///   cannot open until the zip reader lands in M2. Zero here means the rule
    ///   does not false-fire on the 100-odd legitimate sections in the
    ///   plain-text corpus, which is the harder half to get right.
    /// * `duplicate-scene-number` finds no collision in any of the 75 scripts in
    ///   the library, `.highland` included. It is here because scene numbers are
    ///   the identity sidecar metadata will re-attach by, and a collision has to
    ///   be reported the first time it happens rather than the first time
    ///   somebody notices their notes moved.
    @Test("Every lint rule fires exactly as often as when it was tuned")
    func lintTotals() throws {
        guard !Corpus.relativePaths.isEmpty else { return Corpus.recordAbsence() }

        var totals: [LintRule: Int] = [:]
        for path in Corpus.relativePaths {
            let diagnostics = Linter.lint(ScriptParser.parse(try Corpus.source(of: path)))
            for (rule, count) in Linter.counts(diagnostics) {
                totals[rule, default: 0] += count
            }
        }

        let expected: [LintRule: Int] = [
            .sluglineAsSection: 0,             // 42 in the six Trophy Boyz `.highland` episodes
            .sceneHeadingEnDash: 4,            // `EXT. MOUNTAIN – MORNING`, 2 files
            .ambiguousForcedMark: 38,          // 14 `.` + 24 `>`, mostly Ergosphere
            .lowercaseSceneHeading: 4,         // `INT. NEEL's WORK`, `INT. Horace apartment desk`
            .sceneHeadingSeparator: 1,         // `I/E MONTAGE IMAGE - CHRIS BACKGROUND`
            .trailingWhitespaceOnCue: 424,     // the Markdown hard-break artifact
            .duplicateSceneNumber: 0,          // no collision anywhere in the library
            .sceneHeadingNeedsBlankLine: 25    // headings glued to a `## Beat n:` line
        ]

        for rule in LintRule.allCases {
            #expect(
                totals[rule, default: 0] == expected[rule, default: 0],
                """
                \(rule.rawValue) fired \(totals[rule, default: 0]) times across the corpus, \
                not \(expected[rule, default: 0]). If the new number is right, say why in the \
                commit — this count is the only evidence the rule is tuned.
                """
            )
        }
        #expect(totals.values.reduce(0, +) == 496)
    }
}
