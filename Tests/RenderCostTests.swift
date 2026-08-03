import AppKit
import FountainKit
import SwiftUI
import XCTest
@testable import Screenwriter

/// What the workspace costs per keystroke, per caret move, and per reparse.
///
/// A SwiftUI `body` that runs more often than it needs to is invisible: nothing
/// looks wrong, a sampling profile is a flat smear across the framework, and the
/// only symptom is that a long script feels heavier than a short one. So this
/// suite counts rather than guesses — "typing one character called `scrollTo`
/// once and rebuilt the outline four times" is a number, and a number can fail a
/// build.
///
/// **CPU time, never wall clock**, for the reason `ScriptParserPerformanceTests`
/// gives: the machine's load is not the thing under test. Counts are asserted in
/// Debug, which is the configuration the scheme's test action builds; the CPU
/// budgets are deliberately loose enough to hold in both, and the headline
/// numbers in the comments were taken in Release.
///
/// Two measurement traps this suite is shaped around, both of which produced
/// confident nonsense first:
///
/// - **Pumping the run loop measures the pump.** `RunLoop.run(mode:before:)` in
///   a loop burned ~80ms of CPU per 120ms whether the panes were open or shut,
///   which is more than everything being measured put together.
///   `layoutSubtreeIfNeeded()` + `displayIfNeeded()` drains the same SwiftUI
///   update with nothing else in the sample.
/// - **The editor buries everything.** One keystroke into the 91 KB reference
///   script costs ~12ms of AppKit and ~50ms of TextKit relayout before SwiftUI
///   is reached at all. The panes are therefore hosted on their own, with the
///   same inputs `RootView` gives them.
@MainActor
final class WorkspaceRenderCostTests: XCTestCase {

    /// Milliseconds of CPU actually spent on this thread.
    private static func cpuMilliseconds(_ body: () -> Void) -> Double {
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        body()
        return Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1_000_000
    }

