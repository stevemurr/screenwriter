import AppKit
import FountainKit
import XCTest
@testable import Screenwriter

/// The M3 go/no-go: does TextKit 2 actually lay screenplay elements out at the
/// measured Highland indents when they are applied purely as attributes?
///
/// These tests deliberately do **not** assert on the attributes that were set —
/// that would only prove the styler agrees with itself. They read the laid-out
/// geometry back out of `NSTextLayoutManager` and assert where the glyphs
/// really landed.
@MainActor
final class StyledModeLayoutTests: XCTestCase {

    /// Covers every element kind that carries an indent.
    private let sample = """
    INT. GLASS HOUSE - NIGHT

    Rain maps the windows in silver veins.

    MARA
    We built a room with no shadows.

    LEO (O.S.)
    (quietly)
    Then why can I still see yours?

    > CUT TO:

    """

    private func host(mode: EditorMode, width: CGFloat = 760) throws -> EditorHostView {
        let host = EditorHostView(frame: NSRect(x: 0, y: 0, width: width, height: 700))
        host.textView.string = sample
        host.setShowsLineNumbers(mode == .plainText)
        host.setScriptColumn(mode == .styled ? Style.scriptColumnWidth : nil)
        host.layoutSubtreeIfNeeded()

        let script = ScriptParser.parse(sample)
        let styler = ElementStyler(mode: mode)
        let storage = try XCTUnwrap(host.textView.textStorage)
        storage.beginEditing()
        storage.setAttributes(
            styler.baseAttributes(),
            range: NSRange(location: 0, length: storage.length)
        )
        for run in styler.runs(for: script) where NSMaxRange(run.range) <= storage.length {
            storage.addAttributes(run.attributes, range: run.range)
        }
        storage.endEditing()
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// Laid-out x origin of the first text line of each paragraph, keyed by the
    /// paragraph's leading text. Read from TextKit 2's own geometry.
    private func measuredIndents(in host: EditorHostView) throws -> [String: CGFloat] {
        let layout = try XCTUnwrap(host.textView.textLayoutManager)
        let content = try XCTUnwrap(layout.textContentManager)
        layout.ensureLayout(for: layout.documentRange)

        var measured: [String: CGFloat] = [:]
        layout.enumerateTextLayoutFragments(
            from: content.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            guard let line = fragment.textLineFragments.first else { return true }
            let text = line.attributedString.string
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                // Fragment frame plus the line's own typographic origin gives the
                // real leading edge of the glyphs.
                measured[text] = fragment.layoutFragmentFrame.minX + line.typographicBounds.minX
            }
            return true
        }
        return measured
    }

    func testStyledModeLaysElementsOutAtHighlandIndents() throws {
        let host = try host(mode: .styled)
        let measured = try measuredIndents(in: host)
        let layout = PageLayout.letter

        // Indents are expressed relative to the action column, which sits at the
        // container's leading edge.
        func expected(_ kind: ElementKind) -> CGFloat {
            layout.leftEdge(for: kind) - layout.actionLeft
        }

        let action = try XCTUnwrap(measured["Rain maps the windows in silver veins."])
        let character = try XCTUnwrap(measured["MARA"])
        let dialogue = try XCTUnwrap(measured["We built a room with no shadows."])
        let parenthetical = try XCTUnwrap(measured["(quietly)"])

        // Everything is measured against action, so the assertions hold whatever
        // container inset the pane happens to have.
        XCTAssertEqual(character - action, expected(.character), accuracy: 1.0,
                       "Character cue should sit 141pt in from the action column.")
        XCTAssertEqual(dialogue - action, expected(.dialogue), accuracy: 1.0,
                       "Dialogue should sit 71pt in from the action column.")
        XCTAssertEqual(parenthetical - action, expected(.parenthetical), accuracy: 1.0,
                       "Parenthetical should sit 99pt in from the action column.")

        // The ordering that makes a page read as a screenplay at a glance.
        XCTAssertLessThan(action, dialogue)
        XCTAssertLessThan(dialogue, parenthetical)
        XCTAssertLessThan(parenthetical, character)
    }

    func testTransitionIsRightAligned() throws {
        let host = try host(mode: .styled)
        let measured = try measuredIndents(in: host)
        let action = try XCTUnwrap(measured["Rain maps the windows in silver veins."])
        let transition = try XCTUnwrap(measured["> CUT TO:"])
        XCTAssertGreaterThan(transition, action + 200,
                             "A transition should be pushed to the right margin.")
    }

    func testPlainModeAppliesNoScreenplayIndents() throws {
        let host = try host(mode: .plainText)
        let measured = try measuredIndents(in: host)
        let action = try XCTUnwrap(measured["Rain maps the windows in silver veins."])
        let character = try XCTUnwrap(measured["MARA"])
        // Plain text is source, not typesetting — every line starts at the same
        // place so the gutter's line numbers line up with what was typed.
        XCTAssertEqual(character, action, accuracy: 0.5)
    }

    func testStyledModeDoesNotAlterTheDocument() throws {
        // Rule 2: indents, colour, and dimmed marks are attributes. The user's
        // bytes are what they typed.
        let host = try host(mode: .styled)
        XCTAssertEqual(host.textView.string, sample)
    }

    func testForcedMarksAreDimmedNotRemoved() throws {
        let source = "@MARA\nHello.\n"
        let script = ScriptParser.parse(source)
        let runs = ElementStyler(mode: .styled).runs(for: script)
        // The `@` keeps its place in the text and simply recedes.
        let markRun = runs.first {
            $0.range.length == 1 && $0.range.location == 0
        }
        let colour = try XCTUnwrap(markRun?.attributes[.foregroundColor] as? NSColor)
        XCTAssertEqual(colour, Style.Element.forcingMark)
    }

    /// Writes a PNG of the styled surface when `SCREENWRITER_LAYOUT_SNAPSHOT` is
    /// set, so the layout can be eyeballed without a screen recording
    /// entitlement. Not an assertion — a way of looking at it.
    func testEmitLayoutSnapshot() throws {
        guard let path = ProcessInfo.processInfo.environment["SCREENWRITER_LAYOUT_SNAPSHOT"] else {
            throw XCTSkip("Set SCREENWRITER_LAYOUT_SNAPSHOT to write a snapshot.")
        }
        for (mode, suffix) in [(EditorMode.styled, "styled"), (EditorMode.plainText, "plain")] {
            let host = try host(mode: mode)
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            let url = URL(fileURLWithPath: path)
                .deletingPathExtension()
                .appendingPathExtension("\(suffix).png")
            try png.write(to: url)
        }
    }
}
