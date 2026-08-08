import Foundation
import Testing
@testable import FountainKit

/// Auto-fix edits somebody's screenplay without being asked, so every test here
/// is about restraint rather than coverage.
@Suite("Auto-fix chooses conservatively")
struct AutoFixTests {

    private func lint(_ source: String) -> [Diagnostic] {
        Linter.lint(ScriptParser.parse(source))
    }

    @Test("Fixes are applied back to front, so no range is invalidated")
    func backToFront() {
        let source = "INT. ROOM – DAY\n\nShe waits.\n\nEXT. YARD – NIGHT\n\nHe waits.\n"
        let edits = AutoFix.edits(for: lint(source))
        #expect(edits.count == 2, "both en dashes are fixable")
        #expect(edits[0].range.location > edits[1].range.location)

        let fixed = AutoFix.apply(edits, to: source)
        #expect(!fixed.contains("–"))
        #expect(fixed.contains("INT. ROOM - DAY"))
        #expect(fixed.contains("EXT. YARD - NIGHT"))
        // Applying front-to-back instead would corrupt the second range, so this
        // is the assertion that the order is load-bearing rather than tidy.
        #expect(Linter.lint(ScriptParser.parse(fixed)).allSatisfy { $0.rule != .sceneHeadingEnDash })
    }

    @Test("The line the caret is on is never touched")
    func protectsTheCaretLine() {
        let source = "INT. ROOM – DAY\n\nShe waits.\n"
        let heading = (source as NSString).lineRange(for: NSRange(location: 0, length: 0))

        #expect(!AutoFix.edits(for: lint(source)).isEmpty, "without protection it would fix")
        #expect(
            AutoFix.edits(for: lint(source), protecting: heading).isEmpty,
            "the writer is on that line; fixing it would rewrite text under the cursor"
        )
    }

    /// The case that motivates the rule: this diagnostic fires the moment a cue
    /// is typed with a trailing space, which is *while* it is being typed.
    @Test("Trailing whitespace on the cue being typed is left alone")
    func doesNotFightTheWriter() {
        let source = "INT. ROOM - DAY\n\nMARLA  \nHello.\n"
        let cue = (source as NSString).range(of: "MARLA")
        let cueLine = (source as NSString).lineRange(for: cue)

        let unprotected = AutoFix.edits(for: lint(source))
        #expect(unprotected.contains { $0.replacement.isEmpty }, "the fix exists")
        #expect(AutoFix.edits(for: lint(source), protecting: cueLine).isEmpty)
    }

    @Test("Disabled rules do not fire")
    func respectsDisabledRules() {
        let source = "INT. ROOM – DAY\n\nShe waits.\n"
        #expect(!AutoFix.edits(for: lint(source)).isEmpty)
        #expect(AutoFix.edits(for: lint(source), excluding: [.sceneHeadingEnDash]).isEmpty)
    }

    @Test("Structural and unguessable rules never auto-apply")
    func refusesJudgementCalls() {
        #expect(LintRule.duplicateSceneNumber.canAutoFix == false)
        #expect(LintRule.sluglineAsSection.canAutoFix == false)
        #expect(LintRule.ambiguousForcedMark.canAutoFix == false)

        // `.` used as a general beat prefix, as Ergosphere does on eleven lines.
        // The linter is right that these typeset as sluglines; rewriting them
        // all unattended empties the navigator.
        let beats = """
        .Open on a commercial for the company

        .Blackness fast forwards to 1986
        """
        let beatDiagnostics = lint(beats)
        #expect(beatDiagnostics.contains { $0.rule == .ambiguousForcedMark })
        #expect(ScriptParser.parse(beats).scenes.count == 2)
        #expect(AutoFix.edits(for: beatDiagnostics).isEmpty)

        // A document made entirely of the rule that rewrites the outline must
        // produce no automatic edits at all.
        let trophy = """
        ## 1. EXT. RAVINE - DAY

        They climb.

        ## 2. INT. TRUCK - NIGHT

        They drive.
        """
        let diagnostics = lint(trophy)
        #expect(diagnostics.contains { $0.rule == .sluglineAsSection }, "the rule must fire here")
        #expect(AutoFix.edits(for: diagnostics).isEmpty)
    }

    @Test("Overlapping fixes never both apply")
    func refusesOverlaps() {
        // A lowercase heading that also uses an en dash: two diagnostics, and
        // the uppercase fix rewrites the characters the dash fix would replace.
        let source = "INT. room – day\n\nShe waits.\n"
        let diagnostics = lint(source)
        #expect(diagnostics.count >= 2, "this fixture needs two overlapping rules")

        let edits = AutoFix.edits(for: diagnostics)
        for (index, edit) in edits.enumerated() where index + 1 < edits.count {
            #expect(
                NSIntersectionRange(edit.range, edits[index + 1].range).length == 0,
                "edit \(index) overlaps the next one"
            )
        }
        // And the result is still a document the parser reads the same way.
        let fixed = AutoFix.apply(edits, to: source)
        #expect(ScriptParser.parse(fixed).scenes.count == 1)
    }

    /// Auto-fix has to converge: applying its own output must leave nothing to
    /// do, or the editor loops on every parse.
    ///
    /// `.Open on nothing` stays put — it is an `ambiguousForcedMark`, which does
    /// not auto-apply — so this also pins that the loop terminates with work
    /// still outstanding rather than only when the linter is silent.
    @Test("Applying the fixes leaves nothing further to fix")
    func reachesAFixedPoint() {
        let source = """
        INT. room – day

        She waits.
        MARLA\u{20}\u{20}
        Hello.
        .Open on nothing
        """
        var text = source
        for round in 0..<5 {
            let edits = AutoFix.edits(for: lint(text))
            if edits.isEmpty { break }
            text = AutoFix.apply(edits, to: text)
            #expect(round < 4, "auto-fix did not converge in five rounds")
        }
        #expect(AutoFix.edits(for: lint(text)).isEmpty)
    }

    /// Every fix is a replacement of a range the linter chose, so the corpus is
    /// the real test: applying them must never make a document the parser reads
    /// differently in scene or section count.
    @Test("Across the corpus, fixes never change how many scenes a script has")
    func acrossTheCorpus() throws {
        guard !Corpus.relativePaths.isEmpty else {
            Corpus.recordAbsence("AutoFixTests.acrossTheCorpus")
            return
        }
        for path in Corpus.relativePaths {
            let source = try Corpus.source(of: path)
            let before = ScriptParser.parse(source)
            let edits = AutoFix.edits(for: Linter.lint(before))
            guard !edits.isEmpty else { continue }
            let after = ScriptParser.parse(AutoFix.apply(edits, to: source))
            #expect(
                after.scenes.count == before.scenes.count,
                Comment(rawValue: "\(path): auto-fix changed the scene count "
                    + "\(before.scenes.count) → \(after.scenes.count)")
            )
        }
    }
}
