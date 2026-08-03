import FountainKit
import XCTest
@testable import Screenwriter

/// App-level tests use XCTest, matching every other XcodeGen app here. The
/// engine's own tests live in `Packages/FountainKit` and run under
/// swift-testing via `swift test`.
@MainActor
final class ScreenplayModelTests: XCTestCase {

    func testTextChangeReparsesAndBumpsRevision() {
        let model = ScreenplayModel()
        let before = model.revision
        model.text = "INT. KITCHEN - DAY\n\nA kettle whistles.\n"
        // Editing schedules a debounced reparse off the main actor, so the test
        // drives it rather than sleeping.
        model.reparseNow()
        XCTAssertEqual(model.script.scenes.count, 1)
        XCTAssertEqual(model.script.scenes.first?.heading, "INT. KITCHEN - DAY")
        XCTAssertGreaterThan(model.revision, before)
    }

    func testEditDoesNotParseSynchronously() {
        // Typing must not pay for a parse inline; at ~15ms on the largest script
        // in the reference library that would drop frames.
        let model = ScreenplayModel()
        model.load("INT. A - DAY\n")
        let revision = model.revision
        model.text = "INT. A - DAY\n\nHe waits.\n"
        XCTAssertEqual(model.revision, revision, "The parse should not have run yet.")
        XCTAssertEqual(model.script.source, "INT. A - DAY\n")
    }

    func testLoadBumpsReplacementTokenButEditDoesNot() {
        let model = ScreenplayModel()
        let token = model.replacementToken
        model.load("INT. A - DAY\n")
        XCTAssertGreaterThan(model.replacementToken, token)

        // A user edit must not look like an external replacement, or the editor
        // surface would reset undo underneath the caret.
        let afterLoad = model.replacementToken
        model.text += "He waits.\n"
        XCTAssertEqual(model.replacementToken, afterLoad)
    }

    func testIdenticalTextDoesNotReparse() {
        let model = ScreenplayModel()
        model.text = "INT. A - DAY\n"
        let revision = model.revision
        model.text = "INT. A - DAY\n"
        XCTAssertEqual(model.revision, revision)
    }
}

final class TextBundleRoundTripTests: XCTestCase {

    func testUnknownSidecarsSurviveARoundTrip() throws {
        // The whole point of the format: another app's state must come back out
        // exactly as it went in.
        let bundle = TextBundle(
            text: "INT. A - DAY\n",
            textFileName: "text.fountain",
            infoData: Data(#"{"version":2,"custom":true}"#.utf8),
            extras: [
                "characters.json": Data("[]".utf8),
                "assets/poster.png": Data([0x89, 0x50, 0x4E, 0x47])
            ]
        )

        let reread = try TextBundle(directory: bundle.directoryWrapper())
        XCTAssertEqual(reread.text, "INT. A - DAY\n")
        XCTAssertEqual(reread.textFileName, "text.fountain")
        XCTAssertEqual(reread.infoData, bundle.infoData)
        XCTAssertEqual(reread.extras["characters.json"], Data("[]".utf8))
        // Nested paths must not be flattened into a filename containing a slash.
        XCTAssertEqual(reread.extras["assets/poster.png"], Data([0x89, 0x50, 0x4E, 0x47]))
    }

    func testLegacyMarkdownPayloadKeepsItsName() throws {
        // 19 of the 59 bundles in the reference library use `text.md`. Writing
        // one back must not silently rename it.
        let original = TextBundle(text: "INT. A - DAY\n", textFileName: "text.md")
        let reread = try TextBundle(directory: original.directoryWrapper())
        XCTAssertEqual(reread.textFileName, "text.md")
    }
}
