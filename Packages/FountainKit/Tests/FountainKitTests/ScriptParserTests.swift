import Foundation
import Testing
@testable import FountainKit

// Cases drawn from the real corpus at ~/Code/github.com/stevemurr/screenplays.
// Every one of these is a construction that actually appears in the user's
// scripts, not a hypothetical.

@Suite("Line classification")
struct LineClassificationTests {

    @Test("Scene headings are recognised leniently")
    func sceneHeadings() {
        #expect(ScriptParser.isSceneHeading("INT. GLASS HOUSE - NIGHT"))
        #expect(ScriptParser.isSceneHeading("EXT. LAKE – MORNING"))      // en dash
        #expect(ScriptParser.isSceneHeading("I/E MONTAGE IMAGE"))        // no period
        #expect(ScriptParser.isSceneHeading("INT. NEEL's WORK"))         // lowercase 's
        #expect(ScriptParser.isSceneHeading("INT./EXT. CAR - DAY"))
        #expect(!ScriptParser.isSceneHeading("Rain needles the windows."))
    }

    @Test("Scene numbers split off the heading")
    func sceneNumbers() {
        let (heading, number) = ScriptParser.splitSceneNumber("EXT. MOUNTAIN – MORNING #1#")
        #expect(heading == "EXT. MOUNTAIN – MORNING")
        #expect(number == "1")

        // A heading with no number is left alone.
        let (plain, none) = ScriptParser.splitSceneNumber("INT. KITCHEN - DAY")
        #expect(plain == "INT. KITCHEN - DAY")
        #expect(none == nil)
    }

    @Test("A parenthetical on the cue line still reads as a cue")
    func cueWithInlineParenthetical() {
        // `Pixelate` writes cues this way throughout.
        #expect(ScriptParser.isCharacterCue("CHRIS (teasing and drawn out)"))
        #expect(ScriptParser.characterName(from: "CHRIS (teasing and drawn out)") == "CHRIS")
        #expect(ScriptParser.characterName(from: "JERRY (V.O.)") == "JERRY")
        #expect(ScriptParser.characterName(from: "COLIN^") == "COLIN")
    }

    @Test("Sentences are not promoted to cues")
    func cueRejection() {
        #expect(!ScriptParser.isCharacterCue("Rain needles the windows."))
        #expect(!ScriptParser.isCharacterCue(""))
        #expect(!ScriptParser.isCharacterCue("123"))
    }
}

@Suite("Title page")
struct TitlePageTests {

    @Test("A transition at the head of a script is not front matter")
    func cutToIsNotATitlePage() {
        // `CUT TO:` occurs 48 times in the corpus and matches a naive key
        // pattern. This is the regression that gate exists for.
        let script = ScriptParser.parse("CUT TO:\n\nINT. CAR - NIGHT\n")
        #expect(script.titlePage == nil)
        #expect(script.scenes.count == 1)
    }

    @Test("Most scripts have no title page at all")
    func noTitlePage() {
        // `The Gig Economy` opens straight on a slugline.
        let script = ScriptParser.parse("INT. CAR - NIGHT\nCamera is in the backseat.\n")
        #expect(script.titlePage == nil)
    }

    @Test("Indented multi-line values keep their shape")
    func indentedValues() throws {
        // Verbatim from `Rebase/script.fountain`.
        let source = """
        Title: ReBase
        Author: Steven Murr
        Date: 7/14/2023
        Contact:
            D in the B Productions
            940 Scott Ct.

        # Act 1
        """
        let page = try #require(ScriptParser.parse(source).titlePage)
        #expect(page.title == "ReBase")
        #expect(page.author == "Steven Murr")
        #expect(page.draftDate == "7/14/2023")          // `Date:`, not `Draft Date:`
        #expect(page.value(for: "Contact")?.contains("940 Scott Ct.") == true)

        let contact = try #require(page.entries.first { $0.key == "Contact" })
        #expect(contact.isIndented)
        #expect(contact.values.count == 2)
        #expect(contact.indent == "    ")
    }

    @Test("A leading blank line does not hide the title page")
    func leadingBlankLine() throws {
        // `Pixelate/script.fountain` opens with one.
        let source = "\nTitle:\n    _**PIXELATE**_\nCredit: Written By\n\nINT. HOME - DAY\n"
        let page = try #require(ScriptParser.parse(source).titlePage)
        #expect(page.title == "_**PIXELATE**_")          // emphasis kept verbatim
        #expect(page.credit == "Written By")
    }

