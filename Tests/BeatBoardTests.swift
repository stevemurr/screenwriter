import FountainKit
import XCTest
@testable import Screenwriter

/// The board is a view of the script, not a store beside it, so a drop has to
/// land the scene in the right place in the *text*. These tests exercise that
/// without a drag.
@MainActor
final class BeatBoardTests: XCTestCase {

    /// The shape the corpus uses: acts over beats over scenes.
    private let sequenced = """
    # Act One

    ## Arrival

    INT. GLASS HOUSE - NIGHT

    Rain needles the windows.

    EXT. GARDEN - NIGHT

    Owen waits.

    ## The Test

    INT. KITCHEN - PRE-DAWN

    A kettle whistles.

    # Act Two

    ## Blackout

    EXT. CLIFF ROAD - DAWN

    They drive.

    """

    func testColumnsComeFromTheDeepestSectionsThatHoldScenes() {
        let layout = BoardLayout(script: ScriptParser.parse(sequenced))
        // The `##` beats are the sequences, not the `#` acts above them.
        XCTAssertEqual(layout.columns.map(\.title), ["Arrival", "The Test", "Blackout"])
        XCTAssertEqual(layout.columns.first?.sceneIndices, [1, 2])
        XCTAssertEqual(layout.columns.last?.sceneIndices, [4])
    }

    func testAScriptWithOnlyTopLevelSectionsUsesThose() {
        let source = """
        # Act One

        INT. A - DAY

        First.

        # Act Two

        INT. B - DAY

        Second.

        """
        let layout = BoardLayout(script: ScriptParser.parse(source))
        XCTAssertEqual(layout.columns.map(\.title), ["Act One", "Act Two"])
    }

    func testAScriptWithNoSectionsStillGetsABoard() {
        // Several scripts in the library have no sections at all. A board with
        // no columns would simply be broken.
        let layout = BoardLayout(script: ScriptParser.parse("INT. A - DAY\n\nHe waits.\n"))
        XCTAssertEqual(layout.columns.count, 1)
        XCTAssertEqual(layout.columns.first?.title, "All Scenes")
        XCTAssertEqual(layout.columns.first?.sceneIndices, [1])
    }

    func testScenesAboveTheFirstSectionAreStillReachable() throws {
        let source = """
        INT. COLD OPEN - NIGHT

        Before any section.

        # Act One

        ## Arrival

        INT. A - DAY

        After.

        """
        let layout = BoardLayout(script: ScriptParser.parse(source))
        let loose = try XCTUnwrap(layout.columns.first { $0.isUnsequenced })
        XCTAssertEqual(loose.title, "Unsequenced")
        XCTAssertEqual(loose.sceneIndices, [1])
    }

    func testDroppingPastTheLastCardLandsBeforeTheNextColumn() throws {
        let script = ScriptParser.parse(sequenced)
        let layout = BoardLayout(script: script)
        let arrival = try XCTUnwrap(layout.columns.first)

        // "After everything in Arrival" is, in document order, immediately
        // before the first scene of The Test — not the end of the script.
        XCTAssertEqual(layout.destination(dropInto: arrival.id, at: 2), 3)
        // And past the last card of the last column really is the end.
        let blackout = try XCTUnwrap(layout.columns.last)
        XCTAssertNil(layout.destination(dropInto: blackout.id, at: 1))
    }

    func testDroppingOnACardLandsBeforeIt() throws {
        let layout = BoardLayout(script: ScriptParser.parse(sequenced))
        let arrival = try XCTUnwrap(layout.columns.first)
        XCTAssertEqual(layout.destination(dropInto: arrival.id, at: 0), 1)
        XCTAssertEqual(layout.destination(dropInto: arrival.id, at: 1), 2)
    }

    func testMovingACardBetweenColumnsRewritesTheSource() throws {
        let model = ScreenplayModel()
        model.load(sequenced)

        let layout = BoardLayout(script: model.script)
        let theTest = try XCTUnwrap(layout.columns.first { $0.title == "The Test" })
        // Drag the cliff-road scene out of Blackout and into The Test.
        let target = layout.destination(dropInto: theTest.id, at: 0)
        let edit = try XCTUnwrap(
            SceneReorder.move(sceneAt: 4, before: target, in: model.script)
        )
        model.apply(edit, undoManager: nil)

        XCTAssertEqual(
            model.script.scenes.map(\.heading),
            [
                "INT. GLASS HOUSE - NIGHT",
                "EXT. GARDEN - NIGHT",
                "EXT. CLIFF ROAD - DAWN",
                "INT. KITCHEN - PRE-DAWN"
            ]
        )
        // And the board reflects it: the scene now belongs to The Test.
        let moved = BoardLayout(script: model.script)
        let updated = try XCTUnwrap(moved.columns.first { $0.title == "The Test" })
        XCTAssertTrue(updated.sceneIndices.contains(3))
    }

    func testAMoveIsASingleUndoStep() throws {
        let model = ScreenplayModel()
        model.load(sequenced)
        let before = model.text

        // Grouping is explicit here because there is no run loop to close an
        // event-based group; the app gets that for free from AppKit.
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        let edit = try XCTUnwrap(SceneReorder.move(sceneAt: 3, before: 1, in: model.script))
        undoManager.beginUndoGrouping()
        model.apply(edit, undoManager: undoManager)
        undoManager.endUndoGrouping()
        XCTAssertNotEqual(model.text, before)
        XCTAssertTrue(undoManager.canUndo)

        // One press puts back both the text and, by extension, the board.
        undoManager.undo()
        XCTAssertEqual(model.text, before)
        XCTAssertEqual(model.script.scenes.first?.heading, "INT. GLASS HOUSE - NIGHT")

        undoManager.redo()
        XCTAssertEqual(model.script.scenes.first?.heading, "INT. KITCHEN - PRE-DAWN")
    }

    func testMetadataFollowsACardAcrossTheBoard() throws {
        let model = ScreenplayModel()
        model.load(sequenced)
        model.updateSceneMetadata(forSceneAt: 4) { $0.status = .locked }

        let edit = try XCTUnwrap(SceneReorder.move(sceneAt: 4, before: 1, in: model.script))
        model.apply(edit, undoManager: nil)

        XCTAssertEqual(model.script.scenes.first?.heading, "EXT. CLIFF ROAD - DAWN")
        XCTAssertEqual(model.sceneMetadata(forSceneAt: 1)?.status, .locked)
    }

    func testEverySceneAppearsOnTheBoardExactlyOnce() {
        // A card that vanishes, or shows up twice, is the failure mode that
        // would make the board untrustworthy.
        for source in [sequenced, "INT. A - DAY\n\nOne.\n", "# Only a section\n"] {
            let script = ScriptParser.parse(source)
            let placed = BoardLayout(script: script).columns.flatMap(\.sceneIndices)
            XCTAssertEqual(placed.sorted(), script.scenes.map(\.index).sorted())
            XCTAssertEqual(Set(placed).count, placed.count, "A scene appeared on two cards.")
        }
    }
}
