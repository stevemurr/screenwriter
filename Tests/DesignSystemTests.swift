import AppKit
import FountainKit
import SwiftUI
import XCTest
@testable import Screenwriter

/// Holds the design pass's decisions to account.
///
/// A visual change cannot be asserted pixel-for-pixel, but the rules it is built
/// on can: which surfaces adapt to appearance, which deliberately do not, and
/// that the navigator still accounts for every scene in scripts of every shape
/// the reference library actually contains.
@MainActor
final class DesignSystemTests: XCTestCase {

    /// Chrome tracks light and dark; nothing here may be a fixed colour.
    func testSemanticSurfacesAreSystemColours() {
        let surfaces: [(String, NSColor)] = [
            ("editorBackground", Style.editorBackground),
            ("chromeBackground", Style.chromeBackground),
            ("paneBackground", Style.paneBackground),
            ("sidebarBackground", Style.sidebarBackground),
            ("inspectorBackground", Style.inspectorBackground),
            ("canvasBackground", Style.canvasBackground),
            ("elevatedBackground", Style.elevatedBackground),
            ("separator", Style.separator)
        ]
        for (name, colour) in surfaces {
            // A system colour resolves differently per appearance; a literal one
            // returns the same components in both, which is the thing to catch.
            let light = colour.usingColorSpace(.sRGB)
            XCTAssertNotNil(light, "\(name) did not resolve.")
            XCTAssertTrue(
                colour.type == .catalog,
                "\(name) is a fixed colour, so it will not follow the system appearance."
            )
        }
    }

    /// The two exceptions, and why.
    func testPaperColoursAreDeliberatelyFixed() {
        // A screenplay page and a beat card are paper in both appearances, the
        // same way the exported PDF is. These are the only colours in the app
        // that must not adapt.
        let paper = NSColor(Style.paper).usingColorSpace(.sRGB)
        let ink = NSColor(Style.paperInk).usingColorSpace(.sRGB)
        XCTAssertNotNil(paper)
        XCTAssertNotNil(ink)
        XCTAssertGreaterThan(paper?.brightnessComponent ?? 0, 0.9, "Paper should be near-white.")
        XCTAssertLessThan(ink?.brightnessComponent ?? 1, 0.2, "Ink should be near-black.")
    }

    /// Both the page preview and the beat board draw on paper, and they must
    /// draw on the *same* paper — two near-white constants that drift apart is
    /// exactly what a shared token prevents.
    func testOnlyOnePaperColourIsDefined() throws {
        let sources = ["Sources/Preview/PagePreview.swift", "Sources/BeatBoard/BeatBoardView.swift"]
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for path in sources {
            let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertFalse(
                text.contains("Color(red:"),
                "\(path) defines a literal colour; use a token in Style instead."
            )
        }
    }
}

/// The navigator's structure, against the shapes the reference library really
/// contains rather than only synthetic ones.
@MainActor
final class OutlineTreeCorpusTests: XCTestCase {

    private func corpusScripts() throws -> [(String, ParsedScript)] {
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Code/github.com/stevemurr/screenplays")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: root.path), "corpus not present")

        var scripts: [(String, ParsedScript)] = []
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "fountain",
                  let text = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            scripts.append((url.lastPathComponent, ScriptParser.parse(text)))
        }
        XCTAssertFalse(scripts.isEmpty)
        return scripts
    }

    private func scenes(in items: [OutlineTreeItem]) -> [Int] {
        items.flatMap { item -> [Int] in
            switch item.content {
            case .scene(let scene): return [scene.index] + scenes(in: item.children)
            case .section: return scenes(in: item.children)
            }
        }
    }

    func testEverySceneAppearsExactlyOnceInTheNavigator() throws {
        // The navigator nests scenes under their sections now. A scene that
        // lands in no section is invisible; one that lands in two is a phantom.
        for (name, script) in try corpusScripts() {
            let placed = scenes(in: OutlineTree.make(from: script))
            XCTAssertEqual(
                placed.sorted(), script.scenes.map(\.index).sorted(),
                "\(name): the navigator does not account for every scene."
            )
            XCTAssertEqual(
                Set(placed).count, placed.count,
                "\(name): a scene appears more than once in the navigator."
            )
        }
    }

    func testFilteringNeverInventsOrLosesAMatch() throws {
        for (name, script) in try corpusScripts() where !script.scenes.isEmpty {
            // Filter to a single real scene and check exactly that one survives.
            let target = script.scenes[script.scenes.count / 2].index
            let filtered = OutlineTree.filter(
                OutlineTree.make(from: script),
                matchingSceneIndices: [target]
            )
            XCTAssertEqual(
                scenes(in: filtered), [target],
                "\(name): filtering to one scene did not leave exactly that scene."
            )
        }
    }

    func testScriptsWithNoSectionsStillListTheirScenes() throws {
        // Nine of the seventeen loose scripts have no sections at all.
        for (name, script) in try corpusScripts() where script.sections.isEmpty {
            let placed = scenes(in: OutlineTree.make(from: script))
            XCTAssertEqual(
                placed.sorted(), script.scenes.map(\.index).sorted(),
                "\(name): a script without sections lost its scenes in the navigator."
            )
        }
    }
}
