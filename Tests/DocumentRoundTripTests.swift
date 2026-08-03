import AppKit
import FountainKit
import XCTest
@testable import Screenwriter

/// M0's proof: a screenplay survives a full open → edit → save → reopen cycle,
/// byte for byte, in both document formats.
@MainActor
final class DocumentRoundTripTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("screenwriter-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The largest script in the reference library, if it is present on this
    /// machine. Skipped rather than failed elsewhere, so the suite stays green
    /// on a checkout without the corpus.
    private func corpusScript() throws -> String {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Code/github.com/stevemurr/screenplays/Rebase/script.fountain")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "corpus not present")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testFountainRoundTripIsByteIdentical() throws {
        let source = try corpusScript()
        let url = directory.appendingPathComponent("script.fountain")
        try source.write(to: url, atomically: true, encoding: .utf8)

        let document = ScreenplayDocument()
        try document.read(from: url, ofType: ScreenplayDocument.DocumentType.fountain.rawValue)
        document.makeWindowControllers()
        XCTAssertEqual(document.model.text, source)

        let out = directory.appendingPathComponent("out.fountain")
        try document.write(to: out, ofType: ScreenplayDocument.DocumentType.fountain.rawValue)
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), source)
    }

    func testSavingAsAPackagePutsPlainTextOnDisk() throws {
        let source = try corpusScript()
        let document = ScreenplayDocument()
        document.model.load(source)

        let package = directory.appendingPathComponent("Rebase.screenplay")
        try document.write(to: package, ofType: ScreenplayDocument.DocumentType.package.rawValue)

        // The point of the uncompressed TextBundle: the script is a plain file
        // inside a folder, so git, grep and Syncthing all see it.
        let payload = package.appendingPathComponent("text.fountain")
        XCTAssertTrue(FileManager.default.fileExists(atPath: payload.path))
        XCTAssertEqual(try String(contentsOf: payload, encoding: .utf8), source)

        let info = package.appendingPathComponent("info.json")
        let parsed = try JSONSerialization.jsonObject(
            with: Data(contentsOf: info)
        ) as? [String: Any]
        XCTAssertEqual(parsed?["version"] as? Int, 2)
        XCTAssertNotNil(parsed?[TextBundle.settingsNamespace])
    }

    func testPackageReopensWithIdenticalText() throws {
        let source = try corpusScript()
        let writer = ScreenplayDocument()
        writer.model.load(source)
        let package = directory.appendingPathComponent("Round.screenplay")
        try writer.write(to: package, ofType: ScreenplayDocument.DocumentType.package.rawValue)

        let reader = ScreenplayDocument()
        try reader.read(from: package, ofType: ScreenplayDocument.DocumentType.package.rawValue)
        reader.makeWindowControllers()
        XCTAssertEqual(reader.model.text, source)
        XCTAssertEqual(reader.model.script.scenes.count, writer.model.script.scenes.count)
    }

    func testHighlandIsNeverOpenedForWriting() throws {
        // 59 irreplaceable files depend on this staying true.
        let document = ScreenplayDocument()
        document.model.load("INT. A - DAY\n")
        XCTAssertThrowsError(
            try document.fileWrapper(ofType: ScreenplayDocument.DocumentType.highland.rawValue)
        ) { error in
            XCTAssertEqual(error as? ScreenplayDocumentError, .highlandIsReadOnly)
        }
    }

    func testWindowIsCreatedWithHostedContent() throws {
        // The M0 integration risk: SwiftUI's App lifecycle never delivered a
        // document window. Under NSApplicationMain it does, and this asserts it
        // rather than trusting a screenshot.
        let document = ScreenplayDocument()
        document.model.load("INT. A - DAY\n")
        document.makeWindowControllers()

        XCTAssertEqual(document.windowControllers.count, 1)
        let window = try XCTUnwrap(document.windowControllers.first?.window)
        XCTAssertNotNil(window.contentView)
        XCTAssertTrue(
            String(describing: type(of: window.contentView!)).contains("NSHostingView"),
            "The document window should host the SwiftUI root view."
        )
    }
}

extension ScreenplayDocumentError: Equatable {}
