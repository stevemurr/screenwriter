import Foundation

/// Breaks a parsed script into pages the way Highland does.
///
/// **The rules here were read out of Highland's own PDFs, not out of a spec.**
/// A content-stream dump of the 19 exports whose source is identifiable — 508
/// pages, `Anal Informant - MASTER.pdf` (83 pages) canonical — gives every
/// number below. Where a rule looks arbitrary it is because Highland's is:
///
/// 1. **Blank lines come from the source.** Highland imposes no spacing table
///    between element kinds. A heading with no blank line under it in the
///    source prints with none, which is why page 2 of `MASTER.pdf` reads
///    `EXT. SUBURBAN HOME - MORNING` with its action on the very next line.
///    A *run* of blank lines is not linear, though: one prints as one, and two
///    or more print as three.
/// 2. **A scene heading takes one extra blank line above it**, dropped when the
///    heading lands at the top of a page.
/// 3. **An element that does not print takes one blank line with it.** In
///    Highland's model a paragraph owns the blank that ends it. Sections are
///    the common case; see `PrintSettings.printSections`.
/// 4. **Consecutive source lines of the same kind are one paragraph.** Authors
///    hard-wrap; Highland keeps the author's line breaks but moves the lines as
///    a unit.
/// 5. **A paragraph splits at a sentence boundary in preference to a line
///    boundary**, re-wrapping both halves, and leaves the foot of the page
///    empty rather than break mid-sentence.
/// 6. **A dialogue block splits with `(MORE)` and a repeated `NAME (CONT'D)`**,
///    under the same sentence rule.
///
/// Pagination is a single linear pass that allocates one `PageLine` per printed
/// line. It runs in a few milliseconds on the largest script in the reference
/// library, which is what lets the status bar keep a live page count; see
/// `PaginatorPerformanceTests` for the latency and `PaginateScalingTests` for
/// the shape of the curve.
///
/// Three pages out of 508 still disagree with Highland, all at the foot of a
/// page: twice Highland moves a block that fits its remaining rows exactly, and
/// once it emits a wholly blank page after a `===`. No rule in the corpus
/// explains either, and inventing one to close the gap would be tuning against
/// noise.
///
/// Measured facts about the cost, so the next person does not have to find them
/// again. All CPU time, `-c release`, on the 91 KB / 3 607-line
/// `anal-informant.fountain`:
///
/// - **5.8ms**, against a 120ms debounce, off the main actor. There is no
///   frame budget here to blow; anything below is invisible in the app and
///   worth having only if it is also free.
/// - **Nothing measures text.** This file and everything it calls import
///   `Foundation` and nothing else — no CoreText, no AppKit. Courier is
///   monospaced, so a width is a character count. Verified rather than assumed.
/// - **Roughly half the time goes on reading bridged `NSString`s.** `LineIndex`
///   cuts every line out of the document with `NSString.substring(with:)`, so
///   `Element.text` is a `__NSCFString` and each `.utf8` byte read is an
///   `objc_msgSend` into `-characterAtIndex:`. Handed the same script with the
///   same element text natively stored, this paginates in **3.2ms instead of
///   6.1ms for identical output**. The lever is in `Parse/`, not here: pulling
///   the bytes over on this side costs an allocation per element and gives back
///   only 0.2ms of it.
/// - **The tallest block in the whole library is 25 source lines**, across all
///   76 scripts and 28 177 blocks. No real script has ever handed the splitter
///   a block that fills a page by itself, so `split`'s cost is invisible on
///   real work and the only thing guarding it is `PaginateScalingTests`.
public enum Paginator {

    // MARK: - Entry points

    public static func paginate(
        _ script: ParsedScript,
        settings: PrintSettings = .highland
    ) -> PaginatedScript {
        Builder(script: script, settings: settings).run()
    }

    /// The page count alone. Currently a full pagination — it is fast enough
    /// that a second code path would only be a second thing to keep correct.
    public static func pageCount(
        of script: ParsedScript,
        settings: PrintSettings = .highland
    ) -> Int {
        paginate(script, settings: settings).pageCount
    }

