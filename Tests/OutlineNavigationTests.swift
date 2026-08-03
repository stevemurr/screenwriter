import FountainKit
import XCTest
@testable import Screenwriter

/// The sidebar is a navigator, not a read-only outline: selecting something has
/// to land the caret in the right place.
@MainActor
final class OutlineNavigationTests: XCTestCase {

    /// The shape `Anal Informant` uses — acts over beats over scenes.
    private let source = """
    # Act One

    ## Beat 1

    EXT. MOUNTAIN - MORNING #1#

    = A car crosses the valley.

    High on a peak.

    MARA
    We're late.

    ## Beat 2

    EXT. LAKE - MORNING #2#

    A car.

    ELIAS
    Not yet.

    # Act Two

    INT. HOUSE - DAY

    """

    func testSelectingASceneLandsOnItsHeading() throws {
        let script = ScriptParser.parse(source)
        let scene = try XCTUnwrap(script.scenes.first { $0.number == "2" })
        let offset = try XCTUnwrap(OutlineSelection.scene(scene.index).sourceOffset(in: script))
        let line = (source as NSString).substring(from: offset).prefix(while: { $0 != "\n" })
        XCTAssertEqual(String(line), "EXT. LAKE - MORNING #2#")
    }

    func testSelectingASectionLandsOnItsHeader() throws {
        let script = ScriptParser.parse(source)
        let beatTwo = try XCTUnwrap(
            script.elements.enumerated().first {
                $0.element.kind == .section && $0.element.text == "Beat 2"
            }
        )
        let offset = try XCTUnwrap(
            OutlineSelection.section(beatTwo.offset).sourceOffset(in: script)
        )
        let line = (source as NSString).substring(from: offset).prefix(while: { $0 != "\n" })
        XCTAssertEqual(String(line), "## Beat 2")
    }

    func testSelectingACharacterLandsOnTheirFirstCue() throws {
        let script = ScriptParser.parse(source)
        let offset = try XCTUnwrap(OutlineSelection.character("ELIAS").sourceOffset(in: script))
        let line = (source as NSString).substring(from: offset).prefix(while: { $0 != "\n" })
        XCTAssertEqual(String(line), "ELIAS")
    }

    func testAStaleSelectionResolvesToNothingRatherThanTheWrongPlace() {
        // Reparsing is debounced, so the sidebar can briefly hold a selection
        // the current parse no longer contains. Landing the caret somewhere
        // arbitrary would be worse than not moving it.
        let script = ScriptParser.parse(source)
        XCTAssertNil(OutlineSelection.scene(999).sourceOffset(in: script))
        XCTAssertNil(OutlineSelection.section(9999).sourceOffset(in: script))
        XCTAssertNil(OutlineSelection.character("NOBODY").sourceOffset(in: script))
        // An element index that exists but is not a section must not resolve.
        let actionIndex = try? XCTUnwrap(
            script.elements.firstIndex { $0.kind == .action }
        )
        if let actionIndex {
            XCTAssertNil(OutlineSelection.section(actionIndex).sourceOffset(in: script))
        }
    }

    func testOutlineTreeMatchesTheDocumentStructure() throws {
        let script = ScriptParser.parse(source)
        XCTAssertEqual(script.sections.map(\.title), ["Act One", "Act Two"])
        let actOne = try XCTUnwrap(script.sections.first)
        XCTAssertEqual(actOne.children.map(\.title), ["Beat 1", "Beat 2"])
        // Scenes attribute to the deepest section containing them, so an act
        // does not double-count what its beats already own.
        XCTAssertEqual(actOne.sceneIndices, [])
        XCTAssertEqual(actOne.children.first?.sceneIndices, [1])
        XCTAssertEqual(actOne.children.last?.sceneIndices, [2])
    }

    func testNavigatorPlacesScenesUnderTheirSequences() throws {
        let tree = OutlineTree.make(from: ScriptParser.parse(source))
        let actOne = try XCTUnwrap(section(named: "Act One", in: tree))
        let beatOne = try XCTUnwrap(section(named: "Beat 1", in: actOne.children))
        let beatTwo = try XCTUnwrap(section(named: "Beat 2", in: actOne.children))

        XCTAssertEqual(sceneIndices(in: beatOne.children), [1])
        XCTAssertEqual(sceneIndices(in: beatTwo.children), [2])
        XCTAssertEqual(sceneIndices(in: tree, recursively: true), [1, 2, 3])
    }

    func testNavigatorAssignsADeepSceneOnlyToItsDeepestSection() throws {
        let deepSource = """
        # Act One

        ## Sequence One

        ### Beat One

        INT. LAB - NIGHT

        The test begins.

        """
        let tree = OutlineTree.make(from: ScriptParser.parse(deepSource))
        let act = try XCTUnwrap(section(named: "Act One", in: tree))
        let sequence = try XCTUnwrap(section(named: "Sequence One", in: act.children))
        let beat = try XCTUnwrap(section(named: "Beat One", in: sequence.children))

        XCTAssertEqual(sceneIndices(in: beat.children), [1])
        XCTAssertEqual(sceneIndices(in: tree, recursively: true), [1])
        XCTAssertEqual(act.sceneCount, 1)
    }

    func testFilteringKeepsTheMatchingScenesAncestorPath() throws {
        let tree = OutlineTree.make(from: ScriptParser.parse(source))
        let filtered = OutlineTree.filter(tree, matchingSceneIndices: [2])
        let actOne = try XCTUnwrap(section(named: "Act One", in: filtered))

        XCTAssertNil(section(named: "Beat 1", in: actOne.children))
        let beatTwo = try XCTUnwrap(section(named: "Beat 2", in: actOne.children))
        XCTAssertEqual(sceneIndices(in: beatTwo.children), [2])
        XCTAssertNil(section(named: "Act Two", in: filtered))
    }

    func testJumpTokenChangesEvenWhenJumpingToTheSameOffset() {
        // Clicking the same scene twice must still scroll back to it.
        let session = FountainEditorSession()
        session.jump(to: 42)
        let first = session.state.pendingJump
        session.jump(to: 42)
        XCTAssertNotEqual(session.state.pendingJump, first)
        XCTAssertEqual(session.state.pendingJump?.offset, 42)
    }

    private func section(
        named title: String,
        in items: [OutlineTreeItem]
    ) -> OutlineTreeItem? {
        items.first { item in
            guard case .section(let node) = item.content else { return false }
            return node.title == title
        }
    }

    private func sceneIndices(
        in items: [OutlineTreeItem],
        recursively: Bool = false
    ) -> [Int] {
        items.flatMap { item -> [Int] in
            switch item.content {
            case .scene(let scene):
                return [scene.index]
            case .section:
                return recursively ? sceneIndices(in: item.children, recursively: true) : []
            }
        }
    }
}