    /// The largest script in the reference library: 91 KB, 95 scenes, 86 pages.
    private func corpusScript() throws -> String {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(
                "Code/github.com/stevemurr/screenplays/Anal Informant/anal-informant.fountain"
            )
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("Reference corpus not present on this machine.")
        }
        return source
    }

    private func hostWindow<V: View>(_ view: V, width: CGFloat) -> (NSWindow, NSHostingView<V>) {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 900)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        settle()
        return (window, hosting)
    }

    /// Drains SwiftUI's pending update synchronously and returns its CPU cost.
    @discardableResult
    private func flush(_ hosting: NSView) -> Double {
        Self.cpuMilliseconds {
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
        }
    }

    private func settle(_ seconds: TimeInterval = 0.6) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
    }

    // MARK: - The preview follows the page, not the caret

    /// The preview as it was written before: the raw caret offset as its input,
    /// and an animated `scrollTo` on every change of it.
    ///
    /// Kept so the regression test can watch the old shape misbehave rather than
    /// only watch the new one behave. Without this, "the preview no longer
    /// scrolls on every keystroke" is a claim about code nobody can see.
    private struct OffsetFollowingPreview: View {
        let paginated: PaginatedScript?
        let caretOffset: Int
        let scrolls: Box

        final class Box { var count = 0 }

        var body: some View {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 20) {
                        ForEach(paginated?.pages ?? []) { page in
                            Color.clear.frame(height: 40).id(page.index)
                        }
                    }
                }
                .onChange(of: caretOffset) { _, offset in
                    guard let index = paginated?.pageIndex(forSourceOffset: offset) else { return }
                    scrolls.count += 1
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(index, anchor: .top)
                    }
                }
            }
        }
    }

    private struct OffsetHarness: View {
        let paginated: PaginatedScript?
        var session: FountainEditorSession
        let scrolls: OffsetFollowingPreview.Box

        var body: some View {
            OffsetFollowingPreview(
                paginated: paginated,
                caretOffset: session.state.selectedRanges.first?.location ?? 0,
                scrolls: scrolls
            )
        }
    }

    private struct PreviewHarness: View {
        @Bindable var model: ScreenplayModel
        var session: FountainEditorSession

        /// Exactly what `RootView` hands the preview.
        private var caretPage: Int? {
            model.paginated?.pageIndex(
                forSourceOffset: session.state.selectedRanges.first?.location ?? 0
            )
        }

        var body: some View {
            PagePreview(
                paginated: model.paginated,
                caretPage: caretPage,
                showsPages: $model.previewShowsPages
            )
        }
    }

    /// Typing inside one page must not drag the preview back to that page's top.
    ///
    /// The old input was the caret offset, so every keystroke was a new view
    /// value and a fresh animated `scrollTo(page, anchor: .top)`. Two costs:
    /// `PagePreview.body` re-ran over all 86 pages on every keystroke, and — the
    /// part a writer actually notices — the preview snapped back to the top of
    /// the page, so the foot of a page could not be read while typing into it.
    ///
    /// Measured on the 95-scene reference script, Release, per caret move over
    /// the sidebar and preview together: **3.014ms → 1.032ms** of SwiftUI CPU.
    func testTypingWithinAPageDoesNotScrollThePreview() throws {
        let source = try corpusScript()
        let model = ScreenplayModel()
        model.load(source)
        let paginated = try XCTUnwrap(model.paginated)

        // Somewhere with a page above and below it, as a writer would be.
        let middle = (source as NSString).length / 2
        let page = try XCTUnwrap(paginated.pageIndex(forSourceOffset: middle))
        let stride = 20
        XCTAssertEqual(
            paginated.pageIndex(forSourceOffset: middle + stride), page,
            "This test needs \(stride) caret positions inside one page."
        )

        // --- The shape that shipped before.
        let legacySession = FountainEditorSession()
        let scrolls = OffsetFollowingPreview.Box()
        let (legacyWindow, legacyHosting) = hostWindow(
            OffsetHarness(paginated: paginated, session: legacySession, scrolls: scrolls),
            width: 700
        )
        legacySession.state.selectedRanges = [NSRange(location: middle, length: 0)]
        flush(legacyHosting)
        scrolls.count = 0
        for step in 1...stride {
            legacySession.state.selectedRanges = [NSRange(location: middle + step, length: 0)]
            flush(legacyHosting)
        }
        legacyWindow.orderOut(nil)
        XCTAssertEqual(
            scrolls.count, stride,
            "The old caret-offset input is supposed to scroll on every keystroke — if it "
                + "no longer does, this test has stopped reproducing what it guards against."
        )

        // --- What ships now.
        let session = FountainEditorSession()
        let (window, hosting) = hostWindow(
            PreviewHarness(model: model, session: session), width: 700
        )
        session.state.selectedRanges = [NSRange(location: middle, length: 0)]
        flush(hosting)

        #if DEBUG
        RenderCounters.reset()
        #endif
        var cpu = 0.0
        for step in 1...stride {
            session.state.selectedRanges = [NSRange(location: middle + step, length: 0)]
            cpu += flush(hosting)
        }
        window.orderOut(nil)

        #if DEBUG
        XCTAssertEqual(
            RenderCounters.previewScrolls, 0,
            "The preview scrolled \(RenderCounters.previewScrolls) times for \(stride) caret "
                + "moves inside one page. It can only ever scroll to a page top, so a caret "
                + "move that does not change page has nothing to scroll to — and scrolling "
                + "anyway throws away wherever the writer had scrolled to."
        )
        XCTAssertEqual(
            RenderCounters.previewBodies, 0,
            "PagePreview.body ran \(RenderCounters.previewBodies) times for \(stride) caret "
                + "moves inside one page. Its inputs must not carry the caret offset."
        )
        #endif

        // Loose enough for Debug and a busy machine; the old shape measured
        // 3.014ms per move in Release and 2.885ms in Debug.
        let perMove = cpu / Double(stride)
        XCTAssertLessThan(
            perMove, 2.5,
            String(format: "%.3fms of SwiftUI CPU per in-page caret move.", perMove)
        )
    }

    /// The point of following the caret at all: crossing a page break shows it.
    func testMovingToAnotherPageStillScrollsThePreview() throws {
        let source = try corpusScript()
        let model = ScreenplayModel()
        model.load(source)
        let paginated = try XCTUnwrap(model.paginated)

        let first = try XCTUnwrap(paginated.pages.first { !$0.isTitlePage })
        let later = try XCTUnwrap(paginated.pages.last)
        XCTAssertNotEqual(first.index, later.index)

        let session = FountainEditorSession()
        let (window, hosting) = hostWindow(
            PreviewHarness(model: model, session: session), width: 700
        )
        session.state.selectedRanges = [NSRange(location: first.sourceRange.location, length: 0)]
        flush(hosting)

        #if DEBUG
        RenderCounters.reset()
        #endif
        session.state.selectedRanges = [NSRange(location: later.sourceRange.location, length: 0)]
        flush(hosting)
        window.orderOut(nil)

        #if DEBUG
        XCTAssertEqual(
            RenderCounters.previewScrolls, 1,
            "Moving the caret to another page must still bring that page into view."
        )
        #endif
    }

    /// Why following by page rather than by offset costs nothing in behaviour:
    /// on the reference script, 86 of 89,287 caret positions change page.
    func testAlmostEveryCaretMoveStaysOnTheSamePage() throws {
        let source = try corpusScript()
        let model = ScreenplayModel()
        model.load(source)
        let paginated = try XCTUnwrap(model.paginated)

        var changes = 0
        var previous: Int?
        var moves = 0
        for offset in 0..<(source as NSString).length {
            guard let index = paginated.pageIndex(forSourceOffset: offset) else { continue }
            moves += 1
            if index != previous { changes += 1 }
            previous = index
        }

        XCTAssertGreaterThan(moves, 50_000, "The corpus script should be large.")
        let share = Double(changes) / Double(moves)
        XCTAssertLessThan(
            share, 0.01,
            String(
                format: "%d of %d caret positions change page (%.3f%%). Following the caret "
                    + "by offset made the other %.1f%% of scrolls pure loss.",
                changes, moves, share * 100, (1 - share) * 100
            )
        )
    }

    // MARK: - The sidebar derives its outline once

    private struct SidebarHarness: View {
        @Bindable var model: ScreenplayModel
        @State private var selection: OutlineSelection?

        var body: some View {
            OutlineSidebar(
                script: model.script,
                metrics: model.sceneMetrics,
                pageCount: model.pageCount,
                selection: $selection
            )
            .frame(width: Style.sidebarWidth)
        }
    }

    /// One body evaluation, one outline build.
    ///
    /// `isEmpty`, `visibleOutlineRows` (read twice) and `sectionIDs` were four
    /// separate computed properties, each of which rebuilt the whole outline
    /// from `script.scenes` and `script.sections`. So every body evaluation ran
    /// `OutlineTree.make` four times and `flatten` twice over all 95 scenes and
    /// threw three of the answers away. Nothing looked wrong — it was simply the
    /// same work, four times.
    ///
    /// Measured on the 95-scene script, Release: **0.2724ms → 0.0926ms** per
    /// body evaluation.
    func testTheSidebarBuildsItsOutlineOncePerBodyEvaluation() throws {
        #if DEBUG
        let source = try corpusScript()
        let model = ScreenplayModel()
        model.load(source)
        let (window, hosting) = hostWindow(SidebarHarness(model: model), width: Style.sidebarWidth)

        RenderCounters.reset()
        let reparses = 5
        for step in 1...reparses {
            model.text += "\n\nINT. ADDED SCENE \(step) - DAY\n\nSomething happens.\n"
            model.reparseNow()
            flush(hosting)
        }
        window.orderOut(nil)

        XCTAssertGreaterThan(
            RenderCounters.outlineBodies, 0,
            "The sidebar never re-rendered, so this test measured nothing."
        )
        XCTAssertEqual(
            RenderCounters.outlineTreeBuilds, RenderCounters.outlineBodies,
            "\(RenderCounters.outlineTreeBuilds) outline builds for "
                + "\(RenderCounters.outlineBodies) body evaluations. Every reader of the "
                + "outline inside one body must share a single build — this was 4 per body, "
                + "and the three extra answers were discarded."
        )
        #else
        throw XCTSkip("The render counters are Debug-only.")
        #endif
    }

    // MARK: - Drawing a page

    /// What one page of the preview costs to draw.
    ///
    /// `PageCanvas` builds an `AttributedString` per printed line on every
    /// redraw, which sounds alarming and measures at 0.19ms for a full page of
    /// 36 lines — because a redraw is rare, not because the work is free. The
    /// canvases are only rebuilt when the pagination changes: `PaginatedPage`
    /// compares equal otherwise, and comparing all 86 pages across a
    /// repagination costs 0.0032ms. Typing does not redraw them.
    ///
    /// This is a budget rather than a count because a count cannot be had:
    /// `Canvas` renders on its layer's own schedule and a test bundle's window
    /// never reaches a screen, so the draw closure does not run — not after
    /// `layoutSubtreeIfNeeded`, not after `displayIfNeeded`, and not after
    /// forcing it with `cacheDisplay(in:to:)`. All three were tried and all
    /// three report zero, which would make any such assertion pass vacuously.
    ///
    /// The emphasis path is the one that could go quadratic: it walks characters
    /// from the string's start for every run. Only 19 of the reference script's
    /// 3,247 printed lines carry emphasis at all, so it is not hot today — but
    /// it is the thing that would make it so.
    func testDrawingAPageStaysCheap() throws {
        let source = try corpusScript()
        let model = ScreenplayModel()
        model.load(source)
        let paginated = try XCTUnwrap(model.paginated)
        let page = try XCTUnwrap(paginated.pages.first { !$0.isTitlePage })
        let canvas = PageCanvas(page: page, layout: .letter, separated: true, scale: 0.5)
        let printed = page.lines.filter { !$0.isBlank }
        XCTAssertGreaterThan(printed.count, 20, "A full page should have been picked.")

        var sink = 0
        func draw() {
            for line in printed { sink &+= canvas.styled(line).characters.count }
        }
        draw()
        let ms = (0..<7).map { _ in Self.cpuMilliseconds(draw) }.min() ?? .infinity
        XCTAssertGreaterThan(sink, 0)

        // Measured in isolation on this machine: 0.19ms optimised, 0.27ms
        // unoptimised, for 36 printed lines.
        #if DEBUG
        let budget = 4.0
        #else
        let budget = 2.0
        #endif
        XCTAssertLessThan(
            ms, budget,
            String(
                format: "Styling %d printed lines took %.4fms of CPU.", printed.count, ms
            )
        )
    }

    /// Deriving the sidebar's rows must stay cheap, because it runs on every
    /// keystroke typed into the scene filter as well as on every reparse.
    func testTheOutlineDerivationStaysCheap() throws {
        let source = try corpusScript()
        let script = ScriptParser.parse(source)
        XCTAssertEqual(script.scenes.count, 95)

        // `sink` is read at the end so -O cannot delete the work being timed.
        var sink = 0
        func derive() {
            let tree = OutlineTree.make(from: script)
            sink &+= OutlineTree.flatten(tree, collapsedSections: []).count
            sink &+= Set(OutlineTree.sectionIDs(in: tree)).count
        }
        derive()
        let ms = (0..<7).map { _ in Self.cpuMilliseconds(derive) }.min() ?? .infinity
        XCTAssertGreaterThan(sink, 0)

        // Measured in isolation on this machine: 0.093ms optimised, 0.42ms
        // unoptimised. Budgets differ by configuration for the same reason the
        // parser suite's do — one number either flakes in Debug or catches
        // nothing in Release.
        #if DEBUG
        let budget = 3.0
        #else
        let budget = 1.0
        #endif
        XCTAssertLessThan(
            ms, budget,
            String(format: "Deriving the outline took %.4fms of CPU on 95 scenes.", ms)
        )
    }

    // MARK: - The board arranges its columns once

    private struct BoardHarness: View {
        @Bindable var model: ScreenplayModel
        @State private var selection: OutlineSelection?

        var body: some View {
            BeatBoardView(model: model, undoManager: nil, selection: $selection)
        }
    }

    /// `BoardLayout(script:)` walks every section and every scene, so reading
    /// the view's `layout` property more than once per body doubles it.
    ///
    /// This is a bound rather than an equality: how many times SwiftUI evaluates
    /// the board's body for a given reparse is its business and did vary between
    /// runs here (1 and 5 for the same five reparses). What must hold is that a
    /// body never arranges the board twice.
    func testTheBoardArrangesItsColumnsAtMostOncePerReparse() throws {
        #if DEBUG
        let source = try corpusScript()
        let model = ScreenplayModel()
        model.load(source)
        model.workspace = .board
        let (window, hosting) = hostWindow(BoardHarness(model: model), width: 1600)
        flush(hosting)

        RenderCounters.reset()
        let reparses = 5
        for step in 1...reparses {
            model.text += "\n\nINT. ADDED SCENE \(step) - DAY\n\nSomething happens.\n"
            model.reparseNow()
            flush(hosting)
        }
        window.orderOut(nil)

        XCTAssertLessThanOrEqual(
            RenderCounters.boardLayoutBuilds, reparses,
            "\(RenderCounters.boardLayoutBuilds) board layouts for \(reparses) reparses. "
                + "`layout` is a computed property over every section and scene; a body that "
                + "reads it twice pays for it twice."
        )
        #else
        throw XCTSkip("The render counters are Debug-only.")
        #endif
    }
}