    /// How a page number prints.
    ///
    /// **This is where production-locked A/B numbering hooks in.** A locked
    /// script keeps the page numbers of the draft it was locked against and
    /// numbers inserted pages `12A`, `12B`. `PaginatedPage.label` is already a
    /// `String` and nothing downstream parses it, so that change arrives as a
    /// lock table consulted here — `settings.lock?.label(forOrdinal:)` — and as
    /// nothing else. Deliberately not implemented: there is no locked script in
    /// the reference library to check a result against.
    static func pageLabel(forNumber number: Int, settings: PrintSettings) -> String? {
        guard number > 0 else { return nil }
        guard number > 1 || settings.numberFirstPage else { return nil }
        return "\(number)."
    }

    // MARK: - Rows

    /// One line of the flattened script, before it knows which page it is on.
    private struct Row {
        /// Lines this engine invents rather than typesets from an element.
        enum Generated {
            case none
            case more
            case continuedCue
        }
        var kind: ElementKind
        var text: String
        var emphasis: [EmphasisRun] = []
        var alignment: PageLine.Alignment
        var elementIndex: Int?
        var sourceOffset: Int
        var sceneIndex: Int?
        /// Where this row starts inside its block, so a split can be expressed
        /// as a position rather than a row count and both halves re-wrapped
        /// around it.
        var position = Position(paragraph: 0, offset: 0)
        var generated: Generated = .none
    }

    /// A point inside a block: which of its paragraphs, and how far into that
    /// paragraph's printed text.
    private struct Position: Comparable, Hashable {
        var paragraph: Int
        var offset: Int

        static func < (lhs: Position, rhs: Position) -> Bool {
            (lhs.paragraph, lhs.offset) < (rhs.paragraph, rhs.offset)
        }
    }

    /// Everything needed to re-wrap a paragraph from an arbitrary point, which
    /// is what splitting one across a page break requires.
    private struct Paragraph {
        var elementIndex: Int
        var kind: ElementKind
        var alignment: PageLine.Alignment
        var sceneIndex: Int?
        /// The printed text: forcing mark and emphasis delimiters gone.
        var text: String
        var emphasis: [EmphasisRun]
        var shifts: [(printed: Int, removed: Int)]
        var measure: Int
        var continuationMeasure: Int
        /// UTF-16 offsets a page break may fall on. See `LineWrap.sentenceBreaks`.
        var sentenceBreaks: [Int]
        var baseOffset: Int
        var upperBound: Int
        var utf16Length: Int

        /// The printed text between two UTF-16 offsets.
        func slice(from start: Int, to end: Int?) -> String {
            let limit = min(end ?? utf16Length, utf16Length)
            guard start > 0 || limit < utf16Length else { return text }
            guard start < limit else { return "" }
            let lower = String.Index(utf16Offset: start, in: text)
            let upper = String.Index(utf16Offset: limit, in: text)
            return String(text[lower..<upper])
        }
    }

    /// A run of rows the page breaker treats as one thing.
    private struct Block {
        enum Shape {
            /// A single blank line.
            case blank
            /// `===`.
            case forcedBreak
            /// A heading, which may not be the last line on a page.
            case sceneHeading
            /// A cue and everything spoken under it.
            case dialogue(cue: String)
            /// Action, transitions, centred text, printed sections.
            case paragraph
        }
        var shape: Shape
        /// The block's content, in order: for dialogue, the cue followed by its
        /// parentheticals and spoken lines. Empty for `.blank` and
        /// `.forcedBreak`.
        var paragraphs: [Paragraph]
        /// Rows for the whole block, cached so the common case — it fits —
        /// costs one wrap.
        var rows: [Row]
    }

    // MARK: - Builder

    private struct Builder {
        let script: ParsedScript
        let settings: PrintSettings
        /// `elements.count` entries: the one-based scene each element belongs
        /// to, or 0 for anything ahead of the first heading. Built once so row
        /// construction stays O(1) per element.
        private let sceneOfElement: [Int]

