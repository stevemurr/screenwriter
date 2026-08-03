import Foundation
import Testing
@testable import FountainKit

/// Blocks taller than a page.
///
/// **The reference library cannot reach this code.** The tallest block in it is
/// 25 source lines — measured across all 76 scripts and 28 177 blocks,
/// `.highland` payloads included — so no script the user owns has ever handed
/// the page breaker a block that fills a page on its own. Every corpus test
/// could pass with the repeated-split path completely broken.
///
/// `PaginatorTests` covers a block that splits *once*, near the foot of a page.
/// What is only reachable synthetically is a block that splits again and again:
/// the carried `(CONT'D)` cue arriving on a page that then ends in `(MORE)` of
/// its own, and — for a block with no legal split anywhere in it — the fill-mark-
/// and-carry fallback in `assemble`, which nothing else in the suite reaches.
///
/// So these are fixtures, not samples, and they are deliberately shaped to be
/// checkable rather than realistic.
@Suite("Blocks taller than a page")
struct PaginateTallBlockTests {

    static let layout = PageLayout.letter

    /// One cue with `lines` spoken lines under it, each long enough to wrap.
    /// No hyphens or dashes: a dash break resumes with no whitespace consumed,
    /// and `printedText` reassembles on single spaces.
    static func speech(lines: Int) -> (source: String, spoken: String) {
        var spoken = ""
        for index in 0..<lines {
            spoken += "Spoken line number \(index) here, and then some more words.\n"
        }
        return ("INT. ROOM - DAY\n\nLENA\n" + spoken, spoken)
    }

    static func action(lines: Int) -> (source: String, body: String) {
        var body = ""
        for index in 0..<lines {
            body += "Action line number \(index), long enough that it needs the whole "
            body += "width of the action column and then a little more.\n"
        }
        return ("INT. ROOM - DAY\n\n" + body, body)
    }

    static func paragraph(sentences: Int) -> (source: String, body: String) {
        var body = ""
        for index in 0..<sentences {
            body += "Sentence number \(index) of one very long unwrapped paragraph. "
        }
        return ("INT. ROOM - DAY\n\n" + body + "\n", body)
    }

    /// Every printed line of the given kinds, in order, joined on single
    /// spaces — what the reader actually reads, with the page breaks taken out.
    static func printedText(_ paginated: PaginatedScript, _ kinds: Set<ElementKind>) -> String {
        paginated.pages
            .flatMap(\.lines)
            .filter { !$0.isBlank && !$0.isGenerated && kinds.contains($0.kind) }
            .map(\.text)
            .joined(separator: " ")
    }

    /// Whitespace runs collapsed, so a comparison is about the words rather
    /// than about where the wrap happened to fall.
    static func normalised(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: - Repeated splitting

    @Test("A speech taller than a page splits again on every page it fills")
    func speechSplitsRepeatedly() {
        let paginated = Paginator.paginate(ScriptParser.parse(Self.speech(lines: 200).source))
        #expect(paginated.pageCount >= 6, "The fixture stopped being taller than a page.")

        let printed = paginated.pages.map { $0.lines.filter { !$0.isBlank } }
        for (index, page) in printed.enumerated() {
            if index < printed.count - 1 {
                #expect(page.last?.text == PageLayout.moreMarker, "Page \(index + 1) lost its (MORE).")
                #expect(page.last?.isGenerated == true)
                #expect(page.last?.x == Self.layout.moreLeft)
            }
            if index > 0 {
                #expect(
                    page.first?.text == PageLayout.continuedCue("LENA"),
                    "Page \(index + 1) did not repeat the cue."
                )
                #expect(page.first?.isGenerated == true)
                // The cue is a cue, set in the character column, not a heading.
                #expect(page.first?.kind == .character)
                #expect(page.first?.x == Self.layout.characterLeft)
            }
        }

        // A (MORE) and a (CONT'D) on every break, and the break count matches.
        let mores = paginated.pages.flatMap(\.lines).count { $0.text == PageLayout.moreMarker }
        let cues = paginated.pages.flatMap(\.lines)
            .count { $0.text == PageLayout.continuedCue("LENA") }
        #expect(mores == paginated.pageCount - 1)
        #expect(cues == paginated.pageCount - 1)
    }

