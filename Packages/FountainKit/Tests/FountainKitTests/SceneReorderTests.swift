import Foundation
import Testing
@testable import FountainKit

/// Dragging a scene card on the Beat Board rewrites the Fountain source, so
/// these tests check the text that comes out — and, more importantly, that
/// reparsing it yields the scenes in the intended order with nothing lost.
@Suite("Scene reordering")
struct SceneReorderTests {

    /// A script with everything that hangs off a heading: a synopsis, notes,
    /// boneyard, dialogue, and a title page and section above it all.
    private let source = """
    Title: Glass House
    Author: Mara Voss

    # Act One

    INT. GLASS HOUSE - NIGHT

    = Lena searches the dark living room.

    Rain needles the windows.

    LENA
    You left the lights on.

    EXT. GARDEN - NIGHT

    [[check the sculpture continuity]]

    Owen waits among the wet sculptures.

    /*
    cut this if the act runs long
    */

    INT. KITCHEN - PRE-DAWN

    A kettle whistles.

    EXT. CLIFF ROAD - DAWN

    They drive in uneasy silence.

    """

    private func headings(of text: String) -> [String] {
        ScriptParser.parse(text).scenes.map(\.heading)
    }

    @Test("Moving a scene backwards reorders it")
    func moveBackwards() throws {
        let script = ScriptParser.parse(source)
        let edit = try #require(SceneReorder.move(sceneAt: 3, before: 1, in: script))
        let moved = SceneReorder.apply(edit, to: source)

        #expect(headings(of: moved) == [
            "INT. KITCHEN - PRE-DAWN",
            "INT. GLASS HOUSE - NIGHT",
            "EXT. GARDEN - NIGHT",
            "EXT. CLIFF ROAD - DAWN"
        ])
    }

    @Test("Moving a scene forwards reorders it")
    func moveForwards() throws {
        let script = ScriptParser.parse(source)
        let edit = try #require(SceneReorder.move(sceneAt: 1, before: 3, in: script))
        let moved = SceneReorder.apply(edit, to: source)

        #expect(headings(of: moved) == [
            "EXT. GARDEN - NIGHT",
            "INT. GLASS HOUSE - NIGHT",
            "INT. KITCHEN - PRE-DAWN",
            "EXT. CLIFF ROAD - DAWN"
        ])
    }

    @Test("Moving a scene to the end reorders it")
    func moveToEnd() throws {
        let script = ScriptParser.parse(source)
        let edit = try #require(SceneReorder.move(sceneAt: 1, before: nil, in: script))
        let moved = SceneReorder.apply(edit, to: source)
        #expect(headings(of: moved).last == "INT. GLASS HOUSE - NIGHT")
        #expect(headings(of: moved).count == 4)
    }

    @Test("A scene carries its synopsis, notes, boneyard, and dialogue with it")
    func sceneCarriesItsContents() throws {
        let script = ScriptParser.parse(source)
        let edit = try #require(SceneReorder.move(sceneAt: 2, before: 1, in: script))
        let moved = SceneReorder.apply(edit, to: source)
        let reparsed = ScriptParser.parse(moved)

        // The garden scene is now first and must still own everything that was
        // written under it.
        let garden = try #require(reparsed.scenes.first)
        #expect(garden.heading == "EXT. GARDEN - NIGHT")
        let block = (moved as NSString).substring(with: garden.range)
        #expect(block.contains("check the sculpture continuity"))
        #expect(block.contains("Owen waits among the wet sculptures."))
        #expect(block.contains("cut this if the act runs long"))
    }

    @Test("Everything above the first scene stays put")
    func frontMatterIsNotMoved() throws {
        let script = ScriptParser.parse(source)
        let edit = try #require(SceneReorder.move(sceneAt: 4, before: 1, in: script))
        let moved = SceneReorder.apply(edit, to: source)
        let reparsed = ScriptParser.parse(moved)

        #expect(reparsed.titlePage?.title == "Glass House")
        #expect(reparsed.sections.map(\.title) == ["Act One"])
        // The title page must still be the very first thing in the file.
        #expect(moved.hasPrefix("Title: Glass House"))
    }

    @Test("Nothing is lost or duplicated")
    func contentIsConserved() throws {
        let script = ScriptParser.parse(source)
        let edit = try #require(SceneReorder.move(sceneAt: 3, before: 2, in: script))
        let moved = SceneReorder.apply(edit, to: source)

        // Compare the multiset of non-blank lines: a move reorders, it never
        // adds, drops, or duplicates a line.
        func lines(_ text: String) -> [String] {
            text.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .sorted()
        }
        #expect(lines(moved) == lines(source))
    }

    @Test("Scenes stay separated by exactly one blank line")
    func separationIsNormalised() throws {
        let script = ScriptParser.parse(source)
        let edit = try #require(SceneReorder.move(sceneAt: 3, before: 1, in: script))
        let moved = SceneReorder.apply(edit, to: source)
        // Welding two scenes together would change what the parser sees; an
        // ever-growing gap would slowly wreck the document over many drags.
        #expect(!moved.contains("\n\n\n"))
        for heading in headings(of: moved).dropFirst() {
            #expect(moved.contains("\n\n\(heading)"))
        }
    }

    @Test("A move that changes nothing is refused")
    func noOpsAreRefused() {
        let script = ScriptParser.parse(source)
        // Dropped on itself.
        #expect(SceneReorder.move(sceneAt: 2, before: 2, in: script) == nil)
        // Dropped immediately before the scene that already follows it.
        #expect(SceneReorder.move(sceneAt: 1, before: 1, in: script) == nil)
        // The last scene dragged to the end.
        #expect(SceneReorder.move(sceneAt: 4, before: nil, in: script) == nil)
        // Scenes that do not exist.
        #expect(SceneReorder.move(sceneAt: 99, before: 1, in: script) == nil)
        #expect(SceneReorder.move(sceneAt: 1, before: 99, in: script) == nil)
    }

    @Test("The edit reports where the moved block ends up")
    func resultingOffsetLocatesTheBlock() throws {
        let script = ScriptParser.parse(source)
        for (from, to) in [(3, 1), (1, 3), (4, 2), (2, 4)] {
            let edit = try #require(SceneReorder.move(sceneAt: from, before: to, in: script))
            let moved = SceneReorder.apply(edit, to: source)
            let expected = script.scenes.first { $0.index == from }?.heading
            let landed = (moved as NSString)
                .substring(from: edit.resultingOffset)
                .prefix { $0 != "\n" }
            #expect(
                String(landed) == expected,
                "Moving \(from) before \(to) reported the wrong resulting offset."
            )
        }
    }

    @Test("Whole sections move with everything beneath them")
    func sectionMove() throws {
        let twoActs = """
        # Act One

        INT. A - DAY

        First.

        # Act Two

        INT. B - DAY

        Second.

        """
        let script = ScriptParser.parse(twoActs)
        let actTwo = try #require(script.sections.last)
        let actOne = try #require(script.sections.first)
        let edit = try #require(
            SceneReorder.move(section: actTwo, before: actOne, in: script)
        )
        let moved = SceneReorder.apply(edit, to: twoActs)
        let reparsed = ScriptParser.parse(moved)
        #expect(reparsed.sections.map(\.title) == ["Act Two", "Act One"])
        #expect(reparsed.scenes.map(\.heading) == ["INT. B - DAY", "INT. A - DAY"])
    }
}