        var layout: PageLayout { settings.layout }

        init(script: ParsedScript, settings: PrintSettings) {
            self.script = script
            self.settings = settings
            var owners = [Int](repeating: 0, count: script.elements.count)
            for scene in script.scenes {
                for index in scene.elementRange where index < owners.count {
                    owners[index] = scene.index
                }
            }
            self.sceneOfElement = owners
        }

        func run() -> PaginatedScript {
            var pages = assemble(buildBlocks())
            if settings.includeTitlePage,
               let titlePage = script.titlePage,
               !titlePage.entries.isEmpty {
                pages.insert(makeTitlePage(titlePage), at: 0)
            }
            tile(&pages)
            return PaginatedScript(
                pages: pages,
                scenes: measureScenes(pages),
                settings: settings,
                source: script.source
            )
        }

        // MARK: Flattening

        private func alignment(for kind: ElementKind) -> PageLine.Alignment {
            switch kind {
            case .transition: return .right
            case .centered: return .centered
            default: return .left
            }
        }

        /// Turns elements into rows, grouped into blocks.
        private func buildBlocks() -> [Block] {
            var blocks: [Block] = []
            blocks.reserveCapacity(script.elements.count)
            let elements = script.elements
            var index = 0

            while index < elements.count {
                let element = elements[index]

                // An element that does not print takes one blank line with it —
                // in Highland's model a paragraph owns the blank that ends it,
                // so dropping the paragraph drops that too. Trophy Boyz proves
                // it: `mschwab@…`, blank, `## 1. EXT. RAVINE - DAY`, blank,
                // action prints with exactly one blank line, not two.
                if !settings.prints(element.kind) {
                    index += 1
                    if index < elements.count, elements[index].kind == .blank { index += 1 }
                    continue
                }

                switch element.kind {
                case .blank:
                    // A run of k blank source lines prints as one blank line
                    // when k is 1 and three when it is more. Measured: two
                    // blank lines between two speeches in `Anal Informant - 6.1`
                    // print as three, and three blank lines before
                    // `FLASHBACK - INT. COMPOUND - NIGHT` in `The Quiet Night`
                    // also print as three. Runs of four or more do not occur in
                    // the corpus, so the cap is where the evidence stops.
                    var run = 0
                    var scan = index
                    while scan < elements.count {
                        if elements[scan].kind == .blank {
                            run += 1
                            scan += 1
                            continue
                        }
                        guard !settings.prints(elements[scan].kind) else { break }
                        scan += 1
                        if scan < elements.count, elements[scan].kind == .blank { scan += 1 }
                    }
                    for _ in 0..<(run == 1 ? 1 : 3) {
                        blocks.append(
                            Block(shape: .blank, paragraphs: [], rows: [blankRow(element, index)])
                        )
                    }
                    index = scan

                case .pageBreak:
                    blocks.append(Block(shape: .forcedBreak, paragraphs: [], rows: []))
                    index += 1

                case .sceneHeading:
                    // One blank line above a heading, on top of any the author
                    // wrote. Dropped when the heading opens a page.
                    blocks.append(
                        Block(shape: .blank, paragraphs: [], rows: [blankRow(element, index)])
                    )
                    blocks.append(make(.sceneHeading, [makeParagraph(element, at: index)]))
                    index += 1

                case .character:
                    var paragraphs = [makeParagraph(element, at: index)]
                    var next = index + 1
                    while next < elements.count {
                        let kind = elements[next].kind
                        guard kind == .dialogue || kind == .parenthetical || kind == .lyrics
                        else { break }
                        paragraphs.append(makeParagraph(elements[next], at: next))
                        next += 1
                    }
                    blocks.append(
                        make(
                            .dialogue(cue: ScriptParser.characterName(from: element.text)),
                            paragraphs
                        )
                    )
                    index = next

                default:
                    // Consecutive source lines of the same kind are one
                    // paragraph, even though each keeps its own line break.
                    // Highland moves them as a unit: page 2 of `Trophy Boyz`
                    // episode 8 has room for the first line of a two-line
                    // action paragraph and leaves it empty rather than strand
                    // that line at the foot of the page.
                    var paragraphs = [makeParagraph(element, at: index)]
                    var next = index + 1
                    while next < elements.count, elements[next].kind == element.kind {
                        paragraphs.append(makeParagraph(elements[next], at: next))
                        next += 1
                    }
                    blocks.append(make(.paragraph, paragraphs))
                    index = next
                }
            }
            return blocks
        }

