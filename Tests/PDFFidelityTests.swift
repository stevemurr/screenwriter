import FountainKit
import PDFKit
import XCTest
@testable import Screenwriter

/// Compares our exported PDF against the ones Highland produced from the same
/// scripts.
///
/// Highland's 50 exports are the oracle for this whole project. Reading text
/// *with coordinates* back out of both with PDFKit needs no external tooling and
/// checks the thing that actually matters — whether a line lands on the same
/// column and the same page as it does in the file the writer already has.
@MainActor
final class PDFFidelityTests: XCTestCase {

    private func corpus(_ relativePath: String) throws -> URL {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Code/github.com/stevemurr/screenplays")
            .appendingPathComponent(relativePath)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "corpus not present")
        return url
    }

    /// Renders one of the user's own Highland bundles through the whole chain:
    /// zip, TextBundle, parse, paginate, PDF.
    ///
    /// The oracle pairing matters and is not obvious. `anal-informant.fountain`
    /// is *not* the source of `Anal Informant - MASTER.pdf` — the loose file
    /// opens on EXT. MOUNTAIN and the export opens on EXT. SUBURBAN HOME. They
    /// are different drafts, and comparing them compares nothing. The export's
    /// real source is the bundle of the same name, found by searching the
    /// library for its opening slugline.
    private func renderedPDF(fromBundle path: String) throws -> PDFDocument {
        let bundle = try HighlandBundle(contentsOf: try corpus(path))
            .imported(keepingOpaqueState: false).bundle
        let document = ScreenplayDocument()
        document.model.load(bundle.text)
        let data = try XCTUnwrap(document.renderPDF())
        return try XCTUnwrap(PDFDocument(data: data))
    }

    private static let master = "Anal Informant/not-master/Anal Informant - MASTER.highland"
    private static let masterPDF = "Anal Informant/backup/Anal Informant - MASTER.pdf"

    private func renderedMaster() throws -> PDFDocument {
        try renderedPDF(fromBundle: Self.master)
    }

    /// The columns a page is set in: the left edge of each text line, kept only
    /// where at least two lines share it.
    ///
    /// Lines are clustered on the 12pt baseline grid rather than by raw `minY`.
    /// `characterBounds` returns each *glyph's* box, so a descender sits 3pt
    /// below a capital on the very same line; grouping on the raw value split
    /// one line into several and invented columns that were really mid-word
    /// positions. Line spacing is 12pt and the worst descender is a quarter of
    /// that, so the grid is unambiguous.
    ///
    /// The two-line threshold drops the page number and any one-off, leaving the
    /// structural columns — which is what fidelity actually means here.
    private func leftEdges(of page: PDFPage) -> Set<Int> {
        var byRow: [Int: CGFloat] = [:]
        for index in 0..<page.numberOfCharacters {
            let bounds = page.characterBounds(at: index)
            guard bounds.width > 0, bounds.height > 0 else { continue }
            let row = Int((bounds.minY / PageLayout.letter.lineHeight).rounded())
            byRow[row] = min(byRow[row] ?? .greatestFiniteMagnitude, bounds.minX)
        }
        var counts: [Int: Int] = [:]
        for left in byRow.values { counts[Int(left.rounded()), default: 0] += 1 }
        return Set(counts.filter { $0.value >= 2 }.keys)
    }

    func testPageCountMatchesHighlandForTheReferenceScript() throws {
        let ours = try renderedMaster()
        let theirs = try XCTUnwrap(
            PDFDocument(url: try corpus(Self.masterPDF))
        )
        // 83 pages: one title page and 82 of script, in both.
        XCTAssertEqual(ours.pageCount, theirs.pageCount)
    }

    /// How many lines start at each column, across the whole document.
    private func columnHistogram(_ document: PDFDocument, from firstPage: Int) -> [Int: Int] {
        var histogram: [Int: Int] = [:]
        for index in firstPage..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            var byRow: [Int: CGFloat] = [:]
            for character in 0..<page.numberOfCharacters {
                let bounds = page.characterBounds(at: character)
                guard bounds.width > 0, bounds.height > 0 else { continue }
                let row = Int((bounds.minY / PageLayout.letter.lineHeight).rounded())
                byRow[row] = min(byRow[row] ?? .greatestFiniteMagnitude, bounds.minX)
            }
            for left in byRow.values { histogram[Int(left.rounded()), default: 0] += 1 }
        }
        return histogram
    }

    /// Compares the columns the whole document is set in, not page by page.
    ///
    /// Page-by-page would be the wrong assertion: the paginator matches
    /// Highland's page *count* on this script exactly, while individual page
    /// boundaries agree about 41% of the time, so page 81 of ours holds
    /// different text from page 81 of theirs. Comparing columns document-wide
    /// asks the question that is actually well-posed — is the script set in the
    /// same grid — and leaves page-break agreement to the paginator's own tests.
    func testTheDocumentIsSetInHighlandsColumns() throws {
        let ours = try renderedMaster()
        let theirs = try XCTUnwrap(PDFDocument(url: try corpus(Self.masterPDF)))

        // Both skip their title page, which is set in its own centred block.
        let mine = columnHistogram(ours, from: 1)
        let highland = columnHistogram(theirs, from: 1)

        // Adjacent integers are one column. `characterBounds` reports the glyph
        // box, so a line beginning `(` measures a point left of one beginning a
        // capital — both documents split 108/109 and 249/250 for that reason,
        // just in different proportions because their page breaks differ.
        //
        // Grouped by walking sorted keys, not by folding into a dictionary:
        // dictionary iteration order is arbitrary, so matching a column against
        // "some key within 2" once picked a stray 1-line neighbour over the
        // 61-line column beside it and reported a match failure that was not real.
        let mineColumns = Self.cluster(mine)
        let highlandColumns = Self.cluster(highland)

        // A structural column carries a real share of the script. An absolute
        // floor, not a percentage: the parenthetical hang is 1.07% of Highland's
        // lines and 0.85% of ours, so a 1% threshold would call it present in one
        // document and missing from the other while both set it identically.
        //
        // 40 admits exactly the six real columns — action, dialogue,
        // parenthetical, the parenthetical hang, the character cue, and the page
        // number — and excludes incidental clusters around 186, which are
        // dialogue lines whose first glyph simply has a wider left bearing (a
        // line beginning with a quotation mark). Both documents have those; only
        // the count differs, and only because the wrapping differs.
        let floor = 40
        let mineMajor = mineColumns.filter { $0.count >= floor }
        let highlandMajor = highlandColumns.filter { $0.count >= floor }

        func match(_ center: Int, in columns: [(center: Int, count: Int)]) -> Int? {
            columns.filter { abs($0.center - center) <= 2 }.map(\.count).max()
        }

        for column in mineMajor {
            XCTAssertNotNil(
                match(column.center, in: highlandMajor),
                "We set \(column.count) lines at x≈\(column.center) and Highland does not. "
                    + "Highland: \(highlandMajor)."
            )
        }
        // The converse matters more: a column Highland relies on and we never use
        // means a whole element type is landing in the wrong place. This is how
        // the missing parenthetical hang was found — Highland set 38 lines at
        // 214.195 and the paginator returned every continuation to the
        // parenthetical's own left edge.
        for column in highlandMajor {
            guard let ours = match(column.center, in: mineMajor) else {
                XCTFail(
                    "Highland sets \(column.count) lines at x≈\(column.center) and we never "
                        + "do. Ours: \(mineMajor)."
                )
                continue
            }
            // And in comparable proportion: the same columns used in wildly
            // different amounts would mean elements are being misclassified.
            let ratio = Double(ours) / Double(column.count)
            XCTAssertTrue(
                ratio > 0.6 && ratio < 1.6,
                "x≈\(column.center): we set \(ours) lines, Highland \(column.count)."
            )
        }
    }

    /// Groups a column histogram into clusters of keys no more than 2pt apart,
    /// each reported at its heaviest position.
    private static func cluster(_ histogram: [Int: Int]) -> [(center: Int, count: Int)] {
        var clusters: [(center: Int, count: Int)] = []
        var group: [Int] = []

        func close() {
            guard !group.isEmpty else { return }
            let total = group.reduce(0) { $0 + (histogram[$1] ?? 0) }
            let heaviest = group.max { (histogram[$0] ?? 0) < (histogram[$1] ?? 0) } ?? group[0]
            clusters.append((center: heaviest, count: total))
            group = []
        }

        for key in histogram.keys.sorted() {
            if let last = group.last, key - last > 2 { close() }
            group.append(key)
        }
        close()
        return clusters
    }

    func testTheMeasuredColumnsAreTheOnesWeShip() throws {
        // Guards the numbers in PageLayout against being "tidied" later.
        let layout = PageLayout.letter
        let ours = try renderedMaster()
        var seen: Set<Int> = []
        for index in 1..<min(ours.pageCount, 20) {
            seen.formUnion(leftEdges(of: try XCTUnwrap(ours.page(at: index))))
        }
        // Action, dialogue, parenthetical, and the character cue.
        for expected in [layout.actionLeft, layout.dialogueLeft, layout.characterLeft] {
            XCTAssertTrue(
                seen.contains { abs(CGFloat($0) - expected) <= 1 },
                "No line was drawn at the \(expected)pt column. Found: \(seen.sorted())."
            )
        }
    }

    func testPageOneCarriesNoPageNumberAndPageTwoDoes() throws {
        let ours = try renderedMaster()
        // Page 1 is the title page; the first page of script is page 2 of the
        // PDF and carries no number, and the one after it is numbered "2.".
        let firstScriptPage = try XCTUnwrap(ours.page(at: 1)).string ?? ""
        let secondScriptPage = try XCTUnwrap(ours.page(at: 2)).string ?? ""
        XCTAssertFalse(firstScriptPage.contains("1."), "Highland leaves page 1 unnumbered.")
        XCTAssertTrue(secondScriptPage.contains("2."))
    }

    func testCourierPrimeIsEmbeddedRatherThanSubstituted() throws {
        // A PDF set in a substituted font would look right here and wrong
        // everywhere else.
        XCTAssertTrue(
            ScreenplayFont.isCourierPrimeAvailable,
            "The bundled font did not register; exports would fall back to Courier New."
        )
        let ours = try renderedMaster()
        let data = try XCTUnwrap(ours.dataRepresentation())
        let raw = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(
            raw.contains("CourierPrime"),
            "Courier Prime is not named in the PDF's font resources."
        )
    }

    /// Writes our render to disk for side-by-side inspection against Highland's.
    func testEmitRenderedPDF() throws {
        guard let path = ProcessInfo.processInfo.environment["SCREENWRITER_PDF_DUMP"] else {
            throw XCTSkip("Set SCREENWRITER_PDF_DUMP to write the rendered PDF.")
        }
        let ours = try renderedMaster()
        try XCTUnwrap(ours.dataRepresentation()).write(to: URL(fileURLWithPath: path))
    }

    func testContinuedDialogueUsesHighlandsCurlyApostrophe() throws {
        let ours = try renderedMaster()
        let text = (0..<ours.pageCount)
            .compactMap { ours.page(at: $0)?.string }
            .joined()
        // Matching this matters for a byte-level diff against their exports.
        XCTAssertTrue(text.contains("(MORE)"))
        XCTAssertTrue(
            text.contains("(CONT\u{2019}D)"),
            "Continuation cues must use U+2019, as Highland's do."
        )
    }
}
