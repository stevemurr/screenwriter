import AppKit
import FountainKit
import SwiftUI
import XCTest
@testable import Screenwriter

/// The preview and the export share one paginator, so what the writer sees is
/// what they get. These tests hold that seam together at the app level.
@MainActor
final class PreviewIntegrationTests: XCTestCase {

    func testTheStatusBarPageCountComesFromTheRealPaginator() {
        let model = ScreenplayModel()
        model.load(String(repeating: "INT. A - DAY\n\nHe waits.\n\n", count: 60))
        let paginated = model.paginated
        XCTAssertNotNil(paginated)
        XCTAssertEqual(model.pageCount, paginated?.bodyPageCount)
        XCTAssertGreaterThan(model.pageCount, 1, "That much text should not fit on one page.")
    }

    func testSceneLengthsAreReportedInEighths() throws {
        let model = ScreenplayModel()
        model.load("""
        INT. GLASS HOUSE - NIGHT

        Rain needles the windows.

        EXT. GARDEN - NIGHT

        Owen waits.

        """)
        let metric = try XCTUnwrap(model.metric(forSceneAt: 1))
        // A short scene still reads as an eighth, never as zero — a schedule has
        // no row for a scene of no length.
        XCTAssertGreaterThan(metric.length.total, 0)
        XCTAssertTrue(metric.lengthDescription.hasSuffix("pp"))
    }

    func testSectionsDoNotPrint() {
        // Highland's saved settings claim they do; nineteen of the user's own
        // exports contain no printed section line at all.
        let model = ScreenplayModel()
        model.load("# Act One\n\nINT. A - DAY\n\nHe waits.\n")
        let text = (model.paginated?.pages ?? [])
            .flatMap(\.lines)
            .map(\.text)
        XCTAssertFalse(text.contains { $0.contains("Act One") })
        XCTAssertTrue(text.contains { $0.contains("INT. A - DAY") })
    }

    func testTheCaretMapsToAPage() throws {
        let model = ScreenplayModel()
        model.load(String(repeating: "INT. A - DAY\n\nHe waits.\n\n", count: 60))
        let paginated = try XCTUnwrap(model.paginated)

        let firstPage = try XCTUnwrap(paginated.page(forSourceOffset: 0))
        let lastOffset = (model.text as NSString).length - 1
        let latePage = try XCTUnwrap(paginated.page(forSourceOffset: lastOffset))
        XCTAssertLessThan(firstPage.index, latePage.index, "The preview must follow the caret.")
    }

    func testPageOneIsUnnumbered() throws {
        let model = ScreenplayModel()
        model.load(String(repeating: "INT. A - DAY\n\nHe waits.\n\n", count: 60))
        let pages = try XCTUnwrap(model.paginated?.pages.filter { !$0.isTitlePage })
        XCTAssertNil(pages.first?.label, "Highland leaves page 1 unnumbered.")
        XCTAssertNotNil(pages.dropFirst().first?.label)
    }

    /// Renders the preview offscreen. Screen recording is unavailable in this
    /// environment, so this is how the page layout gets looked at.
    func testEmitPreviewSnapshot() throws {
        guard let path = ProcessInfo.processInfo.environment["SCREENWRITER_PREVIEW_SNAPSHOT"] else {
            throw XCTSkip("Set SCREENWRITER_PREVIEW_SNAPSHOT to write a snapshot.")
        }
        let model = ScreenplayModel()
        model.load("""
        Title: Glass House
        Credit: Written by
        Author: Mara Voss

        INT. GLASS HOUSE - NIGHT

        Rain maps the windows in silver veins. MARA, 32, stands alone beneath the chandelier, watching the storm work its way across the valley.

        MARA
        We built a room with no shadows.

        LEO (O.S.)
        (quietly)
        Then why can I still see yours?

        > CUT TO:

        EXT. ROOFTOP - LATER

        The city exhales steam and light.

        """)

        let view = NSHostingView(
            rootView: PagePreview(
                paginated: model.paginated,
                caretPage: 0,
            )
            .frame(width: 700, height: 900)
        )
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        view.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: path))
    }
}
