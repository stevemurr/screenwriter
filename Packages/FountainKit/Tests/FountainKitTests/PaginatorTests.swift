import Foundation
import Testing
@testable import FountainKit

/// Pagination is reproducing Highland, so most of these assertions are not
/// design choices — they are measurements. Where a number looks arbitrary, the
/// comment says which export it came off.
@Suite("Paginator")
struct PaginatorTests {

    private func paginate(
        _ source: String,
        _ settings: PrintSettings = .highland
    ) -> PaginatedScript {
        Paginator.paginate(ScriptParser.parse(source), settings: settings)
    }

    /// Non-blank text on a page, in order.
    private func content(_ page: PaginatedPage) -> [String] {
        page.lines.filter { !$0.isBlank }.map(\.text)
    }

    // MARK: - Shape

    @Test("An empty script has no pages")
    func empty() {
        let paginated = paginate("")
        #expect(paginated.pages.isEmpty)
        #expect(paginated.pageCount == 0)
        #expect(paginated.page(forSourceOffset: 0) == nil)
    }

    @Test("A short script is one unnumbered page")
    func onePage() {
        let paginated = paginate("INT. ROOM - DAY\n\nShe waits.\n")
        #expect(paginated.pageCount == 1)
        #expect(paginated.pages[0].number == 1)
        #expect(paginated.pages[0].label == nil, "Page 1 is unnumbered.")
        #expect(content(paginated.pages[0]) == ["INT. ROOM - DAY", "She waits."])
    }

    @Test("Page numbers carry a trailing period and start at two")
    func pageNumbers() {
        var source = "INT. ROOM - DAY\n\n"
        for index in 0..<80 { source += "Beat \(index).\n\n" }
        let paginated = paginate(source)
        #expect(paginated.pageCount >= 2)
        #expect(paginated.pages[0].label == nil)
        #expect(paginated.pages[1].label == "2.")
        #expect(paginated.pages[1].number == 2)
    }

    @Test("Page one can be numbered when asked")
    func numberFirstPage() {
        var settings = PrintSettings.highland
        settings.numberFirstPage = true
        let paginated = paginate("INT. ROOM - DAY\n\nShe waits.\n", settings)
        #expect(paginated.pages[0].label == "1.")
    }

    // MARK: - Wrapping

    @Test("Action wraps at 63 characters, on a word boundary")
    func actionMeasure() {
        // 63 characters exactly, then one more word.
        let text = "Dominic produces a GUN—comically large, gleaming, a weapon that "
            + "says its owner is compensating."
        let paginated = paginate("INT. SHOP - DAY\n\n\(text)\n")
        let lines = content(paginated.pages[0])
        #expect(lines[1] == "Dominic produces a GUN—comically large, gleaming, a weapon that")
        #expect(lines[1].count == 63)
        #expect(lines[2] == "says its owner is compensating.")
    }

    @Test("Dialogue wraps at 34 characters")
    func dialogueMeasure() {
        let source = """
        INT. ROOM - DAY

        DOMINIC
        You see that’s what I thought. You look like a guy who’s afraid to try things.

        """
        let lines = content(paginate(source).pages[0])
        #expect(lines[1] == "DOMINIC")
        #expect(lines[2] == "You see that’s what I thought. You")
        #expect(lines[2].count == 34)
        #expect(lines[3] == "look like a guy who’s afraid to")
    }

    @Test("A parenthetical wraps at 29 and hangs the rest at 27")
    func parentheticalMeasure() {
        let source = """
        INT. ROOM - DAY

        EDITH
        (with the worldly wisdom of someone who’s seen it all and ordered the deluxe version)
        They all do that.

        """
        let lines = content(paginate(source).pages[0])
        #expect(lines[2] == "(with the worldly wisdom of")
        #expect(lines[3] == "someone who’s seen it all")
        #expect(lines[4] == "and ordered the deluxe")
        #expect(lines[5] == "version)")
    }

    @Test("A line may break after a dash")
    func dashBreaks() {
        // 384 lines in the corpus end on an em dash and 342 on a hyphen.
        let segments = LineWrap.wrap("Dom, there’s been some misunderstanding—I can explain", measure: 34)
        #expect(segments[0].text == "Dom, there’s been some")
        #expect(segments[1].text == "misunderstanding—I can explain")
    }

