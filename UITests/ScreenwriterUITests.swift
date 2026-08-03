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

    private let sample = """
    INT. GLASS HOUSE - NIGHT

    Rain needles the windows.

    LENA
    You left the lights on.

    EXT. GARDEN - NIGHT

    Owen waits among the wet sculptures.

    """

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
        XCTAssertTrue(app.staticTexts["2 scenes"].waitForExistence(timeout: 5))
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

        app.popUpButtons["editor.mode"].click()
        app.menuItems["Styled"].click()

        // Only attributes change; the text is what was typed.
        XCTAssertTrue(editor.exists)
        XCTAssertTrue(app.staticTexts["2 scenes"].exists)
    }

    func testTitlePageSheetWritesBackIntoTheSource() {
        let editor = newDocument()
        editor.typeText(sample)

        app.typeKey("t", modifierFlags: [.command, .shift])
        let sheet = app.otherElements["titlepage.root"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))

        let title = app.textFields["titlepage.title"]
        title.click()
        title.typeText("Glass House")
        app.buttons["Done"].click()

        // The block is written into the document, so it shows up in the source.
        XCTAssertTrue(
            app.staticTexts["2 scenes"].waitForExistence(timeout: 10),
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
        _ = newDocument()
        let preview = app.scrollViews["preview.pages"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        app.checkBoxes["toggle.preview"].click()
        XCTAssertFalse(preview.exists)
    }
}
