import Foundation
import Testing
@testable import FountainKit

// Every case below is a line that actually appears in the reference corpus at
// ~/Code/github.com/stevemurr/screenplays, and every rule has a negative test
// standing next to it built from the *legitimate* uses sitting in the same
// files. That pairing is the whole discipline here: `Ergosphere` misuses `.`
// eleven times and `Whorey` uses it correctly thirty, in the same corpus, so a
// rule that only proves it fires has proved nothing.

@Suite("Lint · scene headings written as sections")
struct SluglineAsSectionTests {

    /// Verbatim from `Trophy Boyz Rewrite/Episode 1.highland`, which writes all
    /// nine of its headings this way. Highland treats a section as outline text
    /// and leaves it out of the PDF, so those episodes export with no sluglines
    /// at all — the single most expensive mistake in the whole library.
    @Test("A heading written as a section is reported as invisible to the PDF")
    func sluglineAsSection() throws {
        let source = """
        # TROPHY BOYZ

        ## 1. EXT. RAVINE - DAY

        A desolate ravine, hidden from the main road above.
        """
        let diagnostics = Linter.lint(ScriptParser.parse(source), rules: [.sluglineAsSection])
        let diagnostic = try #require(diagnostics.first)
        #expect(diagnostics.count == 1)
        #expect(diagnostic.severity == .warning)
        #expect(diagnostic.message.contains("EXT. RAVINE - DAY"))
        #expect(diagnostic.message.contains("will not appear in the PDF"))
        #expect(diagnostic.replacement == "EXT. RAVINE - DAY #1#")
    }

    /// The fix has to survive being applied: the ordinal becomes a real `#1#`
    /// scene number, which is how the same writer numbers scenes in
    /// `anal-informant.fountain`.
    @Test("Accepting the fix turns the section into a numbered scene")
    func fixProducesAScene() throws {
        let source = "# TROPHY BOYZ\n\n## 1. EXT. RAVINE - DAY\n\nA desolate ravine.\n"
        let diagnostic = try #require(
            Linter.lint(ScriptParser.parse(source), rules: [.sluglineAsSection]).first
        )
        let repaired = ScriptParser.parse(diagnostic.applied(to: source))
        #expect(repaired.scenes.count == 1)
        #expect(repaired.scenes.first?.heading == "EXT. RAVINE - DAY")
        #expect(repaired.scenes.first?.number == "1")
        #expect(repaired.sections.count == 1)          // `# TROPHY BOYZ` survives
    }

    /// `anal-informant.fountain` has 40 sections in exactly this shape and
    /// `Horror Film 01/script.fountain` is nothing but prose sections. Not one
    /// of them may be touched.
    @Test("Ordinary outline sections are left alone")
    func realSectionsAreQuiet() {
        let source = """
        # Act One

        ## Beat 1: Mountain Valley Establishing Shots

        ## Beat 2: Dominic Kills Sal

        # Neighbors move in

        # Interior decorating goes wrong

        ### Bittersweet Ending:
        """
        #expect(Linter.lint(ScriptParser.parse(source), rules: [.sluglineAsSection]).isEmpty)
    }

    @Test("A leading ordinal is only stripped when it really is one")
    func ordinalSplitting() {
        #expect(Linter.splitLeadingOrdinal("1. EXT. RAVINE - DAY").number == "1")
        #expect(Linter.splitLeadingOrdinal("1. EXT. RAVINE - DAY").rest == "EXT. RAVINE - DAY")
        #expect(Linter.splitLeadingOrdinal("12) INT. CAR").rest == "INT. CAR")
        // `## Beat 1: …` must come back untouched, or the rule fires on 36 of
        // them in one script.
        #expect(Linter.splitLeadingOrdinal("Beat 1: Dominic Kills Sal").number == nil)
        #expect(Linter.splitLeadingOrdinal("1984 was a good year").number == nil)
    }
}

@Suite("Lint · en dash in a scene heading")
struct SceneHeadingEnDashTests {