    @Test("A word wider than the measure is broken rather than run off the page")
    func unbreakableWord() {
        let segments = LineWrap.wrap(String(repeating: "x", count: 80), measure: 34)
        #expect(segments.count == 3)
        #expect(segments[0].text.count == 34)
    }

    @Test("Emphasis marks do not print and do not count towards the measure")
    func emphasis() {
        let source = "INT. ROOM - DAY\n\n**VHS STATIC** crackles, flickering across the screen, warping the image.\n"
        let lines = content(paginate(source).pages[0])
        #expect(lines[1] == "VHS STATIC crackles, flickering across the screen, warping the")
        let run = paginate(source).pages[0].lines.first { $0.text.hasPrefix("VHS") }?.emphasis.first
        #expect(run?.range == 0..<10)
        #expect(run?.style == .bold)
    }

    @Test("An underscore inside a word is not emphasis")
    func underscoreInsideWord() {
        // Five of the six lines in the corpus containing an underscore are
        // like this, and Highland prints the underscore.
        let parsed = Emphasis.parse("His handle was **ONEBOX_MANYPATHS**.")
        #expect(parsed.text == "His handle was ONEBOX_MANYPATHS.")
    }

    @Test("Highland's inline revision markup does not print")
    func revisionMarkup() {
        let parsed = Emphasis.parse("{{REVISION: #07a04a}}Weed and pills.{{/REVISION}}")
        #expect(parsed.text == "Weed and pills.")
    }

    // MARK: - Spacing

    @Test("Blank lines come from the source, and a run of two becomes three")
    func blankRuns() {
        // Measured: one blank source line prints as one, two print as three.
        // `Anal Informant - 6.1` sets two speeches two blank lines apart and
        // Highland prints three.
        func blanksBetweenActions(_ source: String) -> Int {
            let lines = paginate(source).pages[0].lines
            let first = lines.firstIndex { $0.text == "She waits." }!
            let second = lines.firstIndex { $0.text == "He leaves." }!
            return second - first - 1
        }
        #expect(blanksBetweenActions("INT. ROOM - DAY\n\nShe waits.\n\nHe leaves.\n") == 1)
        #expect(blanksBetweenActions("INT. ROOM - DAY\n\nShe waits.\n\n\nHe leaves.\n") == 3)
        #expect(blanksBetweenActions("INT. ROOM - DAY\n\nShe waits.\n\n\n\nHe leaves.\n") == 3)
    }

    @Test("A scene heading takes one extra blank line above it")
    func headingSpacing() {
        let source = "INT. ONE - DAY\n\nShe waits.\n\nINT. TWO - DAY\n\nHe leaves.\n"
        let lines = paginate(source).pages[0].lines
        let second = lines.firstIndex { $0.text == "INT. TWO - DAY" }!
        // One blank from the source plus one Highland adds.
        #expect(lines[second - 1].isBlank)
        #expect(lines[second - 2].isBlank)
        #expect(!lines[second - 3].isBlank)
    }

    @Test("A page never opens on a blank line")
    func noLeadingBlank() {
        var source = "INT. ROOM - DAY\n\n"
        for index in 0..<120 { source += "Beat number \(index).\n\n" }
        for page in paginate(source).pages {
            #expect(page.lines.first?.isBlank == false)
            #expect(page.lines.last?.isBlank == false)
        }
    }

    @Test("A heading with no blank line under it prints with none")
    func noImposedSpacing() {
        // Highland has no spacing table: page 2 of `Anal Informant - MASTER`
        // runs its action straight under the slug because the source does.
        let lines = content(paginate("INT. ROOM - DAY\nShe waits.\n").pages[0])
        #expect(lines == ["INT. ROOM - DAY", "She waits."])
        #expect(paginate("INT. ROOM - DAY\nShe waits.\n").pages[0].lines.count == 2)
    }

    // MARK: - Print settings

