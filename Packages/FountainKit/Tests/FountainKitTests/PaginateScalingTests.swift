import Foundation
import Testing
@testable import FountainKit

/// How pagination scales, as opposed to how long it takes once.
///
/// `PaginatorPerformanceTests` guards the latency of the one script that
/// matters. This suite guards the shape of the curve, which is a different
/// failure: the paginator can stay comfortably inside its budget on every
/// script in the reference library and still fall off a cliff on input the
/// library does not contain.
///
/// It does contain one. **The tallest block in the whole library is 25 source
/// lines** — measured across all 76 scripts, 28 177 blocks, `.highland`
/// payloads included — so no real script has ever handed the splitter a block
/// that fills a page on its own. Paste a wall of prose into the editor and it
/// does. Everything here is therefore synthetic on purpose, and needs no
/// corpus.
@Suite("Pagination scaling")
struct PaginateScalingTests {

    /// Milliseconds of CPU actually spent on this thread.
    ///
    /// Not wall clock. swift-testing runs suites concurrently, so a wall-clock
    /// budget measures how busy the machine happened to be rather than how much
    /// work the paginator did — the lesson `ScriptParserPerformanceTests`
    /// records, and the reason this file does not use `DispatchTime`.
    static func cpuMilliseconds(_ body: () -> Void) -> Double {
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        body()
        return Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1_000_000
    }

    /// Best of two. CPU time is immune to another suite competing for the
    /// machine, but not to this thread being descheduled mid-run.
    static func fastest(_ body: () -> Void) -> Double {
        body()                                  // warm up
        return min(cpuMilliseconds(body), cpuMilliseconds(body))
    }

    /// One cue with `lines` spoken lines under it: a single block, taller than
    /// a page, which the page breaker has to split over and over.
    static func speech(lines: Int) -> String {
        var text = "INT. ROOM - DAY\n\nLENA\n"
        for index in 0..<lines { text += "Thirty four characters spoken, no \(index).\n" }
        return text
    }

    @Test("Splitting one tall block across many pages does not go quadratic")
    func splittingIsNotQuadratic() {
        let small = ScriptParser.parse(Self.speech(lines: 100))
        let large = ScriptParser.parse(Self.speech(lines: 800))
        #expect(Paginator.paginate(small).pageCount == 4)
        #expect(Paginator.paginate(large).pageCount == 31)

        let smallTime = Self.fastest { _ = Paginator.paginate(small) }
        let largeTime = Self.fastest { _ = Paginator.paginate(large) }
        let growth = largeTime / smallTime

        // Eight times the input. A cliff guard, not a proof of linearity: the
        // re-wrap of a carried tail is still quadratic in the height of the
        // block, and closing that would mean threading a row limit through
        // `LineWrap.wrap` for a shape no script in the library contains.
        //
        // What this does catch is the cliff that was there. `split` asked
        // `keptRows` — a linear scan of the block's rows — once per candidate
        // boundary, and scanned every candidate in the block rather than
        // stopping at the foot of the page. Growth over these two inputs,
        // measured on this machine: **66x optimised and 281x unoptimised**
        // before, **32x and 34x** after. 48 is the only budget that separates
        // them in both configurations, so it is deliberately snug — retune it
        // against all four numbers, not against one.
        let growthText = String(format: "%.1f", growth)
        #expect(
            growth < 48,
            """
            Eight times the block took \(growthText)x the time \
            (\(String(format: "%.2f", smallTime))ms → \
            \(String(format: "%.2f", largeTime))ms). \
            Splitting a block across a page has gone quadratic again.
            """
        )
    }

    @Test("Following the caret is a lookup, not a scan")
    func caretLookupDoesNotScanPages() {
        // The preview calls `page(forSourceOffset:)` while it draws and
        // `pageIndex(forSourceOffset:)` on every caret move, so this runs at
        // typing rate. It must not care how long the script is.
        let short = ScriptParser.parse(Self.speech(lines: 100))
        let long = ScriptParser.parse(Self.speech(lines: 800))
        let shortPages = Paginator.paginate(short)
        let longPages = Paginator.paginate(long)
        #expect(longPages.pageCount > shortPages.pageCount * 5)

        func perCall(_ paginated: PaginatedScript, _ length: Int) -> Double {
            var offsets: [Int] = []
            offsets.reserveCapacity(20_000)
            // Deterministic, and spread over the whole document so no run is
            // measuring one lucky page.
            var seed = 1
            for _ in 0..<20_000 {
                seed = (seed &* 1_103_515_245 &+ 12_345) & 0x3FFF_FFFF
                offsets.append(seed % max(length, 1))
            }
            return Self.fastest {
                for offset in offsets { blackHole(paginated.pageIndex(forSourceOffset: offset)) }
            }
        }

        let shortCost = perCall(shortPages, (short.source as NSString).length)
        let longCost = perCall(longPages, (long.source as NSString).length)
        let growth = longCost / shortCost

        // Eight times the pages. A binary search grows with the log — three
        // more comparisons out of six, so about 1.5x. A linear scan would grow
        // with the count, about 8x. 3 separates them with room for noise on
        // both sides.
        let growthText = String(format: "%.2f", growth)
        #expect(
            growth < 3,
            """
            Eight times the pages made the offset lookup \(growthText)x dearer. \
            `pageIndex(forSourceOffset:)` looks like a scan again, and the \
            preview calls it on every caret move.
            """
        )
    }

    @Test("A left-aligned line's x comes from its column, not from its text")
    func leftAlignedGeometryIgnoresText() {
        // `makePage` measures a line only to right-align or centre it. Nothing
        // left-aligned may depend on the text, which is what lets the measure
        // be skipped for the ~99% of lines that are left-aligned. If this ever
        // stops holding, that skip is wrong rather than merely slower.
        let layout = PageLayout.letter
        let script = ScriptParser.parse(
            """
            INT. A ROOM - DAY

            Short.

            A very much longer line of action indeed, long enough to wrap onto \
            a second printed line all by itself.

            LENA
            (a beat)
            Something spoken, and then rather more spoken after it so that this \
            wraps too.

            > CENTRED <

            CUT TO:
            """
        )
        let paginated = Paginator.paginate(script)
        for page in paginated.pages {
            for line in page.lines where !line.isBlank && line.alignment == .left {
                let expected = line.kind == .parenthetical && line.x != layout.parentheticalLeft
                    ? layout.parentheticalContinuationLeft
                    : (line.text == PageLayout.moreMarker ? layout.moreLeft : layout.leftEdge(for: line.kind))
                #expect(
                    line.x == expected,
                    "\(line.kind) '\(line.text)' sits at x=\(line.x), not its column's \(expected)."
                )
            }
        }

        // …and the two alignments that *do* measure still measure.
        let centred = paginated.pages.flatMap(\.lines).first { $0.alignment == .centered }
        let transition = paginated.pages.flatMap(\.lines).first { $0.alignment == .right }
        if let centred {
            let width = CGFloat(centred.text.unicodeScalars.count) * layout.characterWidth
            #expect(centred.x == (layout.pageWidth - width) / 2)
        }
        if let transition {
            let width = CGFloat(transition.text.unicodeScalars.count) * layout.characterWidth
            #expect(transition.x == layout.transitionRight - width)
        }
    }
}

/// Keeps a measured call from being optimised away without pretending to
/// assert anything about its result.
@inline(never)
private func blackHole<T>(_ value: T) {
    withExtendedLifetime(value) {}
}