        private func make(_ shape: Block.Shape, _ paragraphs: [Paragraph]) -> Block {
            Block(
                shape: shape,
                paragraphs: paragraphs,
                rows: rows(of: paragraphs, from: Position(paragraph: 0, offset: 0))
            )
        }

        private func blankRow(_ element: Element, _ index: Int) -> Row {
            Row(
                kind: .blank,
                text: "",
                alignment: .left,
                elementIndex: element.kind == .blank ? index : nil,
                sourceOffset: element.range.location,
                sceneIndex: sceneIndex(of: index)
            )
        }

        private func sceneIndex(of elementIndex: Int) -> Int? {
            guard elementIndex < sceneOfElement.count else { return nil }
            let owner = sceneOfElement[elementIndex]
            return owner == 0 ? nil : owner
        }

        private func makeParagraph(_ element: Element, at index: Int) -> Paragraph {
            // Emphasis delimiters do not print, so they must come out before
            // wrapping — counting them wraps every emphasised line early.
            let parsed = Emphasis.parse(element.text)
            // The forcing mark was stripped from `text`, so an offset inside the
            // element is one character further along than the offset into it.
            // Clamped, because `section` and `character` trim whitespace too and
            // an exact map would be a lie.
            return Paragraph(
                elementIndex: index,
                kind: element.kind,
                alignment: alignment(for: element.kind),
                sceneIndex: sceneIndex(of: index),
                text: parsed.text,
                emphasis: parsed.runs,
                shifts: parsed.shifts,
                measure: layout.charactersPerLine(for: element.kind),
                continuationMeasure: layout.continuationCharactersPerLine(for: element.kind),
                sentenceBreaks: LineWrap.sentenceBreaks(parsed.text),
                baseOffset: element.range.location + (element.forcingMark == nil ? 0 : 1),
                upperBound: element.range.location + max(element.range.length - 1, 0),
                utf16Length: parsed.text.utf16.count
            )
        }

        /// Wraps a block's paragraphs from a position onward.
        private func rows(
            of paragraphs: [Paragraph],
            from start: Position,
            to end: Position? = nil
        ) -> [Row] {
            var rows: [Row] = []
            var index = start.paragraph
            while index < paragraphs.count {
                if let end, index > end.paragraph { break }
                if let end, index == end.paragraph, end.offset == 0 { break }
                rows.append(
                    contentsOf: self.rows(
                        of: paragraphs[index],
                        at: index,
                        from: index == start.paragraph ? start.offset : 0,
                        to: (end?.paragraph == index) ? end?.offset : nil
                    )
                )
                index += 1
            }
            return rows
        }

        /// Wraps one paragraph from a printed UTF-16 offset onward.
        private func rows(
            of paragraph: Paragraph,
            at position: Int,
            from start: Int,
            to end: Int? = nil
        ) -> [Row] {
            let text = paragraph.slice(from: start, to: end)
            let parsed = Emphasis.Parsed(
                text: paragraph.text,
                runs: paragraph.emphasis,
                shifts: paragraph.shifts
            )
            return LineWrap.wrap(
                text,
                measure: start == 0 ? paragraph.measure : paragraph.continuationMeasure,
                continuation: paragraph.continuationMeasure
            ).map { segment in
                let lower = start + segment.utf16Offset
                let upper = lower + segment.text.utf16.count
                var emphasis: [EmphasisRun] = []
                for run in paragraph.emphasis {
                    let from = max(run.range.lowerBound, lower)
                    let to = min(run.range.upperBound, upper)
                    if from < to {
                        emphasis.append(
                            EmphasisRun(range: (from - lower)..<(to - lower), style: run.style)
                        )
                    }
                }
                return Row(
                    kind: paragraph.kind,
                    text: segment.text,
                    emphasis: emphasis,
                    alignment: paragraph.alignment,
                    elementIndex: paragraph.elementIndex,
                    sourceOffset: min(
                        paragraph.baseOffset + parsed.inputOffset(forPrinted: lower),
                        paragraph.upperBound
                    ),
                    sceneIndex: paragraph.sceneIndex,
                    position: Position(paragraph: position, offset: lower)
                )
            }
        }