    @Test("Sections do not print, and their blank line goes with them")
    func sectionsAreNotPrinted() {
        // Measured across every identifiable export: Highland renders no
        // section lines at all. `## 1. EXT. RAVINE - DAY` in Trophy Boyz is
        // silently dropped, blank line included.
        let source = "# Act One\n\n## Beat\n\nINT. ROOM - DAY\n\nShe waits.\n"
        let paginated = paginate(source)
        #expect(content(paginated.pages[0]) == ["INT. ROOM - DAY", "She waits."])

        var settings = PrintSettings.highland
        settings.printSections = true
        #expect(content(paginate(source, settings).pages[0]).first == "Act One")
    }

    @Test("Synopses and notes do not print unless asked")
    func synopsesAndNotes() {
        let source = "INT. ROOM - DAY\n\n= She is waiting.\n\n[[check this]]\n\nShe waits.\n"
        #expect(content(paginate(source).pages[0]) == ["INT. ROOM - DAY", "She waits."])

        var settings = PrintSettings.everything
        settings.includeTitlePage = false
        let all = content(paginate(source, settings).pages[0])
        #expect(all.contains("She is waiting."))
        #expect(all.contains("check this"))
    }

    @Test("The title page is one extra unnumbered page")
    func titlePage() {
        let source = "Title: Anal Informant\nCredit: written by\nAuthor: Steven Murr\n\nINT. ROOM - DAY\n\nShe waits.\n"
        let paginated = paginate(source)
        #expect(paginated.pageCount == 2)
        #expect(paginated.bodyPageCount == 1)
        #expect(paginated.pages[0].isTitlePage)
        #expect(paginated.pages[0].label == nil)
        #expect(paginated.pages[0].lines.map(\.text) == ["Anal Informant", "written by", "Steven Murr"])
        #expect(paginated.pages[1].number == 1)
        #expect(paginated.pages[1].label == nil)

        var settings = PrintSettings.highland
        settings.includeTitlePage = false
        #expect(paginate(source, settings).pageCount == 1)
    }

    // MARK: - Breaking

    @Test("=== forces a page break")
    func forcedBreak() {
        let source = "INT. ONE - DAY\n\nShe waits.\n\n===\n\nINT. TWO - DAY\n\nHe leaves.\n"
        let paginated = paginate(source)
        #expect(paginated.pageCount == 2)
        #expect(content(paginated.pages[1]).first == "INT. TWO - DAY")
    }

    @Test("=== after a full page leaves a blank page")
    func forcedBreakOnFullPage() {
        // `The Quiet Night` has a page 30 carrying nothing but its number.
        var source = "INT. ONE - DAY\n"
        for index in 0..<54 { source += "Beat \(index).\n" }
        source += "\n===\n\nINT. TWO - DAY\n\nHe leaves.\n"
        let paginated = paginate(source)
        #expect(paginated.pageCount == 3)
        #expect(paginated.pages[0].lines.count == 55)
        #expect(paginated.pages[1].lines.isEmpty)
        #expect(paginated.pages[1].label == "2.")
        #expect(content(paginated.pages[2]).first == "INT. TWO - DAY")
    }

    @Test("A page holds 55 lines")
    func linesPerPage() {
        #expect(PageLayout.letter.linesPerPage == 55)
        var source = "INT. ROOM - DAY\n"
        for index in 0..<200 { source += "Line \(index).\n" }
        let paginated = paginate(source)
        for page in paginated.pages.dropLast() {
            #expect(page.lines.count == 55)
        }
    }

    @Test("A scene heading is never the last line on a page")
    func headingIsNeverOrphaned() {
        // Walk the offset of the heading through the whole page so every
        // landing position is exercised.
        for filler in 40...54 {
            var source = "INT. FIRST - DAY\n"
            for index in 0..<filler { source += "Beat \(index).\n" }
            source += "\nINT. SECOND - DAY\n\nThe scene plays out at length.\nAnd continues.\n"
            for page in paginate(source).pages {
                let content = page.lines.filter { !$0.isBlank }
                if let last = content.last, last.kind == .sceneHeading {
                    Issue.record("A heading ended page \(page.number) with filler \(filler).")
                }
            }
        }
    }

