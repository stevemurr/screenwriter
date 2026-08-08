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

    /// The bug this replaced: "after everything in Arrival" resolved to *before
    /// the first scene of The Test*, which is one heading too far — the card
    /// landed under The Test's heading and joined the wrong column. Measured on
    /// this fixture, dropping CLIFF ROAD at the bottom of Arrival produced
    /// `Arrival [1, 2]`, `The Test [3, 4]`.
    func testDroppingBelowTheLastCardStaysInThatColumn() throws {
        let model = ScreenplayModel()
        model.load(sequenced)
        let layout = BoardLayout(script: model.script)
        let arrival = try XCTUnwrap(layout.columns.first { $0.title == "Arrival" })

        // Drag the cliff-road scene to the bottom of Arrival.
        let drop = try XCTUnwrap(layout.drop(scene: 4, into: arrival.id, at: 2))
        guard case .offset(let insertion) = drop else {
            return XCTFail("the end of a column is an offset, not a scene: \(drop)")
        }
        let range = try XCTUnwrap(SceneReorder.movableRange(ofSceneAt: 4, in: model.script))
        let edit = try XCTUnwrap(
            SceneReorder.move(range: range, to: insertion, in: model.script.source)
        )
        model.apply(edit, undoManager: nil)

        let after = BoardLayout(script: model.script)
        let updated = try XCTUnwrap(after.columns.first { $0.title == "Arrival" })
        XCTAssertEqual(
            updated.sceneIndices.count, 3,
            "the card was dropped at the bottom of Arrival and did not stay there"
        )
        XCTAssertEqual(
            model.script.scenes.first { $0.index == updated.sceneIndices.last }?.heading,
            "EXT. CLIFF ROAD - DAWN"
        )
    }

    func testDroppingOnACardLandsBeforeIt() throws {
        let layout = BoardLayout(script: ScriptParser.parse(sequenced))
        let arrival = try XCTUnwrap(layout.columns.first { $0.title == "Arrival" })
        // Scene 4 comes from another column, so there is no direction of travel:
        // a drop means "before this one" either way.
        XCTAssertEqual(layout.drop(scene: 4, into: arrival.id, at: 0), .before(scene: 1))
        XCTAssertEqual(layout.drop(scene: 4, into: arrival.id, at: 1), .before(scene: 2))
    }

    /// Dragging a card *down* one slot used to do nothing at all: "insert before
    /// the card you dropped on" is where it already was, so it sprang back.
    func testDraggingACardDownwardMovesIt() throws {
        let model = ScreenplayModel()
        model.load(sequenced)
        let layout = BoardLayout(script: model.script)
        let arrival = try XCTUnwrap(layout.columns.first { $0.title == "Arrival" })
        XCTAssertEqual(arrival.sceneIndices, [1, 2])

        // Card 1 dropped onto card 2 — one slot down, which is past it.
        let drop = try XCTUnwrap(layout.drop(scene: 1, into: arrival.id, at: 1))
        guard case .offset(let insertion) = drop else {
            return XCTFail("past the last card of the column is an offset: \(drop)")
        }
        let range = try XCTUnwrap(SceneReorder.movableRange(ofSceneAt: 1, in: model.script))
        let edit = try XCTUnwrap(
            SceneReorder.move(range: range, to: insertion, in: model.script.source)
        )
        model.apply(edit, undoManager: nil)

        XCTAssertEqual(
            model.script.scenes.prefix(2).map(\.heading),
            ["EXT. GARDEN - NIGHT", "INT. GLASS HOUSE - NIGHT"],
            "the two cards did not swap"
        )
    }

    /// Dragging *up* keeps the plain meaning, so the two directions do not both
    /// resolve to the same slot.
    func testDraggingACardUpwardInsertsBeforeIt() throws {
        let layout = BoardLayout(script: ScriptParser.parse(sequenced))
        let arrival = try XCTUnwrap(layout.columns.first { $0.title == "Arrival" })
        XCTAssertEqual(layout.drop(scene: 2, into: arrival.id, at: 0), .before(scene: 1))
        XCTAssertNil(layout.drop(scene: 1, into: arrival.id, at: 0), "onto itself")
    }

    /// An empty column advertises "Drop a scene here". It has to be true.
    func testAnEmptyColumnCanBeDroppedInto() throws {
        let source = """
        # Act One

        ## Arrival

        INT. GLASS HOUSE - NIGHT

        Rain needles the windows.

        ## Empty Beat

        # Act Two

        ## Blackout

        EXT. CLIFF ROAD - DAWN

        They drive.

        """
        let model = ScreenplayModel()
        model.load(source)
        let layout = BoardLayout(script: model.script)
        let empty = try XCTUnwrap(layout.columns.first { $0.title == "Empty Beat" })
        XCTAssertTrue(empty.sceneIndices.isEmpty)

        let drop = try XCTUnwrap(layout.drop(scene: 2, into: empty.id, at: 0))
        guard case .offset(let insertion) = drop else {
            return XCTFail("an empty column resolves to an offset: \(drop)")
        }
        let range = try XCTUnwrap(SceneReorder.movableRange(ofSceneAt: 2, in: model.script))
        let edit = try XCTUnwrap(
            SceneReorder.move(range: range, to: insertion, in: model.script.source)
        )
        model.apply(edit, undoManager: nil)

        let after = BoardLayout(script: model.script)
        XCTAssertEqual(
            after.columns.first { $0.title == "Empty Beat" }?.sceneIndices.count, 1,
            "a scene dropped into the empty column did not arrive there"
        )
    }

    /// A scene's range runs to the next *scene* heading, so a section heading
    /// between two scenes falls inside it. Dragging the last card of a column
    /// used to take the next column's heading along with it.
    func testMovingACardDoesNotCarryTheNextColumnsHeading() throws {
        let model = ScreenplayModel()
        model.load(sequenced)

        // The premise: scene 2's own range really does contain `## The Test`.
        let scene = try XCTUnwrap(model.script.scenes.first { $0.index == 2 })
        XCTAssertTrue(
            (model.text as NSString).substring(with: scene.range).contains("## The Test"),
            "this fixture no longer reproduces the overlap the test is about"
        )

        let movable = try XCTUnwrap(SceneReorder.movableRange(ofSceneAt: 2, in: model.script))
        XCTAssertFalse(
            (model.text as NSString).substring(with: movable).contains("##"),
            "the movable span still carries a section heading"
        )

        let edit = try XCTUnwrap(SceneReorder.move(sceneAt: 2, before: 1, in: model.script))
        model.apply(edit, undoManager: nil)

        // The outline is unchanged in shape: three sequences, same order.
        let after = BoardLayout(script: model.script)
        XCTAssertEqual(after.columns.map(\.title), ["Arrival", "The Test", "Blackout"])
        XCTAssertEqual(after.columns.first?.sceneIndices.count, 2)
    }

    func testMovingACardBetweenColumnsRewritesTheSource() throws {
        let model = ScreenplayModel()
        model.load(sequenced)

        let layout = BoardLayout(script: model.script)
        let theTest = try XCTUnwrap(layout.columns.first { $0.title == "The Test" })
        // Drag the cliff-road scene out of Blackout and into The Test.
        guard case .before(let target)? = layout.drop(scene: 4, into: theTest.id, at: 0) else {
            return XCTFail("dropping on the first card resolves to that card")
        }
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
