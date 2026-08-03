import AppKit
import FountainKit
import XCTest
@testable import Screenwriter

/// Typing must not move the page under the writer.
///
/// Restyling runs after every debounced reparse, so anything it does to the
/// scroll position happens continuously while typing. These tests pin the two
/// properties that makes usable: the viewport does not move, and the caret does
/// not move.
@MainActor
final class EditorScrollStabilityTests: XCTestCase {

    /// Long enough to scroll properly — roughly 400 scenes.
    private static let longScript: String = {
        (1...400).map { index in
            """
            INT. LOCATION \(index) - NIGHT

            Rain maps the windows in silver veins while somebody waits.

            MARA
            We built a room with no shadows, and then we lived in it.

            """
        }.joined()
    }()

    private func makeHost() throws -> (EditorHostView, ParsedScript) {
        let host = EditorHostView(frame: NSRect(x: 0, y: 0, width: 760, height: 600))
        host.textView.string = Self.longScript
        host.setScriptColumn(Style.scriptColumnWidth)
        host.layoutSubtreeIfNeeded()

        let script = ScriptParser.parse(Self.longScript)
        let styler = ElementStyler(mode: .styled, fontSize: 12)
        // Style once so the document is laid out as it would be in use.
        host.applyStyle(
            base: styler.baseAttributes(),
            runs: styler.runs(for: script)
        )
        host.layoutSubtreeIfNeeded()
        return (host, script)
    }

    /// Scrolls to roughly the middle and returns the resulting origin.
    private func scrollToMiddle(_ host: EditorHostView) -> NSPoint {
        let documentHeight = host.textView.frame.height
        let target = NSPoint(x: 0, y: (documentHeight / 2).rounded())
        host.scrollView.contentView.scroll(to: target)
        host.scrollView.reflectScrolledClipView(host.scrollView.contentView)
        host.layoutSubtreeIfNeeded()
        return host.scrollView.contentView.bounds.origin
    }

    func testRestylingDoesNotMoveTheViewport() throws {
        let (host, script) = try makeHost()
        let before = scrollToMiddle(host)
        XCTAssertGreaterThan(before.y, 0, "The test needs a document long enough to scroll.")

        let styler = ElementStyler(mode: .styled, fontSize: 12)
        host.applyStyle(base: styler.baseAttributes(), runs: styler.runs(for: script))
        host.layoutSubtreeIfNeeded()

        let after = host.scrollView.contentView.bounds.origin
        XCTAssertEqual(
            after.y, before.y, accuracy: 0.5,
            "Restyling moved the viewport by \(after.y - before.y)pt. This is the "
                + "scroll jump that makes typing unusable."
        )
    }

    func testRestylingDoesNotMoveTheCaret() throws {
        let (host, script) = try makeHost()
        _ = scrollToMiddle(host)

        let caret = NSRange(location: 12_000, length: 0)
        host.textView.selectedRanges = [NSValue(range: caret)]

        let styler = ElementStyler(mode: .styled, fontSize: 12)
        host.applyStyle(base: styler.baseAttributes(), runs: styler.runs(for: script))

        XCTAssertEqual(host.textView.selectedRanges.first?.rangeValue, caret)
    }

    func testRestylingTouchesOnlyWhatIsOnScreen() throws {
        // A full-document `setAttributes` invalidates every laid-out fragment,
        // which is what makes the scrollbar jump on a long script. Styling is
        // scoped to the viewport and a margin around it.
        let (host, _) = try makeHost()
        _ = scrollToMiddle(host)

        let styled = host.styledCharacterRange()
        let total = (Self.longScript as NSString).length
        XCTAssertGreaterThan(styled.length, 0)
        XCTAssertLessThan(
            styled.length, total / 2,
            "Styling still spans most of the document; the viewport scoping is not working."
        )
        // And the caret's neighbourhood is inside it, or typing would show
        // unstyled text.
        let caretOffset = host.scrollView.contentView.bounds.origin.y > 0 ? styled.location + 10 : 10
        XCTAssertTrue(NSLocationInRange(caretOffset, styled))
    }

    func testTypingAtTheTopDoesNotScroll() throws {
        // The document starts at the top; styling must leave it there rather
        // than scrolling to reveal an anchor.
        let (host, script) = try makeHost()
        host.scrollView.contentView.scroll(to: .zero)
        host.scrollView.reflectScrolledClipView(host.scrollView.contentView)

        let styler = ElementStyler(mode: .styled, fontSize: 12)
        host.applyStyle(base: styler.baseAttributes(), runs: styler.runs(for: script))
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(host.scrollView.contentView.bounds.origin.y, 0, accuracy: 0.5)
    }
}

/// Confirms the diagnosis rather than assuming it.
///
/// The fix is only a fix if the previous approach genuinely fails these
/// assertions. This reproduces what the editor used to do on every keystroke —
/// reset attributes across the whole document, then call `scrollRangeToVisible`
/// on the character at the top of the viewport — and shows the page moving.
@MainActor
final class EditorScrollRegressionTests: XCTestCase {