    @Test("A parenthetical is never the last line on a page")
    func parentheticalIsNeverOrphaned() {
        for filler in 40...54 {
            var source = "INT. ROOM - DAY\n"
            for index in 0..<filler { source += "Beat \(index).\n" }
            source += """

            DOMINIC
            (with the worldly wisdom of someone who has seen it all)
            They all do that, and then they do it again, and again, and again.

            """
            for page in paginate(source).pages {
                let content = page.lines.filter { !$0.isBlank }
                if let last = content.last, last.kind == .parenthetical {
                    Issue.record("A parenthetical ended page \(page.number) with filler \(filler).")
                }
            }
        }
    }

    @Test("Split dialogue gets (MORE) and a repeated cue with a curly apostrophe")
    func dialogueSplit() {
        var source = "INT. ROOM - DAY\n"
        for index in 0..<50 { source += "Beat \(index).\n" }
        source += """

        DOMINIC
        You see the prostate is like the male G-Spot and when you hit it just right \
        well that shift will change your life. But sometimes the guy is not paying \
        attention at all and when that happens it can be very uncomfortable indeed, \
        which is the sort of thing nobody tells you and everybody finds out.

        """
        let paginated = paginate(source)
        #expect(paginated.pageCount == 2)
        #expect(content(paginated.pages[0]).last == "(MORE)")
        #expect(content(paginated.pages[1]).first == "DOMINIC (CONT\u{2019}D)")
        // The apostrophe is U+2019, not U+0027 — a byte-level diff depends on it.
        #expect(!content(paginated.pages[1])[0].contains("'"))

        let more = paginated.pages[0].lines.last { $0.text == "(MORE)" }
        #expect(more?.x == PageLayout.letter.moreLeft)
        #expect(more?.isGenerated == true)
    }

    @Test("Neither side of a dialogue split gets fewer than two lines")
    func dialogueSplitMinimums() {
        for filler in 40...54 {
            var source = "INT. ROOM - DAY\n"
            for index in 0..<filler { source += "Beat \(index).\n" }
            source += """

            DOMINIC
            One two three four five six seven eight nine ten eleven twelve thirteen \
            fourteen fifteen sixteen seventeen eighteen nineteen twenty twenty-one.

            """
            let paginated = paginate(source)
            for (index, page) in paginated.pages.enumerated() {
                let content = page.lines.filter { !$0.isBlank }
                guard content.last?.text == "(MORE)" else { continue }
                // Cue plus at least one spoken line, then (MORE).
                #expect(content.count >= 3, "Too little kept on page \(index + 1).")
                guard index + 1 < paginated.pages.count else { continue }
                let next = paginated.pages[index + 1].lines.filter { !$0.isBlank }
                #expect(next.count >= 3, "Too little moved to page \(index + 2).")
            }
        }
    }

    @Test("A paragraph that splits prefers a sentence boundary")
    func sentenceSplit() {
        var source = "INT. ROOM - DAY\n"
        for index in 0..<50 { source += "Beat \(index).\n" }
        source += "\nFor a moment, she stays tense in his arms, her body still locked in "
            + "the fear of the nightmare. But slowly, she begins to relax, leaning into "
            + "him, letting his warmth calm the cold that had settled in her chest.\n"
        let paginated = paginate(source)
        #expect(paginated.pageCount == 2)
        #expect(content(paginated.pages[0]).last?.hasSuffix("nightmare.") == true)
        #expect(content(paginated.pages[1]).first?.hasPrefix("But slowly,") == true)
    }

    // MARK: - Geometry

    @Test("Lines land in the columns Highland measured")
    func columns() {
        let layout = PageLayout.letter
        let source = """
        INT. ROOM - DAY

        She waits.

        DOMINIC
        (quietly)
        Hello.

        CUT TO:

        """
        let lines = paginate(source).pages[0].lines.filter { !$0.isBlank }
        #expect(lines[0].x == layout.actionLeft)
        #expect(lines[2].x == layout.characterLeft)
        #expect(lines[3].x == layout.parentheticalLeft)
        #expect(lines[4].x == layout.dialogueLeft)
        #expect(lines[5].alignment == .right)
        #expect(abs(lines[5].x + CGFloat(7) * layout.characterWidth - layout.transitionRight) < 0.01)

        #expect(lines[0].y == layout.bodyTop)
        #expect(lines[1].y == layout.bodyTop + 2 * layout.lineHeight)
    }

