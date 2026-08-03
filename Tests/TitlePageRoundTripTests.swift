import FountainKit
import XCTest
@testable import Screenwriter

/// The title page is editable two ways — as raw text in the source pane and as
/// a form. Round-tripping through the form must not disturb anything the form
/// does not show.
final class TitlePageRoundTripTests: XCTestCase {

    /// Verbatim from `Pixelate/script.fountain`, including the blank first line.
    private let pixelate = """

    Title:
        _**PIXELATE**_
    Credit: Written By
    Author: Steven Murr
    Source: Story by Mark Schwab
    Draft Date: 11/1/2023
    Contact:
        Diamond in the Rough Films
        940 Scott Ct.
        Campbell, CA 95008

    # Opening Version 1

    """

    func testAnUntouchedFormLeavesTheDocumentByteIdentical() throws {
        let script = ScriptParser.parse(pixelate)
        let page = try XCTUnwrap(script.titlePage)
        XCTAssertEqual(page.applied(to: pixelate, existing: page), pixelate)
    }

    func testTheLeadingBlankLineSurvives() throws {
        // The block's range must start at `Title:`, not at offset zero, or
        // rewriting it would eat the blank line the author left above it.
        let script = ScriptParser.parse(pixelate)
        var page = try XCTUnwrap(script.titlePage)
        page.setValue("Steven Murr Jr.", for: "Author")
        let updated = page.applied(to: pixelate, existing: script.titlePage)
        XCTAssertTrue(updated.hasPrefix("\n"), "The blank line before Title: was consumed.")
        XCTAssertTrue(updated.contains("Author: Steven Murr Jr."))
    }

    func testEditingOneFieldPreservesOrderStyleAndEmphasis() throws {
        let script = ScriptParser.parse(pixelate)
        var page = try XCTUnwrap(script.titlePage)
        page.setValue("11/2/2023", for: "Draft Date")
        let updated = page.applied(to: pixelate, existing: script.titlePage)

        let reparsed = try XCTUnwrap(ScriptParser.parse(updated).titlePage)
        XCTAssertEqual(
            reparsed.entries.map(\.key),
            ["Title", "Credit", "Author", "Source", "Draft Date", "Contact"]
        )
        // Emphasis is markup inside the value, not something the form owns.
        XCTAssertEqual(reparsed.title, "_**PIXELATE**_")
        XCTAssertEqual(reparsed.draftDate, "11/2/2023")
        // The indented multi-line Contact block keeps its shape.
        let contact = try XCTUnwrap(reparsed.entries.first { $0.key == "Contact" })
        XCTAssertTrue(contact.isIndented)
        XCTAssertEqual(contact.values.count, 3)
        XCTAssertTrue(updated.contains("    Campbell, CA 95008"))
        // And the script below is untouched.
        XCTAssertTrue(updated.contains("# Opening Version 1"))
    }

    func testACustomKeyTheFormNeverShowsIsStillPreserved() throws {
        let source = """
        Title: Every Day
        Author: Steven Murr
        Copyright: (c) 2149 Structured Data Productions
        Series: Season 2

        FADE IN:

        """
        let script = ScriptParser.parse(source)
        var page = try XCTUnwrap(script.titlePage)
        page.setValue("Steve Murr", for: "Author")
        let updated = page.applied(to: source, existing: script.titlePage)
        XCTAssertTrue(updated.contains("Series: Season 2"))
        XCTAssertTrue(updated.contains("Copyright: (c) 2149 Structured Data Productions"))
    }

    func testTheAuthorsOwnKeySpellingIsKept() throws {
        // `Date:` is more common in the corpus than `Draft Date:`. Neither is
        // canonical, so editing must not normalise one into the other.
        let source = "Title: ReBase\nDate: 7/14/2023\n\nINT. A - DAY\n"
        let script = ScriptParser.parse(source)
        var page = try XCTUnwrap(script.titlePage)
        page.setValue("8/1/2023", for: "Date")
        let updated = page.applied(to: source, existing: script.titlePage)
        XCTAssertTrue(updated.contains("Date: 8/1/2023"))
        XCTAssertFalse(updated.contains("Draft Date:"))
    }

