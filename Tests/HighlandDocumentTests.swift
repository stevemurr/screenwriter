import FountainKit
import XCTest
@testable import Screenwriter

/// Opening a Highland document. Rule 6 is the whole test suite: 59
/// irreplaceable bundles depend on the app never writing one.
@MainActor
final class HighlandDocumentTests: XCTestCase {

    /// A real bundle from the reference library, if present.
    private func libraryBundle(_ relativePath: String) throws -> URL {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Code/github.com/stevemurr/screenplays")
            .appendingPathComponent(relativePath)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "corpus not present")
        return url
    }

    func testOpeningAHighlandBundleLoadsItsScript() throws {
        let url = try libraryBundle("Trophy Boyz Rewrite/Episode 1.highland")
        let document = ScreenplayDocument()
        try document.read(from: url, ofType: ScreenplayDocument.DocumentType.highland.rawValue)
        document.makeWindowControllers()

        XCTAssertFalse(document.model.text.isEmpty)
        XCTAssertTrue(document.model.text.contains("TROPHY BOYZ"))
    }

    func testAnImportedBundleOpensAsADraftSoSaveCannotTouchIt() throws {
        let url = try libraryBundle("Trophy Boyz Rewrite/Episode 1.highland")
        let document = ScreenplayDocument()
        try document.read(from: url, ofType: ScreenplayDocument.DocumentType.highland.rawValue)
        document.makeWindowControllers()

        // No file to save back to, and the type has already been switched to our
        // own package format — so Save is Save As, and the original is unreachable.
        XCTAssertTrue(document.isDraft)
        XCTAssertNil(document.fileURL)
        XCTAssertEqual(document.fileType, ScreenplayDocument.DocumentType.package.rawValue)
    }

    func testWritingAsHighlandIsRefusedOutright() throws {
        let document = ScreenplayDocument()
        document.model.load("INT. A - DAY\n")
        XCTAssertThrowsError(
            try document.fileWrapper(ofType: ScreenplayDocument.DocumentType.highland.rawValue)
        ) { error in
            XCTAssertEqual(error as? ScreenplayDocumentError, .highlandIsReadOnly)
        }
    }

    func testTheOriginalBundleIsUnchangedAfterOpeningAndSavingElsewhere() throws {
        let url = try libraryBundle("Trophy Boyz Rewrite/Episode 1.highland")
        let before = try Data(contentsOf: url)
        let modified = try FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate] as? Date

        let document = ScreenplayDocument()
        try document.read(from: url, ofType: ScreenplayDocument.DocumentType.highland.rawValue)
        document.makeWindowControllers()
        document.model.text += "\nAdded a line.\n"

        let elsewhere = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Episode 1 \(UUID().uuidString).screenplay")
        try document.write(
            to: elsewhere,
            ofType: ScreenplayDocument.DocumentType.package.rawValue,
            for: .saveAsOperation,
            originalContentsURL: nil
        )
        defer { try? FileManager.default.removeItem(at: elsewhere) }

        XCTAssertEqual(try Data(contentsOf: url), before, "The Highland bundle was modified.")
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date,
            modified
        )
    }

    func testTheSluglineAsSectionProblemIsVisibleOnceImported() throws {
        // This is the app's whole argument, and it is only reachable through the
        // importer: the episode's sluglines are written as sections, so the
        // parser finds no scenes and Highland printed none of them.
        let url = try libraryBundle("Trophy Boyz Rewrite/Episode 1.highland")
        let document = ScreenplayDocument()
        try document.read(from: url, ofType: ScreenplayDocument.DocumentType.highland.rawValue)
        document.makeWindowControllers()
        document.model.reparseNow()

        XCTAssertEqual(document.model.script.scenes.count, 0)
        let flagged = document.model.diagnostics.filter { $0.rule == .sluglineAsSection }
        XCTAssertGreaterThanOrEqual(flagged.count, 5)

        // And the fix is offered rather than merely reported.
        let first = try XCTUnwrap(flagged.first)
        XCTAssertTrue(first.isFixable)
        document.model.applyFix(first)
        XCTAssertEqual(document.model.script.scenes.count, 1, "Fixing one slugline should reveal one scene.")
    }
}