    /// `EXT. MOUNTAIN – MORNING #1#` opens `anal-informant.fountain`. Four of
    /// these across two files, and at 12pt Courier the en dash is invisible.
    @Test("An en dash separator is reported with the hyphen as the fix")
    func enDash() throws {
        let source = "EXT. MOUNTAIN – MORNING #1#\n\nHigh on a peak.\n"
        let diagnostic = try #require(
            Linter.lint(ScriptParser.parse(source), rules: [.sceneHeadingEnDash]).first
        )
        #expect(diagnostic.severity == .suggestion)
        #expect(diagnostic.range.length == 1)
        #expect((source as NSString).substring(with: diagnostic.range) == "–")
        #expect(diagnostic.replacement == "-")
        #expect(diagnostic.applied(to: source).hasPrefix("EXT. MOUNTAIN - MORNING #1#"))
    }

    @Test("A hyphenated heading, and an en dash in prose, stay quiet")
    func hyphenAndProse() {
        // The corpus has 69 en dashes in `anal-informant.fountain` alone, all
        // but two of them inside action and dialogue where they belong.
        let source = """
        EXT. MOUNTAIN - MORNING #1#

        He waited – for a long time – then left.
        """
        #expect(Linter.lint(ScriptParser.parse(source), rules: [.sceneHeadingEnDash]).isEmpty)
    }
}

@Suite("Lint · ambiguous forcing marks")
struct AmbiguousForcedMarkTests {

    /// Verbatim from `Ergosphere/ergosphere.fountain`, which uses `.` as a
    /// generic "force this line" mark eleven times. Fountain reads it as a
    /// slugline and typesets the whole paragraph as a scene heading.
    @Test("A forced heading that reads like action is reported")
    func forcedActionAsHeading() throws {
        let source = ".Open to a commerical for the company ENERSPHERE.  The commercial is like the satire from robocop.\n"
        let diagnostic = try #require(
            Linter.lint(ScriptParser.parse(source), rules: [.ambiguousForcedMark]).first
        )
        #expect(diagnostic.severity == .warning)
        #expect(diagnostic.range == NSRange(location: 0, length: 1))
        #expect(diagnostic.replacement == "!")
        #expect(diagnostic.message.contains("reads like action"))

        // The fix has to actually reclassify the line.
        let repaired = ScriptParser.parse(diagnostic.applied(to: source))
        #expect(repaired.elements.first?.kind == .action)
        #expect(repaired.scenes.isEmpty)
    }

    /// `Whorey` and `THICK` force thirty perfectly good headings with the same
    /// character. Firing on those would make the rule worse than useless.
    @Test("Forced headings that really are headings stay quiet")
    func forcedHeadingsAreQuiet() {
        let source = """
        .INT. STRIP CLUB

        .EXT. BEACH - MAGIC HOUR

        .I/E. CAR - NIGHT

        .THE VOID
        """
        #expect(Linter.lint(ScriptParser.parse(source), rules: [.ambiguousForcedMark]).isEmpty)
    }

    /// `>What is the theme or central question of the story…` — twenty-two beat
    /// prompts in `Ergosphere`, every one of them right-aligned on the page as
    /// though it were `CUT TO:`.
    @Test("A forced transition that reads like a note is reported")
    func forcedNoteAsTransition() throws {
        let source = ">What is the theme or central question of the story that the B-story will resolve?\n"
        let diagnostic = try #require(
            Linter.lint(ScriptParser.parse(source), rules: [.ambiguousForcedMark]).first
        )
        #expect(diagnostic.severity == .warning)
        #expect(diagnostic.range == NSRange(location: 0, length: 1))
        #expect(diagnostic.replacement == "=")
        #expect(diagnostic.message.contains("reads like a note"))

        let repaired = ScriptParser.parse(diagnostic.applied(to: source))
        #expect(repaired.elements.first?.kind == .synopsis)
    }

    /// `>TITLE CARD: THE GIG ECONOMY` is a real forced transition in
    /// `THE_GIG_ECONOMY.fountain`, and `>… <` is centred text, not a transition
    /// at all. Both sit within a few lines of the prompts above.
    @Test("Legitimate forced transitions and centred text stay quiet")
    func realTransitionsAreQuiet() {
        let source = """
        >TITLE CARD: THE GIG ECONOMY

        >SMASH CUT TO:

        >1847 Industrial Blvd, Unit C.<

        >FADE OUT.
        """
        #expect(Linter.lint(ScriptParser.parse(source), rules: [.ambiguousForcedMark]).isEmpty)
    }
}

