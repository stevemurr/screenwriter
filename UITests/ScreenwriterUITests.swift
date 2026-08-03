import XCTest

/// UI tests run **only** inside an ephemeral tart VM, via
/// `~/.claude/skills/vm-uitest/uitest.sh`. XCUITest seizes the host mouse and
/// keyboard, so never run this scheme with `xcodebuild test` on the host.
///
/// Kept deliberately thin: the engine is covered far more cheaply by
/// `swift test` in `Packages/FountainKit`, and the editor's layout is covered
/// headlessly by `StyledModeLayoutTests`, which reads geometry back out of
/// TextKit rather than driving the UI. What is left for XCUITest is the wiring
/// between panes — the things only a running app can prove.
final class ScreenwriterUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitest"]
        app.launch()
    }

    private func newDocument() -> XCUIElement {
        app.typeKey("n", modifierFlags: .command)
        let editor = app.textViews["editor.surface"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        editor.click()
        return editor
    }

    /// Reads the status bar's scene count by identifier.
    ///
    /// Matching `app.staticTexts["2 scenes"]` by label is ambiguous — the same
    /// string is rendered in the sidebar footer and in the status bar — and an
    /// ambiguous query is a confusing way to fail.
    private func sceneCountEquals(_ expected: String, timeout: TimeInterval) -> Bool {
        // By identifier, and reading its label. The status bar carries both now;
        // the identifier alone would have matched an element whose label was
        // empty, which is precisely the state that made this unreliable.
        let element = app.staticTexts["status.scenes"]
        guard element.waitForExistence(timeout: timeout) else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element.label == expected { return true }
            usleep(200_000)
        } while Date() < deadline
        return element.label == expected
    }

    private let sample = """
    INT. GLASS HOUSE - NIGHT

    Rain needles the windows.

    LENA
    You left the lights on.

    EXT. GARDEN - NIGHT

    Owen waits among the wet sculptures.

    """

    /// Attaches the accessibility tree so a failing lookup can be diagnosed from
    /// the result bundle instead of by another three-minute guess.
    func testDumpAccessibilityTree() {
        let editor = newDocument()
        editor.typeText(sample)
        // Give the debounced reparse time to reach the status bar.
        _ = app.staticTexts["INT. GLASS HOUSE - NIGHT"].waitForExistence(timeout: 10)

        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "accessibility-tree"
        tree.lifetime = .keepAlways
        add(tree)

        let labels = app.staticTexts.allElementsBoundByIndex
            .map { "[\($0.identifier)] \($0.label)" }
            .joined(separator: "\n")
        let dump = XCTAttachment(string: labels)
        dump.name = "static-texts"
        dump.lifetime = .keepAlways
        add(dump)

        XCTAssertEqual(app.windows.count, 1, "A UI-test launch should open exactly one window.")
    }

    func testNewDocumentOpensAnEditor() {
        _ = newDocument()
    }

    func testTypingPopulatesTheSceneListAndTheStatusBar() {
        let editor = newDocument()
        editor.typeText(sample)

        // The sidebar is driven by a debounced reparse, so it appears shortly
        // after typing rather than instantly.
        XCTAssertTrue(
            app.staticTexts["INT. GLASS HOUSE - NIGHT"].waitForExistence(timeout: 10),
            "Scenes should appear in the sidebar as they are typed."
        )
        XCTAssertTrue(app.staticTexts["EXT. GARDEN - NIGHT"].exists)
        XCTAssertTrue(sceneCountEquals("2 scenes", timeout: 5))
    }

    func testSelectingASceneMovesTheCaret() {
        let editor = newDocument()
        editor.typeText(sample)

        let second = app.staticTexts["EXT. GARDEN - NIGHT"]
        XCTAssertTrue(second.waitForExistence(timeout: 10))
        second.click()

        // The caret jumps to the scene, which the status bar reports. The first
        // scene starts on line 1, so landing anywhere past it proves the jump.
        let caret = app.staticTexts["status.caret"]
        XCTAssertTrue(caret.waitForExistence(timeout: 5))
        XCTAssertFalse(
            caret.label.contains("Line 1,"),
            "Selecting the second scene should have moved the caret off line 1."
        )
    }

    func testFilteringNarrowsTheSceneList() {
        let editor = newDocument()
        editor.typeText(sample)
        XCTAssertTrue(app.staticTexts["EXT. GARDEN - NIGHT"].waitForExistence(timeout: 10))

        let filter = app.textFields["scenes.filter"]
        filter.click()
        filter.typeText("garden")
        XCTAssertTrue(app.staticTexts["EXT. GARDEN - NIGHT"].exists)
        XCTAssertFalse(app.staticTexts["INT. GLASS HOUSE - NIGHT"].exists)
    }

    func testSwitchingToStyledModeKeepsTheDocument() {
        let editor = newDocument()
        editor.typeText(sample)

        // Cmd-Shift-2 rather than the picker: "Styled" appears both in the
        // pane's menu and in the View menu, so matching it by label alone is
        // ambiguous and XCUITest refuses to guess.
        app.typeKey("2", modifierFlags: [.command, .shift])

        // Only attributes change; the text is what was typed.
        XCTAssertTrue(editor.exists)
        XCTAssertTrue(sceneCountEquals("2 scenes", timeout: 5))
    }

    func testTitlePageSheetWritesBackIntoTheSource() {
        let editor = newDocument()
        editor.typeText(sample)

        app.typeKey("t", modifierFlags: [.command, .shift])
        // Sheets are their own element class; `otherElements` does not reach the
        // hosted SwiftUI root inside one.
        let title = app.sheets.firstMatch.textFields["titlepage.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        title.click()
        title.typeText("Glass House")
        app.sheets.firstMatch.buttons["Done"].click()

        // Wait for the sheet to actually go away: while it is up it is modal,
        // and the window behind it cannot be queried.
        XCTAssertTrue(
            app.sheets.firstMatch.waitForNonExistence(timeout: 10),
            "The title page sheet did not dismiss."
        )
        XCTAssertTrue(
            sceneCountEquals("2 scenes", timeout: 10),
            "Adding a title page must not disturb the scenes below it."
        )
    }

    func testBoardModeShowsColumnsOfScenes() {
        let editor = newDocument()
        editor.typeText("""
        # Act One

        ## Arrival

        INT. GLASS HOUSE - NIGHT

        Rain needles the windows.

        ## The Test

        INT. KITCHEN - PRE-DAWN

        A kettle whistles.

        """)
        XCTAssertTrue(app.staticTexts["INT. KITCHEN - PRE-DAWN"].waitForExistence(timeout: 10))

        app.radioButtons["Board"].click()
        XCTAssertTrue(
            app.scrollViews["board.columns"].waitForExistence(timeout: 10),
            "Board mode should show the sequence columns."
        )
        // Columns come from the ## sequences, and every scene lands on a card.
        XCTAssertTrue(app.staticTexts["ARRIVAL"].exists)
        XCTAssertTrue(app.staticTexts["THE TEST"].exists)
    }

    func testSwitchingBackToWriteRestoresTheEditor() {
        let editor = newDocument()
        editor.typeText("INT. A - DAY\n\nHe waits.\n")
        XCTAssertTrue(app.staticTexts["INT. A - DAY"].waitForExistence(timeout: 10))

        app.radioButtons["Board"].click()
        XCTAssertTrue(app.scrollViews["board.columns"].waitForExistence(timeout: 10))
        app.radioButtons["Write"].click()
        XCTAssertTrue(app.textViews["editor.surface"].waitForExistence(timeout: 10))
    }

    func testPreviewPaneCanBeHidden() {
        let editor = newDocument()
        // A document with no pages shows the preview's empty state instead of a
        // scroll view, which is correct behaviour and not what this is testing.
        editor.typeText(sample)
        let preview = app.scrollViews["preview.pages"]
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        app.checkBoxes["toggle.preview"].click()
        XCTAssertFalse(preview.exists)
    }
}