    // MARK: - Offsets

    @Test("A source offset maps to a page and back")
    func offsetMapping() {
        var source = "INT. ROOM - DAY\n\n"
        var marker = 0
        for index in 0..<160 {
            if index == 100 { marker = (source as NSString).length }
            source += "Beat number \(index).\n\n"
        }
        let paginated = paginate(source)
        #expect(paginated.pageCount > 2)

        let page = try? #require(paginated.page(forSourceOffset: marker))
        #expect(page?.sourceRange.contains(marker) == true)
        // Round trip: the page's own first offset lands on the same page.
        if let page, let start = paginated.sourceOffset(forPage: page.index) {
            #expect(paginated.pageIndex(forSourceOffset: start) == page.index)
        }
        // Pages tile the source with no gaps.
        for (index, page) in paginated.pages.enumerated().dropLast() {
            let next = paginated.pages[index + 1]
            #expect(page.sourceRange.location + page.sourceRange.length == next.sourceRange.location)
        }
        #expect(paginated.pages[0].sourceRange.location == 0)
        #expect(paginated.line(forSourceOffset: marker) != nil)
        #expect(paginated.sourceOffset(forPageNumber: 2) != nil)
    }

    @Test("Every printed line is attributable to its scene")
    func sceneAttribution() {
        let source = """
        INT. ONE - DAY

        She waits.

        INT. TWO - DAY

        He leaves.

        """
        let paginated = paginate(source)
        let lines = paginated.pages[0].lines.filter { !$0.isBlank }
        #expect(lines.allSatisfy { $0.sceneIndex != nil })
        #expect(lines[0].sceneIndex == 1)
        #expect(lines[2].sceneIndex == 2)
        #expect(paginated.pages[0].sceneIndices == [1, 2])
    }

    @Test("Scene metrics report a page range and a length in eighths")
    func sceneMetrics() {
        var source = "INT. SHORT - DAY\n\nOne line.\n\nINT. LONG - DAY\n\n"
        for index in 0..<80 { source += "Beat \(index).\n\n" }
        let paginated = paginate(source)

        let short = try? #require(paginated.metric(forScene: 1))
        #expect(short?.lineCount == 2, "The heading counts, the blank above it does not.")
        #expect(short?.length.description == "1/8", "A scene shorter than an eighth still reports 1/8.")
        #expect(short?.pages == 1...1)

        let long = try? #require(paginated.metric(forScene: 2))
        #expect((long?.pages.lowerBound ?? 0) == 1)
        #expect((long?.pages.upperBound ?? 0) > 1)
        #expect((long?.length.total ?? 0) > 8)
        #expect(long?.lengthDescription.hasSuffix(" pp") == true)
    }
}

/// Highland's own PDFs are the oracle, so this suite is the one that matters.
///
/// Every expectation below is a page count read straight off an export with
/// `PDFDocument`, paired with the `.highland` bundle whose text produced it —
/// the pairing was established by comparing bags of long words, and each pair
/// here scored 0.99 or better against every other draft in the library.
///
/// The sources live inside `.highland` zips and FountainKit cannot yet read
/// one, so the test shells out to `unzip`. That is ugly, and it is the only way
/// to check against the canonical geometry: every export whose page geometry
/// matches `PageLayout` has its source inside a bundle.
@Suite("Paginator against Highland's exports")
struct PaginatorOracleTests {