    @Test("Key order and style survive a round trip")
    func roundTrip() throws {
        let source = """
        Title: ReBase
        Author: Steven Murr
        Contact:
            D in the B Productions

        """
        let page = try #require(ScriptParser.parse(source).titlePage)
        #expect(page.entries.map(\.key) == ["Title", "Author", "Contact"])
        #expect(page.serialized() == """
        Title: ReBase
        Author: Steven Murr
        Contact:
            D in the B Productions
        """)
    }
}

@Suite("Document structure")
struct StructureTests {

    @Test("Forced marks are stripped from text but remembered")
    func forcedMarks() {
        // `THICK-10.16.fountain` forces essentially every line.
        let script = ScriptParser.parse("#Act I\n\n.INT. BEDROOM - MORNING\n\n!Black screen.\n\n@JO\n(annoyed)\nUgh.\n")
        let kinds = script.elements.map(\.kind).filter { $0 != .blank }
        #expect(kinds == [.section, .sceneHeading, .action, .character, .parenthetical, .dialogue])

        let section = script.elements.first { $0.kind == .section }
        #expect(section?.text == "Act I")               // `#Act I` — no space after the hash
        #expect(section?.depth == 1)
        #expect(script.elements.first { $0.kind == .action }?.forcingMark == "!")
        #expect(script.characters == ["JO"])
    }

    @Test("Sections nest into a tree")
    func sectionTree() throws {
        // The shape `Anal Informant` uses: acts over beats.
        let source = """
        # Act One

        ## Beat 1

        EXT. MOUNTAIN – MORNING #1#

        High on a peak.

        ## Beat 2

        EXT. LAKE – MORNING #2#

        A car.

        # Act Two

        INT. HOUSE - DAY

        """
        let script = ScriptParser.parse(source)
        #expect(script.sections.count == 2)
        let actOne = try #require(script.sections.first)
        #expect(actOne.title == "Act One")
        #expect(actOne.children.map(\.title) == ["Beat 1", "Beat 2"])
        #expect(actOne.children.first?.sceneIndices == [1])
        #expect(script.scenes.count == 3)
        #expect(script.scenes.map(\.number) == ["1", "2", nil])
    }

    @Test("A document that is only sections still parses")
    func sectionsOnly() {
        // `Horror Film 01/script.fountain` is a beat sheet with no scenes.
        let script = ScriptParser.parse("# Neighbors move in\n\n# Something is wrong\n")
        #expect(script.scenes.isEmpty)
        #expect(script.sections.count == 2)
    }

    @Test("Boneyard spans lines and never becomes action")
    func boneyard() {
        let source = "INT. WORK\n\n/*\n- a note to self\n*/\n\nHe types.\n"
        let script = ScriptParser.parse(source)
        #expect(script.elements.filter { $0.kind == .boneyard }.count == 3)
        #expect(script.elements.contains { $0.kind == .action && $0.text == "He types." })
    }

    @Test("Element ranges tile the document with no gaps")
    func rangesTile() {
        // Load-bearing for M8: moving a scene means moving one contiguous
        // range, which only works if every byte belongs to exactly one element.
        let source = "Title: X\n\n# Act\n\nINT. A - DAY\n\nHe waits.\n\n@BOB\nHi.\n"
        let script = ScriptParser.parse(source)
        var cursor = 0
        for element in script.elements {
            #expect(element.range.location == cursor)
            cursor += element.range.length
        }
        #expect(cursor == (source as NSString).length)
    }
}

@Suite("Word count")
struct WordCountTests {

    /// The `Character`-splitting version this replaced, kept so the two can be
    /// proved to agree rather than assumed to.
    private func splitting(_ script: ParsedScript) -> Int {
        script.elements.reduce(into: 0) { total, element in
            switch element.kind {
            case .action, .dialogue, .sceneHeading, .parenthetical, .transition,
                 .centered, .lyrics, .character:
                total += element.text.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count
            default:
                break
            }
        }
    }

    @Test("The byte scan agrees with splitting on graphemes", arguments: [
        "INT. A - DAY\n\nHe waits.\n",
        "INT. A - DAY\n\n  leading and   doubled   spaces  \n",
        "INT. A - DAY\n\nsmart “quotes” and — dashes and ’apostrophes’\n",
        "INT. A - DAY\n\ntabs\tbetween\twords\n",
        "INT. A - DAY\n\ntrailing space \n\nMARA\nHello.\n",
        "INT. A - DAY\n\n\n\n",
        "INT. A - DAY\n\ncafé naïve résumé Ω 日本語 🎬 family: 👨‍👩‍👧‍👦\n",
        "INT. A - DAY\n\ne\u{0301}combining vs \u{00E9}precomposed\n",
        "# Only a section\n",
        ""
    ])
    func agreesOnEdgeCases(_ source: String) {
        let script = ScriptParser.parse(source)
        #expect(script.wordCount == splitting(script))
    }

    @Test("The byte scan agrees across every script in the corpus")
    func agreesOnTheCorpus() throws {
        guard !Corpus.relativePaths.isEmpty else { return Corpus.recordAbsence() }
        for path in Corpus.relativePaths {
            let script = ScriptParser.parse(try Corpus.source(of: path))
            #expect(
                script.wordCount == splitting(script),
                "\(path): byte scan and grapheme split disagree."
            )
        }
    }
}