    func testAddingATitlePageToAScriptThatHasNone() throws {
        // 10 of the 17 scripts in the reference library have no title page.
        let source = "INT. CAR - NIGHT\n\nCamera is in the backseat.\n"
        let script = ScriptParser.parse(source)
        XCTAssertNil(script.titlePage)

        var page = TitlePage()
        page.setValue("The Gig Economy", for: "Title")
        page.setValue("Steven Murr", for: "Author")
        let updated = page.applied(to: source, existing: nil)

        let reparsed = try XCTUnwrap(ScriptParser.parse(updated).titlePage)
        XCTAssertEqual(reparsed.title, "The Gig Economy")
        // The original first line must still parse as a scene, which means a
        // blank line has to separate it from the new block.
        XCTAssertEqual(ScriptParser.parse(updated).scenes.first?.heading, "INT. CAR - NIGHT")
    }

    func testRemovingTheTitlePageTakesItsTrailingBlankLine() throws {
        let script = ScriptParser.parse(pixelate)
        let updated = TitlePage().applied(to: pixelate, existing: script.titlePage)
        XCTAssertNil(ScriptParser.parse(updated).titlePage)
        XCTAssertFalse(updated.contains("PIXELATE"))
        XCTAssertTrue(updated.contains("# Opening Version 1"))
        // No pile of blank lines left where the block used to be.
        XCTAssertFalse(updated.contains("\n\n\n\n"))
    }

    func testClearingAFieldRemovesTheLineRatherThanLeavingItEmpty() throws {
        let script = ScriptParser.parse(pixelate)
        var page = try XCTUnwrap(script.titlePage)
        page.setValue("", for: "Source")
        let updated = page.applied(to: pixelate, existing: script.titlePage)
        XCTAssertFalse(updated.contains("Source:"))
        XCTAssertTrue(updated.contains("Credit: Written By"))
    }
}

/// Replicates exactly what the UI test drives, at the model level, because a
/// VM round trip is a poor way to debug a parse.
@MainActor
final class TitlePageInsertionTests: XCTestCase {

    /// Byte-for-byte what the XCUITest types.
    private let typed = """
    INT. GLASS HOUSE - NIGHT

    Rain needles the windows.

    LENA
    You left the lights on.

    EXT. GARDEN - NIGHT

    Owen waits among the wet sculptures.

    """

    func testAddingATitleKeepsBothScenes() throws {
        let model = ScreenplayModel()
        model.load(typed)
        XCTAssertEqual(model.sceneCount, 2)

        var page = TitlePage()
        page.setValue("Glass House", for: "Title")
        model.text = page.applied(to: model.text, existing: model.script.titlePage)
        model.reparseNow()

        XCTAssertEqual(model.script.titlePage?.title, "Glass House")
        XCTAssertEqual(
            model.script.scenes.map(\.heading),
            ["INT. GLASS HOUSE - NIGHT", "EXT. GARDEN - NIGHT"]
        )
        XCTAssertEqual(model.sceneCount, 2, "Adding a title page dropped a scene.")
    }

    /// The sheet's field is bound per keystroke, so the document sees every
    /// prefix of the title as it is typed.
    func testTypingTheTitleOneCharacterAtATime() throws {
        let model = ScreenplayModel()
        model.load(typed)

        var page = TitlePage()
        for count in 1..."Glass House".count {
            page.setValue(String("Glass House".prefix(count)), for: "Title")
        }
        model.text = page.applied(to: model.text, existing: nil)
        model.reparseNow()

        XCTAssertEqual(model.script.titlePage?.title, "Glass House")
        XCTAssertEqual(model.sceneCount, 2)
    }
}
