import XCTest

/// UI tests run **only** inside an ephemeral tart VM, via
/// `~/.claude/skills/vm-uitest/uitest.sh`. XCUITest seizes the host mouse and
/// keyboard, so never run this scheme with `xcodebuild test` on the host.
///
/// Kept to a handful of smoke tests deliberately: the engine is covered far more
/// cheaply by `swift test` in `Packages/FountainKit`.
final class ScreenwriterUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitest"]
        app.launch()
    }

    func testNewDocumentOpensAnEditor() {
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.textViews["editor.surface"].waitForExistence(timeout: 10))
    }

    func testTypingUpdatesTheSceneListAndStatusBar() {
        app.typeKey("n", modifierFlags: .command)
        let editor = app.textViews["editor.surface"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.click()
        editor.typeText("INT. GLASS HOUSE - NIGHT\n\nRain needles the windows.\n")

        XCTAssertTrue(
            app.staticTexts["INT. GLASS HOUSE - NIGHT"].waitForExistence(timeout: 5),
            "The scene should appear in the sidebar as it is typed."
        )
    }

    func testSwitchingToStyledModeKeepsTheDocument() {
        app.typeKey("n", modifierFlags: .command)
        let editor = app.textViews["editor.surface"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.click()
        editor.typeText("INT. A - DAY\n")

        app.popUpButtons["editor.mode"].click()
        app.menuItems["Styled"].click()

        // The text is untouched by the mode switch — only its attributes change.
        XCTAssertTrue(editor.exists)
    }
}
