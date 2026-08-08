import AppKit
import FountainKit
import SwiftUI
import XCTest
@testable import Screenwriter

/// Typed text must arrive already rendered.
///
/// The editor used to style everything downstream of the debounced parse, so a
/// character was laid out twice: once with whatever attributes it inherited, and
/// again ~150ms later with the right ones. The writer sees the second pass,
/// because the debounce holds it back until they stop typing.
///
/// Every test here is a form of the same question: **after `insertText` returns,
/// and before anything asynchronous has run, is the text on screen correct?**
@MainActor
final class LiveStylingTests: XCTestCase {

    private func makeEditor(
        _ source: String
    ) -> (host: EditorHostView, model: ScreenplayModel) {
        let model = ScreenplayModel()
        model.load(source)

        let host = EditorHostView(frame: NSRect(x: 0, y: 0, width: 760, height: 600))
        host.liveStyler.titlePageEnd = model.script.titlePage.map { NSMaxRange($0.range) } ?? 0
        host.setScriptColumn(Style.scriptColumnWidth)
        host.textView.string = source
        host.layoutSubtreeIfNeeded()

        let styler = ElementStyler(fontSize: 12)
        // Exactly what the surface applies, diagnostics included: a baseline
        // missing them would make the first debounced pass look dirty for a
        // reason that has nothing to do with what is being tested.
        host.applyStyle(
            base: styler.baseAttributes(),
            runs: styler.runs(for: model.script)
                + styler.diagnosticRuns(model.diagnostics, length: (source as NSString).length)
        )
        host.layoutSubtreeIfNeeded()
        return (host, model)
    }

    /// What the storage says about a character, with no parse involved.
    private func attributes(of host: EditorHostView, at offset: Int) -> [NSAttributedString.Key: Any] {
        host.textView.textStorage?.attributes(at: offset, effectiveRange: nil) ?? [:]
    }

    private func colour(of host: EditorHostView, at offset: Int) -> NSColor? {
        attributes(of: host, at: offset)[.foregroundColor] as? NSColor
    }

    private func indent(of host: EditorHostView, at offset: Int) -> CGFloat? {
        (attributes(of: host, at: offset)[.paragraphStyle] as? NSParagraphStyle)?.firstLineHeadIndent
    }

    // MARK: - The claim

    /// The case the whole thing exists for: a line becomes a character cue as
    /// the writer finishes typing it, and it is *already* in the cue column and
    /// the cue colour when `insertText` returns.
    func testALineBecomesACueWithinTheEditThatMakesItOne() throws {
        let source = "INT. ROOM - DAY\n\nMarla\nHello.\n"
        let (host, model) = makeEditor(source)
        let name = (source as NSString).range(of: "Marla")

        // Before: lowercase, so it is action, at the action indent.
        XCTAssertEqual(indent(of: host, at: name.location), 0, "action hangs at the action column")
        XCTAssertEqual(colour(of: host, at: name.location), Style.Element.body)

        let revision = model.revision
        host.textView.setSelectedRange(name)
        host.textView.insertText("MARLA", replacementRange: name)

        // No parse has run. Nothing has been debounced. This is the same
        // turn of the run loop the keystroke arrived on.
        XCTAssertEqual(model.revision, revision, "no reparse may have happened yet")

        let expected = ElementStyler(fontSize: 12)
        let cue = expected.runs(for: [
            Element(kind: .character, range: name, lineIndex: 0, text: "MARLA")
        ]).first
        XCTAssertEqual(
            colour(of: host, at: name.location), Style.Element.character,
            "the cue is still the body colour, so it was styled after the fact rather than during"
        )
        XCTAssertEqual(
            indent(of: host, at: name.location),
            (cue?.attributes[.paragraphStyle] as? NSParagraphStyle)?.firstLineHeadIndent,
            "the cue did not move to the cue column inside the edit"
        )
        XCTAssertGreaterThan(
            indent(of: host, at: name.location) ?? 0, 0,
            "a character cue is indented from the action column; an indent of zero means "
                + "the paragraph style never changed"
        )
    }