        // MARK: Page assembly

        private func assemble(_ blocks: [Block]) -> [PaginatedPage] {
            let perPage = layout.linesPerPage
            var pages: [PaginatedPage] = []
            var current: [Row] = []
            current.reserveCapacity(perPage)

            func endPage(force: Bool = false) {
                // Trailing blanks are never drawn, and dropping them keeps a
                // page from claiming source that belongs to the next one.
                while current.last?.kind == .blank { current.removeLast() }
                guard !current.isEmpty || (force && !pages.isEmpty) else { return }
                pages.append(makePage(index: pages.count, rows: current))
                current.removeAll(keepingCapacity: true)
            }

            var index = 0
            /// Where the unplaced tail of `blocks[index]` starts, after a split.
            /// A position rather than a row list, because both halves of a split
            /// are re-wrapped around it.
            var carry: Position?
            /// The repeated cue a split dialogue block owes its continuation.
            var carriedCue: String?

            while index < blocks.count {
                let block = blocks[index]
                let from = carry ?? Position(paragraph: 0, offset: 0)
                var rows = carry == nil ? block.rows : self.rows(of: block.paragraphs, from: from)
                if let cue = carriedCue { rows.insert(continuedCueRow(cue, like: rows[0]), at: 0) }
                let free = perPage - current.count

                func finish() {
                    carry = nil
                    carriedCue = nil
                    index += 1
                }

                /// Places everything before `split`, ends the page, and leaves
                /// the rest for the next pass.
                func divide(at split: Position, more: Bool, cue: String?) {
                    var head = self.rows(of: block.paragraphs, from: from, to: split)
                    if let cue = carriedCue { head.insert(continuedCueRow(cue, like: head[0]), at: 0) }
                    current.append(contentsOf: head)
                    if more, let last = head.last { current.append(moreRow(like: last)) }
                    endPage()
                    carry = split
                    carriedCue = cue
                }

                switch block.shape {
                case .blank:
                    // A page never opens on a blank line, and never ends on one:
                    // 728 of the 730 exported pages start on their first row.
                    // A blank with nowhere to go still closes the page, so a
                    // `===` behind it turns an already-empty one.
                    if current.isEmpty {
                        finish()
                    } else if free > 0 {
                        current.append(rows[0])
                        finish()
                    } else {
                        endPage()
                        finish()
                    }

                case .forcedBreak:
                    // `===` turns the page even when the last one has just
                    // closed, which yields a wholly blank page. That is not a
                    // guess: `The Quiet Night` has exactly such a page 30,
                    // carrying nothing but its number. The author asked for a
                    // break; swallowing it because the page happened to be full
                    // would be the surprising behaviour.
                    endPage(force: true)
                    finish()

                case .sceneHeading:
                    // A heading may not be the last thing on a page, and one
                    // line under it would be a false promise. It needs room for
                    // itself, the blank lines that follow it, and two lines of
                    // whatever comes next — page 15 of `Trophy Boyz` episode 8
                    // has room for the heading and one line and moves both.
                    if rows.count + follow(blocks, after: index) <= free {
                        current.append(contentsOf: rows)
                        finish()
                    } else if current.isEmpty {
                        current.append(contentsOf: rows.prefix(perPage))
                        finish()
                    } else {
                        endPage()
                    }

                case .dialogue(let cue):
                    if rows.count <= free {
                        current.append(contentsOf: rows)
                        finish()
                    } else if let split = self.split(
                        block, rows: rows, from: from, free: free, reserve: 1
                    ) {
                        divide(at: split, more: true, cue: cue)
                    } else if current.isEmpty {
                        // A speech taller than a whole page and unsplittable by
                        // the usual rules: fill, mark, carry.
                        divide(at: rows[perPage - 1].position, more: true, cue: cue)
                    } else {
                        endPage()
                    }

                case .paragraph:
                    if rows.count <= free {
                        current.append(contentsOf: rows)
                        finish()
                    } else if let split = self.split(
                        block, rows: rows, from: from, free: free, reserve: 0
                    ) {
                        divide(at: split, more: false, cue: nil)
                    } else if current.isEmpty {
                        divide(at: rows[perPage].position, more: false, cue: nil)
                    } else {
                        endPage()
                    }
                }
            }
            endPage()
            return pages
        }