@Suite("Lint · lowercase scene headings")
struct LowercaseSceneHeadingTests {

    /// `INT. Horace apartment desk` from `whorey.fountain`, and
    /// `INT. NEEL's WORK` from `Rebase/script.fountain`.
    @Test("A heading that is not uppercase is a suggestion, not a warning")
    func lowercaseHeading() throws {
        let source = "INT. Horace apartment desk\n\nHe sits.\n"
        let diagnostic = try #require(
            Linter.lint(ScriptParser.parse(source), rules: [.lowercaseSceneHeading]).first
        )
        #expect(diagnostic.severity == .suggestion)
        #expect(diagnostic.replacement == "INT. HORACE APARTMENT DESK")
        #expect(diagnostic.applied(to: source).hasPrefix("INT. HORACE APARTMENT DESK\n"))
    }

    @Test("An uppercase heading, and prose forced into one, stay quiet")
    func uppercaseAndForcedProse() {
        // `.black screen with HORACE lightly moaning` is `whorey.fountain`
        // misusing the force mark — `ambiguous-forced-mark` has better advice
        // about it than "shout it", so this rule must not also claim it.
        let source = """
        INT. GLASS HOUSE - NIGHT

        .black screen with HORACE lightly moaning
        """
        #expect(Linter.lint(ScriptParser.parse(source), rules: [.lowercaseSceneHeading]).isEmpty)
    }
}

@Suite("Lint · scene heading separators")
struct SceneHeadingSeparatorTests {

    /// `I/E MONTAGE IMAGE - CHRIS BACKGROUND` from `Pixelate/script.fountain`.
    @Test("A prefix with no period after it is reported")
    func missingPeriod() throws {
        let source = "I/E MONTAGE IMAGE - CHRIS BACKGROUND\n\nA blur of faces.\n"
        let diagnostic = try #require(
            Linter.lint(ScriptParser.parse(source), rules: [.sceneHeadingSeparator]).first
        )
        #expect(diagnostic.severity == .suggestion)
        #expect((source as NSString).substring(with: diagnostic.range) == "I/E")
        #expect(diagnostic.replacement == "I/E.")
        #expect(diagnostic.applied(to: source).hasPrefix("I/E. MONTAGE IMAGE"))
    }

    @Test("Conforming prefixes, and prose that merely starts with INT, stay quiet")
    func conformingPrefixes() {
        // `.INTERIOR MONOLOGUE` starts with the letters I-N-T and is not an
        // `INT` heading at all. Matching on letters alone would report it.
        let source = """
        INT. HOME - DAY

        EXT. BEACH - NIGHT

        INT./EXT. CAR - DAY

        .INTERIOR MONOLOGUE
        """
        #expect(Linter.lint(ScriptParser.parse(source), rules: [.sceneHeadingSeparator]).isEmpty)
    }
}

@Suite("Lint · trailing whitespace on a cue")
struct TrailingWhitespaceTests {