    /// And the styling it gets inside the edit is byte-for-byte the styling the
    /// full parse would have given it. If these ever diverge the writer sees a
    /// *worse* flicker than before, because the text would change meaning rather
    /// than merely arrive late.
    func testLiveStylingMatchesWhatTheFullParseWouldHaveApplied() throws {
        let source = "INT. ROOM - DAY\n\nMarla\nHello.\n"
        let (host, _) = makeEditor(source)
        let name = (source as NSString).range(of: "Marla")
        host.textView.setSelectedRange(name)
        host.textView.insertText("MARLA", replacementRange: name)

        let live = host.textView.textStorage!.attributedSubstring(
            from: NSRange(location: 0, length: (host.textView.string as NSString).length)
        )

        // Now do it the old way: parse the whole document and style from that.
        let settled = ScriptParser.parse(host.textView.string)
        let styler = ElementStyler(fontSize: 12)
        host.invalidateAppliedStyle()
        host.applyStyle(base: styler.baseAttributes(), runs: styler.runs(for: settled))
        let parsed = host.textView.textStorage!.attributedSubstring(
            from: NSRange(location: 0, length: (host.textView.string as NSString).length)
        )

        XCTAssertEqual(
            live.string, parsed.string, "Rule 2: styling must never touch a character"
        )
        for offset in 0..<(live.string as NSString).length {
            let a = live.attributes(at: offset, effectiveRange: nil)
            let b = parsed.attributes(at: offset, effectiveRange: nil)
            XCTAssertEqual(
                a[.foregroundColor] as? NSColor, b[.foregroundColor] as? NSColor,
                "colour diverged at \(offset)"
            )
            XCTAssertEqual(
                (a[.paragraphStyle] as? NSParagraphStyle)?.firstLineHeadIndent,
                (b[.paragraphStyle] as? NSParagraphStyle)?.firstLineHeadIndent,
                "indent diverged at \(offset)"
            )
            XCTAssertEqual(a[.font] as? NSFont, b[.font] as? NSFont, "font diverged at \(offset)")
        }
    }

    /// Splitting a dialogue block reclassifies the lines *below* the split, and
    /// they have to move inside the same edit too. This is the case that made
    /// the classification window cover two blocks rather than one.
    func testSplittingABlockRestylesWhatFallsOutOfIt() throws {
        let source = "INT. ROOM - DAY\n\nMARLA\nYou said ten.\nIt's a quarter past.\n"
        let (host, _) = makeEditor(source)
        let orphan = (source as NSString).range(of: "It's a quarter past.")

        let dialogueIndent = indent(of: host, at: orphan.location)
        XCTAssertGreaterThan(dialogueIndent ?? 0, 0, "it starts as dialogue, in the dialogue column")

        // Put a blank line above it: it stops being dialogue and becomes action.
        host.textView.setSelectedRange(NSRange(location: orphan.location, length: 0))
        host.textView.insertText("\n", replacementRange: NSRange(location: orphan.location, length: 0))

        XCTAssertEqual(
            indent(of: host, at: orphan.location + 1), 0,
            "the orphaned line is action now and belongs at the action column, but it was "
                + "left in the dialogue column until the debounced parse landed"
        )
    }

    // MARK: - The other half: the pass that used to happen after typing stopped