    /// `(bundle, exported pages, what we produce, print settings)`.
    ///
    /// **Ours is pinned exactly, not to Highland's number.** Three of the 21
    /// disagree and the report says why; asserting Highland's number with a
    /// tolerance would hide a regression that happened to move the other way.
    private static let corpus: [(bundle: String, highland: Int, ours: Int, titlePage: Bool)] = [
        ("Anal Informant/not-master/Anal Informant - MASTER.highland", 83, 83, true),
        ("Anal Informant/backup/Anal Informant_rewrite1.highland", 83, 83, true),
        ("Anal Informant/not-master/Anal Informant - 6.1.highland", 90, 90, true),
        ("Anal Informant/backup/Anal Informant-Edith Sides.highland", 7, 7, true),
        ("The Quiet Night/The Quiet Night.highland", 40, 39, true),
        // Exported with scene numbers on and the title page off; the source has
        // a `Title:` block, so ours has to be told.
        ("The Algorithm of Us/The Algorithm of Us.highland", 29, 29, false),
        ("Pixelate2/Pixelate-Mark.highland", 47, 47, true),
        ("Trophy Boyz Rewrite/Episode 1.highland", 10, 10, true),
        ("Trophy Boyz Rewrite/Episode 2.highland", 11, 11, true),
        ("Trophy Boyz Rewrite/Episode 3.highland", 10, 10, true),
        ("Trophy Boyz Rewrite/Episode 4.highland", 11, 11, true),
        ("Trophy Boyz Rewrite/Episode 5.highland", 11, 11, true),
        ("Trophy Boyz Rewrite/Episode 6.highland", 11, 11, true),
        ("Trophy Boyz Rewrite/V2/Episode 7.highland", 15, 15, true),
        ("Trophy Boyz Rewrite/V2/Episode 8.highland", 23, 22, true),
        ("Trophy Boyz Rewrite/V2/Episode 9.highland", 18, 18, true),
        ("Trophy Boyz Rewrite/V2/Episode 10.highland", 28, 28, true),
        ("Trophy Boyz Rewrite/V2/Episode 11.highland", 21, 21, true),
        ("Trophy Boyz Rewrite/V2/Episode 12.highland", 38, 37, true)
    ]

    static let library = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Code/github.com/stevemurr/screenplays")

    /// The `text.fountain` inside a `.highland`, or nil when the bundle or
    /// `unzip` is not there.
    static func payload(of bundle: String) -> String? {
        let url = library.appendingPathComponent(bundle)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, "*/text.fountain"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @Test("Page counts hold against Highland's exports")
    func pageCounts() throws {
        try #require(
            FileManager.default.fileExists(atPath: Self.library.path),
            "Reference corpus not present on this machine."
        )
        var checked = 0
        var deviation = 0
        for entry in Self.corpus {
            guard let source = Self.payload(of: entry.bundle) else { continue }
            checked += 1
            var settings = PrintSettings.highland
            settings.includeTitlePage = entry.titlePage
            let pages = Paginator.pageCount(of: ScriptParser.parse(source), settings: settings)
            #expect(
                pages == entry.ours,
                "\(entry.bundle): \(pages) pages, expected \(entry.ours) (Highland: \(entry.highland))."
            )
            deviation += abs(pages - entry.highland)
        }
        try #require(checked > 0, "No bundles readable; `unzip` may be missing.")
        // Three pages across 19 scripts and 508 exported pages. Two are the
        // same unexplained case — Highland moving a block that fits exactly at
        // the foot of a page — and one is a wholly blank page after a `===`.
        #expect(deviation <= 3, "Drifted further from Highland's exports: \(deviation) pages.")
    }

    @Test("The canonical script paginates to 83 pages")
    func canonical() throws {
        let source = try #require(
            Self.payload(of: "Anal Informant/not-master/Anal Informant - MASTER.highland"),
            "Reference corpus not present on this machine."
        )
        let script = ScriptParser.parse(source)
        let paginated = Paginator.paginate(script)

        // `Anal Informant - MASTER.pdf`: 83 sheets, a title page and 82 numbered.
        #expect(paginated.pageCount == 83)
        #expect(paginated.bodyPageCount == 82)
        #expect(paginated.pages[0].isTitlePage)
        #expect(paginated.pages[1].label == nil)
        #expect(paginated.pages[2].label == "2.")

        // Page 2 of the PDF opens on the slug with its action on the very next
        // line, because the source has no blank between them.
        let first = paginated.pages[1].lines.filter { !$0.isBlank }
        #expect(first[0].text == "EXT. SUBURBAN HOME - MORNING")
        #expect(first[1].text == "SAL, an unassuming mid-thirties guy pulls into his driveway. He")
        // …and ends on `(MORE)`, with `DOMINIC (CONT’D)` at the top of page 3.
        #expect(first.last?.text == PageLayout.moreMarker)
        #expect(paginated.pages[2].lines.first?.text == "DOMINIC (CONT\u{2019}D)")

        // Every scene is measurable and none rounds away to nothing.
        #expect(paginated.scenes.count == script.scenes.count)
        #expect(paginated.scenes.allSatisfy { $0.length.total >= 1 })
        #expect(paginated.scenes.allSatisfy { $0.pages.lowerBound >= 1 })
    }
}