        /// How much room the blocks after a scene heading need for the heading
        /// to be worth printing: the blank lines under it plus two lines of the
        /// next thing, or all of it when the next thing is shorter than two.
        private func follow(_ blocks: [Block], after index: Int) -> Int {
            var needed = 0
            var next = index + 1
            while next < blocks.count {
                switch blocks[next].shape {
                case .blank:
                    needed += 1
                    next += 1
                    continue
                case .forcedBreak:
                    return needed
                default:
                    return needed + min(2, blocks[next].rows.count)
                }
            }
            return needed
        }

        // MARK: Splitting

        /// Where to break a block across a page, or nil to move it whole.
        ///
        /// Both shapes obey the same two rules, because Highland does:
        ///
        /// - **A sentence boundary beats a line boundary**, and both halves are
        ///   re-wrapped around it. Page 5 of `The Quiet Night` ends on
        ///   `locked in the fear of the nightmare.` with a line of the page
        ///   still free, rather than run the next sentence onto that line; page
        ///   34 of `Trophy Boyz` episode 12 puts `(MORE)` after
        ///   `understand what happened.` for the same reason.
        /// - **Two rows stay and two move.** For dialogue the cue counts as one
        ///   of the two that stay, so a cue with a parenthetical and one spoken
        ///   line is a legal page foot — Highland does exactly that on page 31
        ///   of that episode.
        ///
        /// `reserve` is the room the `(MORE)` line needs. A parenthetical may
        /// not be the last thing on a page, and a split never falls inside a cue
        /// or a parenthetical.
        func split(
            _ block: Block,
            rows: [Row],
            from: Position,
            free: Int,
            reserve: Int
        ) -> Position? {
            guard free >= 2 + reserve, rows.count >= 4 else { return nil }

            /// How many of `rows` stay when the block is split at `position`.
            ///
            /// A lower bound, not a scan. `rows` is ordered by position — the
            /// wrap walks a block's paragraphs in order and a paragraph's
            /// offsets in order — and a repeated cue is always row 0 at
            /// position (0, 0), ahead of every candidate. This was a linear
            /// scan, and since it is asked once per candidate that made `split`
            /// quadratic in the height of the block; see `verdict`.
            func keptRows(before position: Position) -> Int {
                var low = 0
                var high = rows.count
                while low < high {
                    let middle = (low + high) / 2
                    if rows[middle].position < position
                        || rows[middle].generated == .continuedCue {
                        low = middle + 1
                    } else {
                        high = middle
                    }
                }
                return low
            }

            /// `.past` means the candidate already keeps more rows than the
            /// page has free. Candidates arrive in ascending order and
            /// `keptRows` only grows with the position, so nothing after a
            /// `.past` can be legal and the search stops there rather than
            /// walking the whole remaining block.
            enum Verdict { case legal, illegal, past }

            func verdict(_ position: Position) -> Verdict {
                let kept = keptRows(before: position)
                guard kept + reserve <= free else { return .past }
                guard kept >= 2, rows.count - kept >= 2 else { return .illegal }
                return rows[kept - 1].kind == .parenthetical ? .illegal : .legal
            }

            // Sentence boundaries, latest first.
            var best: Position?
            sentences: for (index, paragraph) in block.paragraphs.enumerated() {
                guard index >= from.paragraph else { continue }
                // A cue and a parenthetical are indivisible: neither is prose,
                // and splitting inside one produces nonsense.
                guard paragraph.kind != .character, paragraph.kind != .parenthetical
                else { continue }
                for boundary in paragraph.sentenceBreaks
                where boundary > 0 && boundary < paragraph.utf16Length {
                    let position = Position(paragraph: index, offset: boundary)
                    guard position > from else { continue }
                    switch verdict(position) {
                    case .legal: best = position
                    case .illegal: continue
                    case .past: break sentences
                    }
                }
            }
            if let best { return best }

            // Line boundaries.
            var line: Position?
            for row in rows where row.position > from {
                switch verdict(row.position) {
                case .legal: line = row.position
                case .illegal: continue
                case .past: return line
                }
            }
            return line
        }