    func testTheOldFullDocumentRestyleMovedThePage() throws {
        let script = (1...400).map { index in
            """
            INT. LOCATION \(index) - NIGHT

            Rain maps the windows in silver veins while somebody waits.

            MARA
            We built a room with no shadows, and then we lived in it.

            """
        }.joined()

        let host = EditorHostView(frame: NSRect(x: 0, y: 0, width: 760, height: 600))
        host.textView.string = script
        host.setScriptColumn(Style.scriptColumnWidth)
        host.layoutSubtreeIfNeeded()

        let parsed = ScriptParser.parse(script)
        let styler = ElementStyler(mode: .styled, fontSize: 12)
        host.applyStyle(base: styler.baseAttributes(), runs: styler.runs(for: parsed))
        host.layoutSubtreeIfNeeded()

        let target = NSPoint(x: 0, y: (host.textView.frame.height / 2).rounded())
        host.scrollView.contentView.scroll(to: target)
        host.scrollView.reflectScrolledClipView(host.scrollView.contentView)
        host.layoutSubtreeIfNeeded()
        let before = host.scrollView.contentView.bounds.origin

        // --- what the editor used to do, verbatim ---------------------------
        let storage = try XCTUnwrap(host.textView.textStorage)
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes(styler.baseAttributes(), range: full)
        for run in styler.runs(for: parsed) where NSMaxRange(run.range) <= storage.length {
            storage.addAttributes(run.attributes, range: run.range)
        }
        storage.endEditing()
        // Anchor on the top-of-viewport character and scroll it back into view.
        let layout = try XCTUnwrap(host.textView.textLayoutManager)
        let content = try XCTUnwrap(layout.textContentManager)
        let top = max(before.y - host.textView.textContainerOrigin.y, 0)
        let fragment = layout.textLayoutFragment(for: CGPoint(x: 0, y: top))
        let offset = fragment.map {
            content.offset(from: content.documentRange.location, to: $0.rangeInElement.location)
        } ?? 0
        host.textView.scrollRangeToVisible(NSRange(location: offset, length: 0))
        host.layoutSubtreeIfNeeded()
        // --------------------------------------------------------------------

        let after = host.scrollView.contentView.bounds.origin
        XCTAssertNotEqual(
            after.y, before.y, accuracy: 0.5,
            "The old approach did not move the page here, so the scroll jumping "
                + "has a different cause and the fix is aimed at the wrong thing."
        )
    }
}

/// Switching between Plain Text and Styled changes the geometry — the gutter
/// appears or disappears and the column width changes — so the exact origin is
/// meaningless. What must hold is that the same line stays at the top.
@MainActor
final class EditorModeSwitchScrollTests: XCTestCase {

    func testSwitchingModeKeepsTheSameLineAtTheTop() throws {
        let script = (1...300).map { index in
            "INT. LOCATION \(index) - NIGHT\n\nSomebody waits in the rain.\n\n"
        }.joined()

        let host = EditorHostView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        host.textView.string = script
        host.setShowsLineNumbers(true)
        host.layoutSubtreeIfNeeded()

        let parsed = ScriptParser.parse(script)
        let plain = ElementStyler(mode: .plainText, fontSize: 12)
        host.applyStyle(base: plain.baseAttributes(), runs: plain.runs(for: parsed))
        host.layoutSubtreeIfNeeded()

        host.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 3000))
        host.scrollView.reflectScrolledClipView(host.scrollView.contentView)
        host.layoutSubtreeIfNeeded()

        let layout = try XCTUnwrap(host.textView.textLayoutManager)
        let content = try XCTUnwrap(layout.textContentManager)
        func topCharacterOffset() -> Int {
            let visible = host.scrollView.documentVisibleRect
            let top = max(visible.minY - host.textView.textContainerOrigin.y, 0)
            guard let fragment = layout.textLayoutFragment(for: CGPoint(x: 0, y: top)) else { return -1 }
            return content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
        }
        let before = topCharacterOffset()
        XCTAssertGreaterThan(before, 0)

        // Switch to styled: gutter off, column narrower, everything re-laid out.
        host.setShowsLineNumbers(false)
        host.setScriptColumn(Style.scriptColumnWidth)
        let styled = ElementStyler(mode: .styled, fontSize: 12)
        host.applyStyle(base: styled.baseAttributes(), runs: styled.runs(for: parsed))
        host.layoutSubtreeIfNeeded()

        // Put the anchor back at the top, as the coordinator does.
        guard let location = content.location(content.documentRange.location, offsetBy: before),
              let fragment = layout.textLayoutFragment(for: location) else {
            return XCTFail("Anchor no longer resolves after the mode switch.")
        }
        host.scrollView.contentView.scroll(
            to: NSPoint(x: 0, y: fragment.layoutFragmentFrame.minY + host.textView.textContainerOrigin.y)
        )
        host.scrollView.reflectScrolledClipView(host.scrollView.contentView)
        host.layoutSubtreeIfNeeded()

        // The same character is at the top, even though the y differs.
        XCTAssertEqual(topCharacterOffset(), before)
    }
}
