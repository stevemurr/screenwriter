import FountainKit
import XCTest
@testable import Screenwriter

/// Lint results are advice, and applying one has to be safe: a diagnostic is a
/// range into a specific parse, and the parse is debounced.
@MainActor
final class DiagnosticsTests: XCTestCase {

    func testDiagnosticsArriveWithTheParse() {
        let model = ScreenplayModel()
        // An en dash where the convention is a hyphen — 4 of these are in the
        // reference library.
        model.load("EXT. MOUNTAIN \u{2013} MORNING\n\nHigh on a peak.\n")
        XCTAssertTrue(model.diagnostics.contains { $0.rule == .sceneHeadingEnDash })
    }

    func testACleanScriptReportsNothing() {
        let model = ScreenplayModel()
        model.load("INT. KITCHEN - DAY\n\nA kettle whistles.\n\nLENA\nMorning.\n")
        XCTAssertEqual(model.diagnostics, [])
        XCTAssertEqual(model.warningCount, 0)
        XCTAssertEqual(model.suggestionCount, 0)
    }

    func testApplyingAFixRepairsTheLine() throws {
        let model = ScreenplayModel()
        model.load("EXT. MOUNTAIN \u{2013} MORNING\n\nHigh on a peak.\n")
        let diagnostic = try XCTUnwrap(
            model.diagnostics.first { $0.rule == .sceneHeadingEnDash }
        )
        XCTAssertTrue(diagnostic.isFixable)

        model.applyFix(diagnostic)
        XCTAssertTrue(model.text.contains("EXT. MOUNTAIN - MORNING"))
        XCTAssertFalse(model.text.contains("\u{2013}"))
        // The scene survives the repair.
        XCTAssertEqual(model.script.scenes.first?.heading, "EXT. MOUNTAIN - MORNING")
        XCTAssertFalse(model.diagnostics.contains { $0.rule == .sceneHeadingEnDash })
    }

    func testAStaleFixIsRefusedRatherThanAppliedAtTheWrongOffset() throws {
        // The dangerous case: the user keeps typing after the pane rendered, so
        // the diagnostic's range no longer means what it did.
        let model = ScreenplayModel()
        model.load("EXT. MOUNTAIN \u{2013} MORNING\n\nHigh on a peak.\n")
        let stale = try XCTUnwrap(
            model.diagnostics.first { $0.rule == .sceneHeadingEnDash }
        )

        // Edit ahead of the diagnostic so every offset after it shifts.
        model.text = "INT. NEW SCENE - DAY\n\nSomething else.\n\n" + model.text
        model.applyFix(stale)

        // The en dash is still there — untouched rather than mangled — because
        // the fix was re-resolved against the current parse and its old offset
        // was abandoned.
        XCTAssertTrue(model.text.contains("EXT. MOUNTAIN \u{2013} MORNING"))
        XCTAssertTrue(model.text.hasPrefix("INT. NEW SCENE - DAY"))
        XCTAssertEqual(model.script.scenes.count, 2)
    }

    func testFixingOneDiagnosticLeavesTheOthersAlone() throws {
        let model = ScreenplayModel()
        model.load("""
        EXT. MOUNTAIN \u{2013} MORNING

        High on a peak.

        EXT. LAKE \u{2013} MORNING

        A car.

        """)
        XCTAssertEqual(model.diagnostics.count { $0.rule == .sceneHeadingEnDash }, 2)

        let first = try XCTUnwrap(model.diagnostics.first { $0.rule == .sceneHeadingEnDash })
        model.applyFix(first)

        XCTAssertEqual(model.diagnostics.count { $0.rule == .sceneHeadingEnDash }, 1)
        XCTAssertTrue(model.text.contains("EXT. MOUNTAIN - MORNING"))
        XCTAssertTrue(model.text.contains("EXT. LAKE \u{2013} MORNING"))
    }

    func testTheHeadlineRuleFiresOnTheTrophyBoyzConstruction() {
        // Six episodes in the library write every slugline as a section, so
        // Highland drops all of them from the PDF. Reachable only through the
        // Highland importer, which is why this is asserted here directly.
        let model = ScreenplayModel()
        model.load("## 1. EXT. RAVINE - DAY\n\nA desolate ravine.\n")
        XCTAssertTrue(model.diagnostics.contains { $0.rule == .sluglineAsSection })
        XCTAssertEqual(model.script.scenes.count, 0, "The parser sees no scene here, which is the problem.")
    }
}