        private func moreRow(like row: Row) -> Row {
            Row(
                kind: .character,
                text: PageLayout.moreMarker,
                alignment: .left,
                elementIndex: nil,
                sourceOffset: row.sourceOffset,
                sceneIndex: row.sceneIndex,
                generated: .more
            )
        }

        private func continuedCueRow(_ cue: String, like row: Row) -> Row {
            Row(
                kind: .character,
                text: PageLayout.continuedCue(cue),
                alignment: .left,
                elementIndex: nil,
                sourceOffset: row.sourceOffset,
                sceneIndex: row.sceneIndex,
                generated: .continuedCue
            )
        }

        // MARK: Page construction

        /// The drawn width of a line, in points.
        ///
        /// Only `.right` and `.centered` lines need it — a left-aligned line
        /// starts at its column's left edge whatever it says — and they are
        /// about one printed line in a hundred. Computing it for every line
        /// instead cost 0.35ms of the 6.2ms release pagination of the 91 KB
        /// script, because `unicodeScalars.count` walks the whole string.
        private func width(of text: String) -> CGFloat {
            CGFloat(text.unicodeScalars.count) * layout.characterWidth
        }

        private func makePage(index: Int, rows: [Row]) -> PaginatedPage {
            var lines: [PageLine] = []
            lines.reserveCapacity(rows.count)
            var scenes: [Int] = []

            for (row, source) in rows.enumerated() {
                let x: CGFloat
                switch (source.generated, source.alignment) {
                case (.more, _):
                    x = layout.moreLeft
                case (_, .left) where source.kind == .parenthetical
                    && source.position.offset > 0:
                    // A parenthetical hangs its continuation lines rather than
                    // returning to its own left edge. Without this the whole
                    // column vanishes: Highland sets 38 lines at 214.195 in the
                    // reference export and we set none, which the PDF fidelity
                    // test catches as a missing column.
                    x = layout.parentheticalContinuationLeft
                case (_, .left):
                    x = layout.leftEdge(for: source.kind)
                case (_, .right):
                    x = layout.transitionRight - width(of: source.text)
                case (_, .centered):
                    x = (layout.pageWidth - width(of: source.text)) / 2
                }
                lines.append(
                    PageLine(
                        kind: source.kind,
                        text: source.text,
                        emphasis: source.emphasis,
                        alignment: source.alignment,
                        elementIndex: source.elementIndex,
                        sourceOffset: source.sourceOffset,
                        sceneIndex: source.sceneIndex,
                        row: row,
                        x: x,
                        y: layout.bodyTop + CGFloat(row) * layout.lineHeight
                    )
                )
                if let scene = source.sceneIndex, scenes.last != scene { scenes.append(scene) }
            }

            let number = index + 1
            return PaginatedPage(
                index: index,
                number: number,
                label: Paginator.pageLabel(forNumber: number, settings: settings),
                lines: lines,
                sceneIndices: scenes,
                sourceRange: NSRange(location: rows.first?.sourceOffset ?? 0, length: 0)
            )
        }