/// The status bar wants a page count while the author types. That is only
/// defensible if pagination is cheap enough to run beside the parse, off the
/// main actor behind the same debounce — so this suite holds that trade honest,
/// exactly as `ScriptParserPerformanceTests` does for the parse.
@Suite("Paginator performance")
struct PaginatorPerformanceTests {

    /// Through the shared resolver, which prefers the vendored snapshot.
    ///
    /// Read the user's live file directly and the 85-page expectation below
    /// becomes a claim about whatever they last edited — this test started
    /// failing when they applied 243 lint fixes to their own screenplay, which
    /// is not a regression in anything.
    private static var largestScript: String? {
        try? Corpus.source(of: "Anal Informant/anal-informant.fountain")
    }

    @Test("Paginating the largest script stays inside the debounce window")
    func latency() throws {
        let source = try #require(
            Self.largestScript,
            "Reference corpus not present on this machine."
        )
        let script = ScriptParser.parse(source)
        _ = Paginator.paginate(script)          // warm up

        var slowest: Double = 0
        for _ in 0..<10 {
            let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            let paginated = Paginator.paginate(script)
            slowest = max(
                slowest,
                Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1_000_000
            )
            #expect(paginated.pageCount == 85)
        }

        // Measured on this machine: 7ms in release, 26ms in debug, against a
        // 91 KB script — the same order as the 15ms parse it runs beside, and
        // well inside `ScreenplayModel`'s 120ms debounce. 60ms is the budget
        // because tests run unoptimised and CI machines are slower; it is still
        // tight enough to catch a real regression. If this fails, the fix is a
        // faster linear pass, not an incremental paginator: nothing in the
        // corpus justifies that complexity yet.
        // Split by configuration, like the parser's. A single 60ms number was
        // simultaneously too tight and too loose: debug's worst observed under
        // load is 44ms — 1.4x headroom — while release CPU is under 6ms, which
        // is 10x slack and would sit silently through a 4x regression.
        //
        // Measured on this machine, best-of-12 CPU while idle: 23.4ms debug,
        // 5.9ms release. Under concurrent suites those become ~44ms and ~9ms.
        //
        // Note CPU time is immune to *preemption*, not to load: it still
        // inflates roughly 1.4x under concurrency, through cache pressure and
        // being scheduled onto an efficiency core. Do not re-tune these down to
        // the idle figures.
        #if DEBUG
        let budget: Double = 90
        #else
        let budget: Double = 30
        #endif
        let slowestText = String(format: "%.2f", slowest)
        #expect(
            slowest < budget,
            "Pagination took \(slowestText)ms CPU, over the budget."
        )
    }

    @Test("Pagination is linear enough to scale")
    func scaling() throws {
        let source = try #require(Self.largestScript)
        let single = ScriptParser.parse(source)
        let double = ScriptParser.parse(source + "\n\n" + source)

        func measure(_ script: ParsedScript) -> Double {
            _ = Paginator.paginate(script)
            // Best of three. This is a ratio test, so a noisy denominator fails
            // the assertion while the code is perfectly fine.
            return (0..<3).map { _ -> Double in
                let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                _ = Paginator.paginate(script)
                return Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1_000_000
            }.min() ?? .infinity
        }

        let one = measure(single)
        let two = measure(double)
        let oneText = String(format: "%.2f", one)
        let twoText = String(format: "%.2f", two)
        #expect(
            two < one * 4 + 5,
            "Doubling the input took \(twoText)ms vs \(oneText)ms — pagination may not be linear."
        )
    }
}