    /// With the text already correct, the debounced pass must find nothing to do.
    ///
    /// This is the second half of the jank and the half that survives making the
    /// first half instant: `setAttributes` over the styled window invalidates
    /// every laid-out fragment in it, so TextKit re-lays out the visible page.
    /// That is a render pass the writer sees, arriving exactly when they stop
    /// typing, even though not one attribute in it differs from what is on
    /// screen.
    func testTheDebouncedPassWritesNothingAfterOrdinaryTyping() throws {
        let source = "INT. ROOM - DAY\n\nMARLA\nYou said ten and it is a quarter past.\n"
        let (host, model) = makeEditor(source)
        let caret = (source as NSString).range(of: "quarter").location

        host.textView.setSelectedRange(NSRange(location: caret, length: 0))
        host.resetStyleWrites()

        for _ in 0..<12 {
            host.textView.insertText("x", replacementRange: host.textView.selectedRange())
        }
        XCTAssertEqual(host.styleWrites, 0, "typing itself must not go through applyStyle at all")

        // Now the debounce fires: parse, and apply exactly as the surface does.
        model.text = host.textView.string
        model.reparseNow()
        let styler = ElementStyler(fontSize: 12)
        host.applyStyle(
            base: styler.baseAttributes(),
            runs: styler.runs(for: model.script)
                + styler.diagnosticRuns(
                    model.diagnostics, length: (model.text as NSString).length
                )
        )

        XCTAssertEqual(
            host.styleWrites, 0,
            "the debounced pass rewrote the window even though nothing about the styling "
                + "changed. That write is the render pass the writer sees after they stop typing."
        )
    }

    /// The skip is not achieved by never writing. When the styling genuinely
    /// changes, the pass still writes — and writes a *small* range, not the
    /// whole window.
    func testTheDebouncedPassStillWritesWhenStylingActuallyChanges() throws {
        let source = "INT. ROOM - DAY\n\nMarla\nHello.\n\nShe waits.\n"
        let (host, model) = makeEditor(source)

        // An edit the live styler is not allowed to make: the styler is told
        // this document has a boneyard, so it refuses everything.
        host.liveStyler.allowsLiveStyling = false
        let name = (source as NSString).range(of: "Marla")
        host.textView.setSelectedRange(name)
        host.textView.insertText("MARLA", replacementRange: name)
        XCTAssertNotEqual(
            colour(of: host, at: name.location), Style.Element.character,
            "with live styling refused, the cue must not already be styled — otherwise this "
                + "test cannot tell the two paths apart"
        )

        host.resetStyleWrites()
        model.text = host.textView.string
        model.reparseNow()
        let styler = ElementStyler(fontSize: 12)
        host.applyStyle(base: styler.baseAttributes(), runs: styler.runs(for: model.script))

        XCTAssertEqual(host.styleWrites, 1, "the fallback path still has to style the text")
        XCTAssertEqual(colour(of: host, at: name.location), Style.Element.character)
    }

    /// A type-size change alters every attribute while changing no run's
    /// signature, so the diff would correctly conclude there is nothing to
    /// write. The surface has to say otherwise, and this is the test that
    /// catches it if `invalidateAppliedStyle` ever stops being called.
    func testATypeSizeChangeStillRestylesEverything() throws {
        let source = "INT. ROOM - DAY\n\nMARLA\nYou said ten.\n"
        let (host, model) = makeEditor(source)
        let cue = (source as NSString).range(of: "MARLA").location
        let before = indent(of: host, at: cue) ?? 0
        XCTAssertGreaterThan(before, 0)

        host.resetStyleWrites()
        host.invalidateAppliedStyle()
        let larger = ElementStyler(fontSize: 24)
        host.applyStyle(base: larger.baseAttributes(), runs: larger.runs(for: model.script))

        XCTAssertEqual(host.styleWrites, 1)
        XCTAssertEqual(
            indent(of: host, at: cue), before * 2,
            "the cue column scales with the type, or the screenplay stops looking like one"
        )
    }

    // MARK: - Refusals