    @Test("No page of a tall block overflows, opens blank, or goes backwards")
    func tallBlocksRespectThePage() {
        for source in [
            Self.speech(lines: 200).source,
            Self.action(lines: 200).source,
            Self.paragraph(sentences: 200).source
        ] {
            let paginated = Paginator.paginate(ScriptParser.parse(source))
            #expect(paginated.pageCount >= 3)
            var previous = -1
            for page in paginated.pages {
                #expect(
                    page.lines.count <= Self.layout.linesPerPage,
                    "Page \(page.number) has \(page.lines.count) rows."
                )
                #expect(page.lines.first?.isBlank != true, "Page \(page.number) opens on a blank.")
                #expect(page.lines.last?.isBlank != true, "Page \(page.number) ends on a blank.")
                for line in page.lines where !line.isBlank {
                    // Best effort inside an element, but never backwards: the
                    // preview maps a caret offset onto a page with a binary
                    // search, which needs the tiling to be monotonic.
                    #expect(
                        line.sourceOffset >= previous,
                        "Offset went backwards on page \(page.number)."
                    )
                    previous = line.sourceOffset
                }
            }
        }
    }

    // MARK: - Conservation

    @Test("Splitting a block across many pages neither loses nor repeats a word")
    func splittingConservesTheText() {
        // The failure a page-break bug actually produces: a sentence dropped at
        // a break, or set twice on either side of one. Nothing else in the
        // suite would notice, because every other split test reads two pages.
        let speech = Self.speech(lines: 200)
        let spoken = Paginator.paginate(ScriptParser.parse(speech.source))
        // Guard against the comparison going vacuous — two empty strings are
        // equal, and a fixture that stops producing text would pass silently.
        #expect(Self.printedText(spoken, [.dialogue]).utf8.count > 10_000)
        #expect(spoken.pageCount >= 6)
        #expect(
            Self.printedText(spoken, [.dialogue]) == Self.normalised(speech.spoken),
            "A speech lost or repeated text across \(spoken.pageCount) pages."
        )

        let action = Self.action(lines: 200)
        let acted = Paginator.paginate(ScriptParser.parse(action.source))
        #expect(
            Self.printedText(acted, [.action]) == Self.normalised(action.body),
            "An action block lost or repeated text across \(acted.pageCount) pages."
        )

        // The sentence-boundary path, which re-wraps *both* halves around the
        // split rather than cutting a wrapped line — the one most likely to
        // drop a character.
        let prose = Self.paragraph(sentences: 200)
        let set = Paginator.paginate(ScriptParser.parse(prose.source))
        #expect(
            Self.printedText(set, [.action]) == Self.normalised(prose.body),
            "A paragraph lost or repeated text across \(set.pageCount) pages."
        )
        // …and it really did split on sentences, not on line boundaries.
        let firstPage = set.pages[0].lines.filter { !$0.isBlank }
        #expect(firstPage.last?.text.hasSuffix("paragraph.") == true)
    }

    // MARK: - The block with nowhere legal to break

    @Test("A block with no legal split fills the page, marks it, and carries")
    func unsplittableBlockFillsAndCarries() {
        // A parenthetical may not be the last line on a page and a split never
        // falls inside one, so a speech that is nothing but parentheticals has
        // no legal break anywhere in it. `assemble` then falls back to filling
        // the page and carrying the rest — the only path here the rest of the
        // suite never executes.
        var source = "INT. ROOM - DAY\n\nLENA\n"
        for index in 0..<120 { source += "(a beat, and then another, number \(index))\n" }
        source += "Finally she actually says something out loud.\n"

        let paginated = Paginator.paginate(ScriptParser.parse(source))
        #expect(paginated.pageCount >= 4)
        for page in paginated.pages {
            #expect(page.lines.count <= Self.layout.linesPerPage)
            let printed = page.lines.filter { !$0.isBlank }
            // Whatever else happens, a page never ends on a parenthetical.
            #expect(
                printed.last?.kind != .parenthetical,
                "Page \(page.number) ends on a parenthetical."
            )
        }
        // The continuation lines hang in their own column rather than returning
        // to the parenthetical's left edge.
        let hung = paginated.pages.flatMap(\.lines)
            .filter { $0.kind == .parenthetical && $0.x == Self.layout.parentheticalContinuationLeft }
        #expect(!hung.isEmpty)
    }

    // MARK: - Eighths across a multi-page scene

    @Test("A scene spanning many pages is measured across all of them")
    func eighthsSpanPages() {
        let paginated = Paginator.paginate(ScriptParser.parse(Self.speech(lines: 200).source))
        let scene = try? #require(paginated.metric(forScene: 1))
        guard let scene else { return }

        #expect(scene.pages.lowerBound == 1)
        #expect(scene.pages.upperBound == paginated.bodyPageCount)

        // Every printed line on every page, counted once.
        let printed = paginated.pages
            .filter { !$0.isTitlePage }
            .flatMap(\.lines)
            .count { !$0.isBlank && $0.sceneIndex == 1 }
        #expect(scene.lineCount == printed)
        #expect(scene.length == Eighths(lines: printed, linesPerPage: Self.layout.linesPerPage))

        // **The generated lines count.** A `(MORE)` and a repeated cue take a
        // row of paper each, and eighths measure paper, so they are in the
        // total — which means a scene measures marginally longer for having
        // straddled a page break. On the reference script that is 12 generated
        // lines across 95 scenes and moves exactly 2 of them, by one eighth
        // each. Recorded rather than fixed: there is no Highland breakdown in
        // the library to check either reading against, and both are defensible.
        // If this ever changes it should be because an oracle turned up, not by
        // accident.
        let generated = paginated.pages.flatMap(\.lines).count { $0.isGenerated && !$0.isBlank }
        #expect(generated == (paginated.pageCount - 1) * 2)
        #expect(scene.lineCount > printed - generated)
    }
}