    /// 302 lines of `anal-informant.fountain` end in stray spaces — Markdown's
    /// two-space hard break, left behind by a conversion. 220 of them are cues.
    @Test("A cue ending in invisible whitespace is reported")
    func trailingWhitespaceOnCue() throws {
        let source = "INT. HOME - DAY\n\nDOMINIC  \nWhere is he?\n"
        let diagnostic = try #require(
            Linter.lint(ScriptParser.parse(source), rules: [.trailingWhitespaceOnCue]).first
        )
        #expect(diagnostic.severity == .suggestion)
        #expect((source as NSString).substring(with: diagnostic.range) == "  ")
        #expect(diagnostic.replacement == "")
        #expect(diagnostic.applied(to: source) == "INT. HOME - DAY\n\nDOMINIC\nWhere is he?\n")
    }

    /// Only cues. The same file has hundreds of action and dialogue lines with
    /// the identical artifact, where it is invisible and inert — reporting
    /// those would bury every other diagnostic in the document.
    @Test("Trailing whitespace anywhere but a cue is ignored")
    func onlyCues() {
        let source = "INT. HOME - DAY  \n\nHe waits by the door.  \n\nDOMINIC\nWhere is he?  \n"
        #expect(Linter.lint(ScriptParser.parse(source), rules: [.trailingWhitespaceOnCue]).isEmpty)
    }
}

@Suite("Lint · duplicate scene numbers")
struct DuplicateSceneNumberTests {

    /// Scene numbers are the identity sidecar metadata re-attaches by after a
    /// reorder, so two headings sharing one is a real conflict rather than a
    /// style note.
    @Test("A repeated scene number is reported on the second heading")
    func duplicateNumber() throws {
        let source = """
        EXT. MOUNTAIN – MORNING #1#

        High on a peak.

        EXT. LAKE - MORNING #2#

        A car.

        INT. CAR - MORNING #2#

        He drives.
        """
        let diagnostics = Linter.lint(ScriptParser.parse(source), rules: [.duplicateSceneNumber])
        let diagnostic = try #require(diagnostics.first)
        #expect(diagnostics.count == 1)
        #expect(diagnostic.severity == .warning)
        #expect(diagnostic.lineIndex == 8)                    // the *second* #2#
        #expect((source as NSString).substring(with: diagnostic.range) == "#2#")
        #expect(diagnostic.message.contains("line 5"))
        // No safe automatic fix exists — only the writer knows which scene owns
        // the number. This is the one rule that offers no replacement.
        #expect(diagnostic.replacement == nil)
        #expect(!diagnostic.isFixable)
    }

    @Test("Distinct and absent scene numbers stay quiet")
    func distinctNumbers() {
        // `anal-informant.fountain` numbers 95 scenes #1# through #101# with no
        // collision, and most scripts number nothing at all.
        let source = """
        EXT. MOUNTAIN - MORNING #1#

        High on a peak.

        EXT. LAKE - MORNING #2#

        A car.

        INT. CAR - MORNING

        He drives.
        """
        #expect(Linter.lint(ScriptParser.parse(source), rules: [.duplicateSceneNumber]).isEmpty)
    }
}

@Suite("Lint · scene headings needing a blank line")
struct SceneHeadingBlankLineTests {

    /// Verbatim shape from `anal-informant.fountain`, where 21 headings are
    /// glued to the `## Beat n:` line above them. We read it as a heading and so
    /// does Highland; the Fountain spec asks for the blank line, and a stricter
    /// reader demotes the heading to action without saying so.
    @Test("A heading glued to the line above it is reported")
    func missingBlankLine() throws {
        let source = """
        ## Beat 2: Dominic Kills Sal
        EXT. SALS COTTAGE - MORNING #3#

        SAL pulls into the driveway.
        """
        let diagnostic = try #require(
            Linter.lint(ScriptParser.parse(source), rules: [.sceneHeadingNeedsBlankLine]).first
        )
        #expect(diagnostic.severity == .suggestion)
        #expect(diagnostic.lineIndex == 1)
        #expect(diagnostic.replacement == "\nEXT. SALS COTTAGE - MORNING #3#")

        let repaired = ScriptParser.parse(diagnostic.applied(to: source))
        #expect(repaired.scenes.count == 1)
    }

    @Test("A heading at the top of the file, or after a blank line, stays quiet")
    func separatedHeadings() {
        // The first line of a document is preceded by a blank as far as
        // Fountain is concerned — that is what makes `The Gig Economy` legal.
        let source = """
        INT. CAR - NIGHT

        Camera is in the backseat.

        EXT. STREET - NIGHT

        The car pulls away.
        """
        #expect(Linter.lint(ScriptParser.parse(source), rules: [.sceneHeadingNeedsBlankLine]).isEmpty)
    }
}

