import FountainKit
import XCTest
@testable import Screenwriter

/// Production data lives in a sidecar and is re-attached to scenes on every
/// parse. These tests exercise that through the document, which is where the
/// two halves meet.
@MainActor
final class MetadataIntegrationTests: XCTestCase {
    private var directory: URL!

    private let source = """
    INT. GLASS HOUSE - NIGHT #1#

    Rain needles the windows.

    EXT. GARDEN - NIGHT #2#

    Owen waits among the wet sculptures.

    INT. KITCHEN - PRE-DAWN #3#

    A kettle whistles.

    """

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("screenwriter-metadata-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRecordingMetadataCreatesASidecarBesideTheScript() throws {
        let url = directory.appendingPathComponent("Glass House.fountain")
        try source.write(to: url, atomically: true, encoding: .utf8)

        let document = ScreenplayDocument()
        try document.read(from: url, ofType: ScreenplayDocument.DocumentType.fountain.rawValue)
        document.makeWindowControllers()

        document.model.updateSceneMetadata(forSceneAt: 2) { record in
            record.status = .revised
            record.shootingDay = 7
        }
        try document.write(
            to: url,
            ofType: ScreenplayDocument.DocumentType.fountain.rawValue,
            for: .saveOperation,
            originalContentsURL: nil
        )

        // Plain text beside plain text, so git and Syncthing both see it.
        let sidecar = directory.appendingPathComponent("Glass House.screenwriter.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
        let json = try String(contentsOf: sidecar, encoding: .utf8)
        XCTAssertTrue(json.contains("\"shootingDay\""))

        // The screenplay itself is untouched by any of it.
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), source)
    }

    func testMetadataFollowsASceneThroughAReorder() throws {
        let url = directory.appendingPathComponent("Reorder.fountain")
        try source.write(to: url, atomically: true, encoding: .utf8)

        let document = ScreenplayDocument()
        try document.read(from: url, ofType: ScreenplayDocument.DocumentType.fountain.rawValue)
        document.makeWindowControllers()
        let model = document.model

        model.updateSceneMetadata(forSceneAt: 3) { $0.shootingDay = 7 }
        model.updateSceneMetadata(forSceneAt: 1) { $0.shootingDay = 1 }

        // Drag the kitchen scene to the front, exactly as the Beat Board would.
        let edit = try XCTUnwrap(
            SceneReorder.move(sceneAt: 3, before: 1, in: model.script)
        )
        model.text = SceneReorder.apply(edit, to: model.text)
        model.reparseNow()

        XCTAssertEqual(model.script.scenes.first?.heading, "INT. KITCHEN - PRE-DAWN")
        // The shooting day travelled with the scene rather than staying at
        // position three.
        XCTAssertEqual(model.sceneMetadata(forSceneAt: 1)?.shootingDay, 7)
        XCTAssertEqual(model.sceneMetadata(forSceneAt: 2)?.shootingDay, 1)
        XCTAssertEqual(model.matchTier(forSceneAt: 1), .sceneNumber)
    }

    func testMetadataSurvivesCloseAndReopen() throws {
        let url = directory.appendingPathComponent("Persist.fountain")
        try source.write(to: url, atomically: true, encoding: .utf8)

        let writer = ScreenplayDocument()
        try writer.read(from: url, ofType: ScreenplayDocument.DocumentType.fountain.rawValue)
        writer.makeWindowControllers()
        writer.model.updateSceneMetadata(forSceneAt: 2) { record in
            record.status = .locked
            record.location = SceneLocation(name: "Glass House", interiorExterior: .exterior)
        }
        try writer.write(
            to: url,
            ofType: ScreenplayDocument.DocumentType.fountain.rawValue,
            for: .saveOperation,
            originalContentsURL: nil
        )

        let reader = ScreenplayDocument()
        try reader.read(from: url, ofType: ScreenplayDocument.DocumentType.fountain.rawValue)
        reader.makeWindowControllers()
        let record = try XCTUnwrap(reader.model.sceneMetadata(forSceneAt: 2))
        XCTAssertEqual(record.status, .locked)
        XCTAssertEqual(record.location?.name, "Glass House")
        XCTAssertEqual(record.location?.interiorExterior, .exterior)
    }

    func testAScriptWithNoMetadataWritesNoSidecar() throws {
        // Do not litter the user's folders with an empty JSON file beside every
        // script they merely open.
        let url = directory.appendingPathComponent("Untouched.fountain")
        try source.write(to: url, atomically: true, encoding: .utf8)

        let document = ScreenplayDocument()
        try document.read(from: url, ofType: ScreenplayDocument.DocumentType.fountain.rawValue)
        document.makeWindowControllers()
        try document.write(
            to: url,
            ofType: ScreenplayDocument.DocumentType.fountain.rawValue,
            for: .saveOperation,
            originalContentsURL: nil
        )

        let sidecar = directory.appendingPathComponent("Untouched.screenwriter.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
    }

    func testADamagedSidecarDoesNotBlockOpeningTheScript() throws {
        let url = directory.appendingPathComponent("Damaged.fountain")
        try source.write(to: url, atomically: true, encoding: .utf8)
        try "{ this is not json".write(
            to: directory.appendingPathComponent("Damaged.screenwriter.json"),
            atomically: true,
            encoding: .utf8
        )

        let document = ScreenplayDocument()
        try document.read(from: url, ofType: ScreenplayDocument.DocumentType.fountain.rawValue)
        document.makeWindowControllers()

        // The screenplay opens; the metadata is simply empty.
        XCTAssertEqual(document.model.script.scenes.count, 3)
        XCTAssertTrue(document.model.metadata.scenes.isEmpty)
    }
}