        /// Renumbers after a title page is prepended and makes the pages' source
        /// ranges tile the document, so an offset lands on exactly one page.
        private func tile(_ pages: inout [PaginatedPage]) {
            let length = (script.source as NSString).length
            var number = 0
            for index in pages.indices {
                pages[index].index = index
                if pages[index].isTitlePage { continue }
                number += 1
                pages[index].number = number
                pages[index].label = Paginator.pageLabel(forNumber: number, settings: settings)
            }
            for index in pages.indices {
                let start = pages[index].sourceRange.location
                let end = index + 1 < pages.count
                    ? pages[index + 1].sourceRange.location
                    : length
                pages[index].sourceRange = NSRange(
                    location: start,
                    length: max(end - start, 0)
                )
            }
            if pages.indices.contains(0) {
                // The first page owns everything ahead of it — a title page's
                // own range, or a leading run of blanks nothing else claimed.
                pages[0].sourceRange = NSRange(
                    location: 0,
                    length: pages[0].sourceRange.location + pages[0].sourceRange.length
                )
            }
        }

        /// The title page: one page, always, in every export in the corpus.
        ///
        /// The grid was measured off `Anal Informant - MASTER.pdf` — rows 14.4pt
        /// apart, title on row 2, credit on row 7, author on row 10, all centred
        /// — and everything else the author wrote goes in the lower block. Final
        /// typesetting is the renderer's business; what pagination needs from
        /// this is that it is exactly one unnumbered page.
        private func makeTitlePage(_ titlePage: TitlePage) -> PaginatedPage {
            var lines: [PageLine] = []
            var used: Set<String> = []

            func add(_ text: String, row: Int, centered: Bool) {
                guard !text.isEmpty else { return }
                lines.append(
                    PageLine(
                        kind: .action,
                        text: text,
                        alignment: centered ? .centered : .left,
                        elementIndex: nil,
                        sourceOffset: titlePage.range.location,
                        sceneIndex: nil,
                        row: row,
                        x: centered ? (layout.pageWidth - width(of: text)) / 2 : 72,
                        y: layout.titleBlockTop + CGFloat(row) * layout.titleLineHeight
                    )
                )
            }

            for (key, row) in [("Title", 2), ("Credit", 7), ("Author", 10)] {
                guard let entry = titlePage.entries.first(
                    where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }
                ) else { continue }
                used.insert(key.lowercased())
                for (offset, value) in entry.values.enumerated() {
                    add(value, row: row + offset, centered: true)
                }
            }

            var row = 30
            for entry in titlePage.entries where !used.contains(entry.key.lowercased()) {
                for value in entry.values where !value.isEmpty {
                    add(value, row: row, centered: false)
                    row += 1
                }
                row += 1
            }

            return PaginatedPage(
                index: 0,
                number: 0,
                label: nil,
                lines: lines,
                sceneIndices: [],
                sourceRange: titlePage.range,
                isTitlePage: true
            )
        }

        // MARK: Scene metrics

        private func measureScenes(_ pages: [PaginatedPage]) -> [SceneMetric] {
            var firstPage: [Int: Int] = [:]
            var lastPage: [Int: Int] = [:]
            var lineCounts: [Int: Int] = [:]

            for page in pages where !page.isTitlePage {
                for line in page.lines {
                    guard let scene = line.sceneIndex, !line.isBlank else { continue }
                    if firstPage[scene] == nil { firstPage[scene] = page.number }
                    lastPage[scene] = page.number
                    lineCounts[scene, default: 0] += 1
                }
            }

            return script.scenes.map { scene in
                let lines = lineCounts[scene.index] ?? 0
                let start = firstPage[scene.index] ?? 0
                let end = max(lastPage[scene.index] ?? start, start)
                return SceneMetric(
                    sceneIndex: scene.index,
                    number: scene.number,
                    heading: scene.heading,
                    pages: start...end,
                    lineCount: lines,
                    length: Eighths(lines: lines, linesPerPage: layout.linesPerPage)
                )
            }
        }
    }
}