    /// Rule 7. A writer typing `Title:` on the first line is creating a title
    /// page the last parse has never seen, and live classification would call
    /// that line action. Refuse, and let the parse decide.
    func testTheHeadOfTheDocumentIsLeftToTheParser() throws {
        let (host, _) = makeEditor("INT. ROOM - DAY\n\nShe waits.\n")
        host.liveStyler.resetCounts()
        host.textView.setSelectedRange(NSRange(location: 0, length: 0))
        host.textView.insertText("Title: A Script", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(host.liveStyler.styledEdits, 0, "the document head is the title page's")
        XCTAssertGreaterThan(host.liveStyler.refusedEdits, 0)
    }

    /// A refusal must not leave the text unstyled forever: the debounced pass
    /// has to be told it still owns that range, even when no signature changed.
    func testRefusedTextIsStillStyledByTheDebouncedPass() throws {
        let source = "INT. ROOM - DAY\n\nShe waits.\n"
        let (host, model) = makeEditor(source)
        host.liveStyler.allowsLiveStyling = false
        host.resetStyleWrites()

        // An edit that changes no element's kind — so the diff alone would find
        // nothing to write — but which live styling declined to handle.
        let caret = (source as NSString).range(of: "waits").location
        host.textView.setSelectedRange(NSRange(location: caret, length: 0))
        host.textView.insertText("still ", replacementRange: NSRange(location: caret, length: 0))

        model.text = host.textView.string
        model.reparseNow()
        let styler = ElementStyler(fontSize: 12)
        host.applyStyle(base: styler.baseAttributes(), runs: styler.runs(for: model.script))

        XCTAssertEqual(
            host.styleWrites, 1,
            "nothing styled this text: the live styler refused it and the diff saw no change"
        )
    }

    /// Styling must not move the caret.
    ///
    /// This is the test for the mistake that shaped the design. Styling from
    /// `textStorage(_:willProcessEditing:…)` — the obvious hook, and the one
    /// that is genuinely inside the edit — writes attributes re-entrantly, and
    /// `NSTextStorage` folds that into the edit in flight. The range AppKit is
    /// then told about is not "the character you typed" but "the block that was
    /// restyled", and `NSTextView` fixes the selection to the end of it.
    ///
    /// It is invisible with one keystroke and obvious with two: typing twelve
    /// characters into the middle of a line put one there and the other eleven
    /// at the end of the document. Only the *second* character reveals it, which
    /// is why this types a word rather than a letter.
    func testTypingAWordLeavesEveryCharacterWhereItWasTyped() throws {
        let source = "INT. ROOM - DAY\n\nMARLA\nYou said ten and it is a quarter past.\n"
        let (host, _) = makeEditor(source)
        let caret = (source as NSString).range(of: "quarter").location
        host.textView.setSelectedRange(NSRange(location: caret, length: 0))

        for character in "twenty-past-" {
            host.textView.insertText(String(character), replacementRange: host.textView.selectedRange())
        }

        XCTAssertEqual(
            host.textView.string,
            (source as NSString).replacingCharacters(
                in: NSRange(location: caret, length: 0), with: "twenty-past-"
            ),
            "the characters did not all land at the caret — styling moved it mid-word"
        )
        XCTAssertEqual(
            host.textView.selectedRange().location, caret + 12,
            "the caret should be just past what was typed"
        )
    }

    /// Rule 2, at the level this new path could break it: an entire session of
    /// typing must leave the bytes exactly as typed.
    func testLiveStylingNeverTouchesTheWritersBytes() throws {
        let source = "INT. ROOM - DAY\n\nMarla\nHello.\n"
        let (host, _) = makeEditor(source)
        let typed = "MARLA\n(quietly)\nYou said ten — “a quarter past”, even.\n"
        let caret = (source as NSString).range(of: "Marla")
        host.textView.setSelectedRange(caret)
        host.textView.insertText(typed, replacementRange: caret)

        let expected = (source as NSString).replacingCharacters(in: caret, with: typed)
        XCTAssertEqual(host.textView.string, expected)
        XCTAssertEqual(Array(host.textView.string.utf8), Array(expected.utf8))
    }
}
