import AppKit
import FountainKit
import XCTest
@testable import Screenwriter

/// The `/` menu, at the level where it can actually go wrong: when it opens,
/// when it must *not*, and what the document holds afterwards.
@MainActor
final class SlashMenuTests: XCTestCase {

    private func makeEditor(_ source: String = "") -> EditorHostView {
        let host = EditorHostView(frame: NSRect(x: 0, y: 0, width: 760, height: 600))
        host.setScriptColumn(Style.scriptColumnWidth)
        host.textView.string = source
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func type(_ text: String, into host: EditorHostView) {
        for character in text {
            host.textView.insertText(String(character), replacementRange: host.textView.selectedRange())
        }
    }

    // MARK: - When it opens

    func testSlashOnAnEmptyLineOpensTheMenu() {
        let host = makeEditor("INT. ROOM - DAY\n\n")
        host.textView.setSelectedRange(NSRange(location: (host.textView.string as NSString).length, length: 0))
        type("/", into: host)
        XCTAssertTrue(host.slashMenu.isVisible)
        XCTAssertEqual(host.slashMenu.items.count, SlashCommand.all.count, "a bare / lists everything")
    }

    func testTypingFiltersAndRanksPrefixMatchesFirst() {
        let host = makeEditor("INT. ROOM - DAY\n\n")
        host.textView.setSelectedRange(NSRange(location: (host.textView.string as NSString).length, length: 0))
        type("/char", into: host)
        XCTAssertEqual(host.slashMenu.selected?.id, "character")

        // A keyword match, not a title match: "cue" is not in any title.
        host.textView.setSelectedRange(NSRange(location: (host.textView.string as NSString).length, length: 0))
        type("\n/cue", into: host)
        XCTAssertEqual(host.slashMenu.selected?.id, "character")
    }

    /// The reason the trigger is line-start-only. Both of these appear in the
    /// reference corpus, and a Notion-style trigger-anywhere opens the menu on
    /// each of them mid-word.
    func testSlashesInsideRealScreenplayTextNeverOpenIt() {
        for line in ["INT./EXT. CAR - DAY", "I/E MONTAGE IMAGE", "He looked and/or waited."] {
            let host = makeEditor("INT. ROOM - DAY\n\n")
            host.textView.setSelectedRange(
                NSRange(location: (host.textView.string as NSString).length, length: 0)
            )
            type(line, into: host)
            XCTAssertFalse(
                host.slashMenu.isVisible,
                "typing “\(line)” opened the command menu"
            )
        }
    }

    func testASpaceDismissesIt() {
        let host = makeEditor("")
        type("/", into: host)
        XCTAssertTrue(host.slashMenu.isVisible)
        type(" ", into: host)
        XCTAssertFalse(host.slashMenu.isVisible, "“/ ” is someone typing, not searching")
    }

    func testAQueryThatMatchesNothingClosesIt() {
        let host = makeEditor("")
        type("/zzzz", into: host)
        XCTAssertFalse(host.slashMenu.isVisible)
    }

    func testMovingTheCaretOffTheLineClosesIt() {
        let host = makeEditor("INT. ROOM - DAY\n\n")
        host.textView.setSelectedRange(NSRange(location: (host.textView.string as NSString).length, length: 0))
        type("/act", into: host)
        XCTAssertTrue(host.slashMenu.isVisible)
        host.textView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertFalse(host.slashMenu.isVisible)
    }

    /// Arrowing back into the middle of what was typed means editing text, not
    /// choosing from a list.
    func testCaretInsideTheQueryClosesIt() {
        let host = makeEditor("")
        type("/act", into: host)
        XCTAssertTrue(host.slashMenu.isVisible)
        host.textView.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertFalse(host.slashMenu.isVisible)
    }

    // MARK: - What it inserts

    func testCommittingReplacesTheQueryWithTheShorthand() {
        let host = makeEditor("INT. ROOM - DAY\n\n")
        let start = (host.textView.string as NSString).length
        host.textView.setSelectedRange(NSRange(location: start, length: 0))
        type("/act", into: host)

        guard let command = host.slashMenu.selected else { return XCTFail("nothing selected") }
        XCTAssertEqual(command.id, "act")
        host.commitSlashCommand(command)

        XCTAssertEqual(host.textView.string, "INT. ROOM - DAY\n\n# ")
        XCTAssertEqual(host.textView.selectedRange().location, start + 2)
        XCTAssertFalse(host.slashMenu.isVisible)
    }

    /// The two that put the caret *inside* what they inserted.
    func testWrappingCommandsLeaveTheCaretInside() {
        for (id, expected, caretFromStart) in [
            ("parenthetical", "()", 1),
            ("note", "[[]]", 2),
            ("centered", "> <", 2)
        ] {
            let host = makeEditor("")
            type("/", into: host)
            guard let command = SlashCommand.all.first(where: { $0.id == id })?.menuItem else {
                return XCTFail("no command \(id)")
            }
            host.slashMenu.select(command)
            host.commitSlashCommand(command)
            XCTAssertEqual(host.textView.string, expected, "\(id)")
            XCTAssertEqual(host.textView.selectedRange().location, caretFromStart, "\(id) caret")
        }
    }

    /// Action needs no mark, so its entry exists to say so and to clear the `/`.
    func testActionInsertsNothingAndLeavesAnEmptyLine() {
        let host = makeEditor("INT. ROOM - DAY\n\n")
        host.textView.setSelectedRange(NSRange(location: (host.textView.string as NSString).length, length: 0))
        type("/action", into: host)
        guard let command = host.slashMenu.selected, command.id == "action" else {
            return XCTFail("action not selected, got \(host.slashMenu.selected?.id ?? "nil")")
        }
        host.commitSlashCommand(command)
        XCTAssertEqual(host.textView.string, "INT. ROOM - DAY\n\n")
    }

    /// The menu is a teaching aid, so what it inserts has to be what the parser
    /// reads as the element the row named. A row that inserts something the
    /// parser classifies differently teaches the wrong thing.
    func testEveryCommandInsertsWhatTheParserReadsAsThatElement() {
        let expected: [String: ElementKind] = [
            "act": .section,
            "sequence": .section,
            "scene-int": .sceneHeading,
            "scene-ext": .sceneHeading,
            "character": .character,
            "transition": .transition,
            "centered": .centered,
            "synopsis": .synopsis,
            "note": .note,
            "lyrics": .lyrics,
            "page-break": .pageBreak
        ]

        for command in SlashCommand.all {
            guard let kind = expected[command.id] else { continue }
            // Written as a writer would leave it: the shorthand, then the text
            // they type into it, in a document with a blank line above. A page
            // break takes no text — `===` *is* the element, and `===TEXT` is a
            // synopsis, which is the parser being right rather than the row
            // being wrong.
            let body: String
            switch command.id {
            case "page-break":
                body = command.snippet
            case "note", "centered", "parenthetical":
                body = insertingText(into: command, "TEXT")
            default:
                body = command.snippet + "TEXT"
            }
            let source = "INT. ROOM - DAY\n\n\(body)\n\nAnd after.\n"
            let parsed = ScriptParser.parse(source)
            let element = parsed.elements.first { $0.range.location == (source as NSString).range(of: body).location }
            XCTAssertEqual(
                element?.kind, kind,
                "“\(body)” from the “\(command.title)” row parsed as "
                    + "\(element?.kind.rawValue ?? "nothing"), not \(kind.rawValue)"
            )
        }
    }

    private func insertingText(into command: SlashCommand, _ text: String) -> String {
        let snippet = command.snippet as NSString
        let caret = command.caretOffset ?? snippet.length
        return snippet.replacingCharacters(in: NSRange(location: caret, length: 0), with: text)
    }

    // MARK: - Keys

    func testArrowKeysMoveTheSelectionAndEscapeDismisses() {
        let host = makeEditor("")
        type("/", into: host)
        let first = host.slashMenu.selected?.id

        host.textView.doCommand(by: #selector(NSResponder.moveDown(_:)))
        XCTAssertNotEqual(host.slashMenu.selected?.id, first)
        host.textView.doCommand(by: #selector(NSResponder.moveUp(_:)))
        XCTAssertEqual(host.slashMenu.selected?.id, first)

        host.textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertFalse(host.slashMenu.isVisible)
    }

    /// The keys the menu claims must go back to the text view the moment it
    /// closes, or Return stops making new lines.
    func testReturnGoesBackToTheDocumentOnceTheMenuIsClosed() {
        let host = makeEditor("INT. ROOM - DAY\n")
        host.textView.setSelectedRange(NSRange(location: (host.textView.string as NSString).length, length: 0))
        XCTAssertFalse(host.slashMenu.isVisible)
        host.textView.insertNewline(nil)
        XCTAssertEqual(host.textView.string, "INT. ROOM - DAY\n\n")
    }

    func testReturnCommitsWhileTheMenuIsOpen() {
        let host = makeEditor("INT. ROOM - DAY\n\n")
        host.textView.setSelectedRange(NSRange(location: (host.textView.string as NSString).length, length: 0))
        type("/seq", into: host)
        host.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(host.textView.string, "INT. ROOM - DAY\n\n## ")
        XCTAssertFalse(host.slashMenu.isVisible)
    }

    // MARK: - Matching

    func testMatchingIsCaseInsensitiveAndRanked() {
        XCTAssertEqual(SlashCommand.matching("ACT").first?.id, "act")
        XCTAssertEqual(SlashCommand.matching("").count, SlashCommand.all.count)
        XCTAssertTrue(SlashCommand.matching("qqq").isEmpty)
        // Shorthand is matchable, which is how somebody who already knows
        // Fountain uses the menu without reading it.
        XCTAssertEqual(SlashCommand.matching("##").first?.id, "sequence")
    }

    func testEveryCommandHasAUniqueIDAndASymbol() {
        XCTAssertEqual(Set(SlashCommand.all.map(\.id)).count, SlashCommand.all.count)
        for command in SlashCommand.all {
            XCTAssertNotNil(
                NSImage(systemSymbolName: command.symbol, accessibilityDescription: nil),
                "“\(command.title)” names a symbol that does not exist: \(command.symbol)"
            )
        }
    }
}

extension SlashMenuTests {
    /// Typing re-ranks the list, so the highlight has to follow the ranking —
    /// until the writer takes it over with the arrow keys.
    @MainActor
    func testTheHighlightFollowsTheRankingUntilTheWriterMovesIt() {
        let host = makeEditor("")
        type("/", into: host)
        XCTAssertEqual(host.slashMenu.selected?.id, "act", "the catalogue's first row")

        type("c", into: host)
        XCTAssertEqual(
            host.slashMenu.selected?.id, "character",
            "“/c” ranks Character first, so ⏎ must insert Character — not whatever "
                + "happened to be highlighted before the filter changed"
        )

        // Now the writer chooses for themselves, and refining must not undo it.
        host.textView.doCommand(by: #selector(NSResponder.moveDown(_:)))
        let chosen = host.slashMenu.selected?.id
        XCTAssertEqual(chosen, "centered")
        type("e", into: host)
        XCTAssertEqual(host.slashMenu.selected?.id, chosen, "an explicit choice survives refining")
    }
}

/// Completion shares the `/` menu's chrome, placement and keys. What differs is
/// what a row inserts and — the part that matters when writing — what Return
/// does, because a completion appears on a line of real text.
@MainActor
final class CompletionMenuTests: XCTestCase {

    private func makeEditor(_ source: String) -> EditorHostView {
        let host = EditorHostView(frame: NSRect(x: 0, y: 0, width: 760, height: 600))
        host.setScriptColumn(Style.scriptColumnWidth)
        host.textView.string = source
        host.vocabulary = ScriptVocabulary(script: ScriptParser.parse(source))
        host.layoutSubtreeIfNeeded()
        host.textView.setSelectedRange(
            NSRange(location: (source as NSString).length, length: 0)
        )
        return host
    }

    private func type(_ text: String, into host: EditorHostView) {
        for character in text {
            host.textView.insertText(String(character), replacementRange: host.textView.selectedRange())
        }
    }

    private let script = """
    INT. DINER - NIGHT

    Rain sheets the window.

    MARLA
    You said ten.

    EXT. PARKING LOT - CONTINUOUS

    Neon.


    """

    func testTypingACueOffersTheCast() {
        let host = makeEditor(script)
        type("MAR", into: host)
        XCTAssertTrue(host.slashMenu.isVisible)
        XCTAssertEqual(host.slashMenu.selected?.title, "MARLA")
    }

    func testTypingAHeadingOffersPreviousLocations() {
        let host = makeEditor(script)
        type("INT. PARK", into: host)
        XCTAssertEqual(host.slashMenu.selected?.title, "PARKING LOT")
    }

    func testAfterTheSeparatorItOffersTimesOfDay() {
        let host = makeEditor(script)
        type("INT. DINER - NIG", into: host)
        XCTAssertEqual(host.slashMenu.selected?.title, "NIGHT")
    }

    func testTabCompletesTheLine() {
        let host = makeEditor(script)
        type("INT. PARK", into: host)
        host.textView.doCommand(by: #selector(NSResponder.insertTab(_:)))
        XCTAssertTrue(
            host.textView.string.hasSuffix("INT. PARKING LOT"),
            "got: \(host.textView.string.suffix(30).debugDescription)"
        )
        XCTAssertFalse(host.slashMenu.isVisible)
    }

    /// The rule that keeps completion out of the way: on a line of real text,
    /// Return means *new line*. A completion list that swallowed Return would
    /// turn every cue into a fight.
    func testReturnMakesANewLineRatherThanCompleting() {
        let host = makeEditor(script)
        type("MAR", into: host)
        XCTAssertTrue(host.slashMenu.isVisible)

        host.textView.insertNewline(nil)
        XCTAssertTrue(
            host.textView.string.hasSuffix("MAR\n"),
            "Return completed the word instead of breaking the line: "
                + "\(host.textView.string.suffix(12).debugDescription)"
        )
        XCTAssertFalse(host.slashMenu.isVisible)
    }

    /// …unless the writer has deliberately picked a row, at which point Return
    /// means what they just pointed at.
    func testReturnCompletesOnceARowIsChosen() {
        let host = makeEditor(script)
        type("INT. ", into: host)
        XCTAssertTrue(host.slashMenu.isVisible)
        host.textView.doCommand(by: #selector(NSResponder.moveDown(_:)))
        let chosen = host.slashMenu.selected?.title
        XCTAssertNotNil(chosen)

        host.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertTrue(host.textView.string.hasSuffix("INT. " + (chosen ?? "")))
    }

    /// Return still commits on a `/` line, where there is nothing else it could
    /// mean — the two menus differ in exactly this.
    func testReturnStillCommitsASlashCommand() {
        let host = makeEditor(script)
        type("/act", into: host)
        host.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertTrue(host.textView.string.hasSuffix("# "))
    }

    func testAnUnknownNameOffersNothing() {
        let host = makeEditor(script)
        type("ZZZ", into: host)
        XCTAssertFalse(host.slashMenu.isVisible)
    }

    /// Uppercase action is common and must not be treated as a cue just because
    /// it is uppercase. Nothing in the cast matches, so nothing is offered.
    func testUppercaseActionOffersNothing() {
        let host = makeEditor(script)
        type("THE DOOR SLAMS", into: host)
        XCTAssertFalse(host.slashMenu.isVisible)
    }

    /// Rule 2 again: completing writes the bytes the writer chose, nothing else.
    func testCompletingLeavesTheDocumentExactlyAsChosen() {
        let host = makeEditor(script)
        type("MAR", into: host)
        host.textView.doCommand(by: #selector(NSResponder.insertTab(_:)))
        XCTAssertTrue(host.textView.string.hasSuffix("MARLA"))
        XCTAssertFalse(host.textView.string.contains("MARMARLA"), "the prefix was not replaced")
    }
}