@Suite("Lint · the linter itself")
struct LinterTests {

    @Test("Diagnostics come back in source order")
    func sourceOrder() {
        // Three different rules, deliberately interleaved.
        let source = """
        ## 1. EXT. RAVINE - DAY

        INT. Horace apartment desk

        DOMINIC
        Where is he?

        EXT. MOUNTAIN – MORNING
        """
        let diagnostics = Linter.lint(ScriptParser.parse(source))
        #expect(diagnostics.map(\.rule) == [
            .sluglineAsSection, .lowercaseSceneHeading, .sceneHeadingEnDash
        ])
        #expect(diagnostics.map(\.range.location) == diagnostics.map(\.range.location).sorted())
        #expect(diagnostics.map(\.lineIndex) == [0, 2, 7])
    }

    @Test("A rule can be switched off without disturbing the others")
    func ruleFiltering() {
        let source = "INT. Horace apartment desk\n\nHe sits.\n\nEXT. LAKE – DAY\n\nWater.\n"
        let all = Linter.lint(ScriptParser.parse(source))
        let one = Linter.lint(ScriptParser.parse(source), rules: [.lowercaseSceneHeading])
        #expect(all.count == 2)
        #expect(one.count == 1)
        #expect(one.allSatisfy { $0.rule == .lowercaseSceneHeading })
        #expect(Linter.lint(ScriptParser.parse(source), rules: []).isEmpty)
    }

    @Test("Every diagnostic points at a range inside the document")
    func rangesAreInBounds() {
        let source = """
        ## 1. EXT. RAVINE - DAY

        .Open to a commercial for the company ENERSPHERE.

        >What is the theme or central question of this story?

        I/E MONTAGE IMAGE

        DOMINIC
        Where is he?
        """
        let length = (source as NSString).length
        for diagnostic in Linter.lint(ScriptParser.parse(source)) {
            #expect(diagnostic.range.location >= 0)
            #expect(diagnostic.range.length >= 0)
            #expect(diagnostic.range.location + diagnostic.range.length <= length)
        }
    }

    @Test("A clean script produces nothing at all")
    func cleanScript() {
        // Nothing here is ambiguous, so nothing here is worth saying.
        let source = """
        Title: Clean Break
        Author: Steven Murr

        # Act One

        INT. GLASS HOUSE - NIGHT #1#

        Rain needles the windows.

        LENA
        (quietly)
        You came back.

        CUT TO:

        EXT. LAKE - MORNING #2#

        A car crosses the valley floor.
        """
        #expect(Linter.lint(ScriptParser.parse(source)).isEmpty)
    }

    @Test("An empty document lints without complaint")
    func emptyDocument() {
        #expect(Linter.lint(ScriptParser.parse("")).isEmpty)
        #expect(Linter.lint(.empty).isEmpty)
    }

    @Test("Warnings mean the page will be wrong; everything else is a suggestion")
    func severities() {
        // The split is load-bearing for the UI: a warning earns a badge, a
        // suggestion does not. Three rules change what prints.
        let warnings = LintRule.allCases.filter { $0.severity == .warning }
        #expect(Set(warnings) == [.sluglineAsSection, .ambiguousForcedMark, .duplicateSceneNumber])
        #expect(Diagnostic.Severity.warning < Diagnostic.Severity.suggestion)
        #expect(LintRule.allCases.allSatisfy { !$0.title.isEmpty })
        // Rule identifiers are user-visible and go into the golden files;
        // renaming one is a breaking change, so pin the whole set.
        #expect(
            LintRule.allCases.map(\.rawValue).sorted() == [
                "ambiguous-forced-mark",
                "duplicate-scene-number",
                "lowercase-scene-heading",
                "scene-heading-en-dash",
                "scene-heading-needs-blank-line",
                "scene-heading-separator",
                "slugline-as-section",
                "trailing-whitespace-on-cue"
            ]
        )
    }
}
