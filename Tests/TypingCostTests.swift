import AppKit
import FountainKit
import SwiftUI
import XCTest
@testable import Screenwriter

// MARK: - Shared harness

/// A script the size of the largest one in the reference library, built rather
/// than read so the budget tests run on every machine. ~90 KB, ~2,300 lines.
enum TypingWorkload {
    static let script: String = {
        var text = "Title: Budget\nCredit: Written by\nAuthor: Nobody\n\n"
        var index = 1
        while (text as NSString).length < 89_000 {
            text += """
            INT. LOCATION \(index) - NIGHT

            Rain maps the windows in silver veins while somebody waits for a
            door that is not going to open, and the room keeps its own counsel.

            MARA
            (quietly)
            We built a room with no shadows, and then we lived in it — and the
            light never once asked us how we were getting on.

            = She decides.

            # Sequence \(index)

            > CUT TO:

            """
            index += 1
        }
        return text
    }()

    /// The largest script in the reference library, when it is on this machine.
    static var corpusScript: String? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(
                "Code/github.com/stevemurr/screenplays/Anal Informant/anal-informant.fountain"
            )
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Milliseconds of CPU actually spent on the calling thread.
    ///
    /// Not wall clock: these tests run alongside every other suite in the
    /// bundle, so a wall-clock budget measures how busy the machine was rather
    /// than how much work a keystroke did. The same reasoning as
    /// `ScriptParserPerformanceTests`, and it matters more here, because every
    /// number in this file is main-*actor* time.
    static func cpuMilliseconds(_ body: () -> Void) -> Double {
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        body()
        return Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1_000_000
    }
}

// MARK: - What a keystroke costs

/// The typing path, end to end, on the main actor.
///
/// Measured before this suite existed, in a release build, on the 91 KB script
/// with the caret in the middle of it: **12.8ms of main-actor CPU per
/// keystroke**, of which AppKit's own text handling was 0.8ms. Two things were
/// responsible, and both are now guarded here:
///
/// * `captureState` built a whole `LineIndex` over the document to find the
///   caret's line and column — twice per keystroke, 3.2ms;
/// * `emitTextIfChanged` handed out `textView.string`, a lazily bridged
///   `NSString`, so comparing it here and again in `ScreenplayModel.text`'s
///   `didSet` re-transcoded the whole document twice — 7.9ms.
///
/// After: 1.3ms, of which 0.8ms is AppKit.
@MainActor
final class TypingCostTests: XCTestCase {

    private func makeEditor(
        _ source: String
    ) -> (host: EditorHostView, model: ScreenplayModel, coordinator: FountainEditorSurface.Coordinator) {
        let model = ScreenplayModel()
        model.load(source)
        model.mode = .styled

        let host = EditorHostView(frame: NSRect(x: 0, y: 0, width: 760, height: 600))
        host.setScriptColumn(Style.scriptColumnWidth)
        host.textView.string = source
        host.layoutSubtreeIfNeeded()

        let styler = ElementStyler(mode: .styled, fontSize: 12)
        host.applyStyle(base: styler.baseAttributes(), runs: styler.runs(for: model.script))
        host.layoutSubtreeIfNeeded()

        let surface = FountainEditorSurface(
            text: Binding(get: { model.text }, set: { model.text = $0 }),
            script: model.script,
            diagnostics: model.diagnostics,
            mode: .styled,
            fontSize: 12,
            revision: model.revision,
            replacementToken: model.replacementToken,
            session: FountainEditorSession()
        )
        let coordinator = surface.makeCoordinator()
        coordinator.host = host
        host.textView.delegate = coordinator
        coordinator.observeViewport(for: host)

        // Type in the middle of a scrolled document, which is the real case.
        host.textView.setSelectedRange(NSRange(location: (source as NSString).length / 2, length: 0))
        host.scrollView.contentView.scroll(
            to: NSPoint(x: 0, y: (host.textView.frame.height / 2).rounded())
        )
        host.scrollView.reflectScrolledClipView(host.scrollView.contentView)
        host.layoutSubtreeIfNeeded()
        return (host, model, coordinator)
    }

    /// Median main-actor CPU for one `insertText`, warmed up first.
    private func medianKeystroke(_ host: EditorHostView) -> Double {
        for _ in 0..<5 {
            host.textView.insertText("w", replacementRange: host.textView.selectedRange())
        }
        var samples = (0..<25).map { _ in
            TypingWorkload.cpuMilliseconds {
                host.textView.insertText("w", replacementRange: host.textView.selectedRange())
            }
        }
        samples.sort()
        return samples[samples.count / 2]
    }

    func testOneKeystrokeStaysInsideAFrame() throws {
        let (host, _, _) = makeEditor(TypingWorkload.script)
        let median = medianKeystroke(host)

        // Measured on this machine: 1.56ms release, 2.03ms debug, against
        // 0.95ms for AppKit inserting the character with no delegate attached.
        // Before this work it was 12.8ms release. One budget for both
        // configurations because the two are close — everything expensive here
        // is Foundation and AppKit, already compiled optimised either way — with
        // roughly three times the headroom for a slower machine, which still
        // catches a regression of the size that was here.
        let budget: Double = 6.0
        XCTAssertLessThan(
            median, budget,
            "A keystroke on a 90 KB script cost \(String(format: "%.2f", median))ms of main-actor "
                + "CPU. This is the number the writer feels. It was 12.8ms before "
                + "EditorText.snapshot and EditorText.lineAndColumn."
        )
    }

    /// Where the old cost was: bounded by AppKit's own share, not a multiple of it.
    func testOurShareOfAKeystrokeIsSmallerThanAppKitsOwn() throws {
        let bare = EditorHostView(frame: NSRect(x: 0, y: 0, width: 760, height: 600))
        bare.setScriptColumn(Style.scriptColumnWidth)
        bare.textView.string = TypingWorkload.script
        bare.layoutSubtreeIfNeeded()
        let styler = ElementStyler(mode: .styled, fontSize: 12)
        let parsed = ScriptParser.parse(TypingWorkload.script)
        bare.applyStyle(base: styler.baseAttributes(), runs: styler.runs(for: parsed))
        bare.layoutSubtreeIfNeeded()
        bare.textView.setSelectedRange(
            NSRange(location: (TypingWorkload.script as NSString).length / 2, length: 0)
        )
        bare.scrollView.contentView.scroll(
            to: NSPoint(x: 0, y: (bare.textView.frame.height / 2).rounded())
        )
        bare.scrollView.reflectScrolledClipView(bare.scrollView.contentView)
        bare.layoutSubtreeIfNeeded()
        // No delegate: AppKit inserting a character and relaying out, nothing else.
        let appKitAlone = medianKeystroke(bare)

        let (host, _, _) = makeEditor(TypingWorkload.script)
        let withEditor = medianKeystroke(host)
        let ours = withEditor - appKitAlone

        XCTAssertLessThan(
            ours, appKitAlone * 3,
            "Our delegate work is \(String(format: "%.2f", ours))ms against AppKit's own "
                + "\(String(format: "%.2f", appKitAlone))ms. It used to be 12.0ms against 0.8ms — "
                + "fifteen times what inserting the character cost."
        )
    }

    /// The status bar's word count must not be recomputed at typing rate.
    ///
    /// `ParsedScript.wordCount` splits every printable element's text on each
    /// read, walking grapheme clusters: 14.0ms on the 91 KB script in release.
    /// `StatusBar.body` reads it, and that body re-runs on every keystroke
    /// because the caret readout beside it changes.
    func testWordCountIsNotRecomputedOnEveryRead() throws {
        let model = ScreenplayModel()
        model.load(TypingWorkload.script)
        XCTAssertGreaterThan(model.wordCount, 1_000)
        XCTAssertEqual(model.wordCount, model.script.wordCount, "the cached count must be the real one")

        _ = model.wordCount
        let elapsed = TypingWorkload.cpuMilliseconds {
            for _ in 0..<200 { _ = model.wordCount }
        }
        XCTAssertLessThan(
            elapsed, 5.0,
            "200 reads of model.wordCount cost \(String(format: "%.2f", elapsed))ms. It is stored "
                + "for a reason: computing it from the script costs 14ms a read."
        )
    }

    /// `emitTextIfChanged` still does both halves of its job.
    ///
    /// It is the path undo depends on — a programmatic undo mutates storage
    /// without `textDidChange`, so the binding is pushed from here instead —
    /// which means it has to notice a change it did not cause, and stay a no-op
    /// when there is nothing to push. Driven directly rather than through
    /// `undoManager`, which is nil for a text view with no window.
    func testEmitPushesAChangeItDidNotCauseAndOtherwiseDoesNothing() throws {
        let (host, model, coordinator) = makeEditor("INT. ROOM - DAY\n\nShe waits.\n")
        let original = model.text

        // Mutate the storage behind the delegate's back, as undo does.
        host.textView.textStorage?.replaceCharacters(
            in: NSRange(location: 0, length: 0), with: "X"
        )
        XCTAssertEqual(model.text, original, "nothing should have reached the model yet")

        coordinator.emitTextIfChanged()
        XCTAssertEqual(model.text, "X" + original)
        XCTAssertEqual(model.text, host.textView.string)

        let revision = model.revision
        coordinator.emitTextIfChanged()
        XCTAssertEqual(model.text, "X" + original, "a second emit must be a no-op")
        XCTAssertEqual(model.revision, revision)
    }

    /// Confirms the diagnosis rather than assuming it.
    ///
    /// Reproduces what `captureState` used to do — build a `LineIndex` over the
    /// whole document, twice per keystroke, to find the caret's line and column
    /// — and shows it costing many times what the whole editor now costs. If
    /// this stops failing, the caret readout was never the problem and the
    /// scan is aimed at the wrong thing.
    func testTheOldCaretReadoutWasTheExpensivePart() throws {
        let (host, _, _) = makeEditor(TypingWorkload.script)
        let now = medianKeystroke(host)

        let ns = TypingWorkload.script as NSString
        let caret = ns.length / 2
        _ = LineIndex(source: TypingWorkload.script)

        // --- what captureState used to do, twice per keystroke --------------
        var old = (0..<5).map { _ in
            TypingWorkload.cpuMilliseconds {
                for _ in 0..<2 {
                    let index = LineIndex(source: host.textView.string)
                    let line = index.lineNumber(containing: caret)
                    _ = (line + 1, caret - index.lineStarts[line] + 1)
                }
            }
        }
        // --------------------------------------------------------------------
        old.sort()
        let oldMedian = old[old.count / 2]

        XCTAssertGreaterThan(
            oldMedian, now,
            "Indexing the whole document for the caret readout cost "
                + "\(String(format: "%.2f", oldMedian))ms against \(String(format: "%.2f", now))ms "
                + "for an entire keystroke now — so the LineIndex build was not the cost after all."
        )
    }
}

// MARK: - The snapshot

/// `NSTextView.string` is a window onto the text view's storage, not a value.
///
/// This is the correctness half of the typing work. The editor used to store
/// `textView.string` straight into `ScreenplayModel.text`, and on a document
/// large enough for Swift to bridge lazily that stored "value" went on changing
/// as the writer typed. Two guards written to be correct could not fire:
/// `ScreenplayModel.apply(_:for:)` compared the model's text against the source
/// a parse ran on, and both were the same live buffer; and the detached parse
/// read storage the main thread was mutating.
@MainActor
final class EditorTextSnapshotTests: XCTestCase {

    func testSnapshotDoesNotChangeWhenTheTextViewDoes() throws {
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.string = TypingWorkload.script
        let snapshot = EditorText.snapshot(of: textView.string as NSString)
        let length = (snapshot as NSString).length

        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.insertText("ZZZZ", replacementRange: NSRange(location: 0, length: 0))

        XCTAssertEqual((snapshot as NSString).length, length)
        XCTAssertFalse(snapshot.hasPrefix("ZZZZ"))
        XCTAssertEqual((textView.string as NSString).length, length + 4)
    }

    func testSnapshotIsByteExact() throws {
        for sample in [
            "",
            "a",
            "INT. ROOM - DAY\n\nShe waits.\n",
            // The corpus is full of these, and they are what makes the bridge
            // lazy rather than a plain ASCII copy.
            "“Smart quotes” — an em dash, an ellipsis…\nand a line after it.\n",
            "emoji \u{1F3AC}\u{1F3AC} and a combining mark: e\u{0301}\n",
            TypingWorkload.script
        ] {
            let textView = NSTextView(usingTextLayoutManager: true)
            textView.string = sample
            XCTAssertEqual(EditorText.snapshot(of: textView.string as NSString), sample)
        }
    }

    /// An unpaired surrogate cannot be represented in a Swift `String` at all,
    /// so it becomes U+FFFD — but nothing after it may be lost.
    ///
    /// `getBytes(…encoding: .utf8…)` was the faster candidate and does exactly
    /// that: it returns `true` and drops the rest of the document. Silently
    /// truncating the writer's script is not a trade available to us.
    func testSnapshotDoesNotTruncateOnMalformedText() throws {
        let broken = NSMutableString(string: "before")
        broken.append(NSString(characters: [0xD800], length: 1) as String)
        broken.append("after")
        let snapshot = EditorText.snapshot(of: broken)
        XCTAssertTrue(snapshot.hasPrefix("before"))
        XCTAssertTrue(
            snapshot.hasSuffix("after"),
            "the snapshot lost everything after a lone surrogate: \(snapshot.debugDescription)"
        )
    }

    /// The invariant the model depends on, at the level the editor works at.
    ///
    /// `ScreenplayModel.apply(_:for:)` discards a parse the document has moved
    /// past by comparing its text against the source that parse ran on. That
    /// only means anything if the text it was handed is a value.
    ///
    /// Note on reproducing the original bug: whether `textView.string` aliases
    /// turns out to depend on process-global bridging state — from a cold
    /// process it aliased every time, on the reference script and on synthetic
    /// ones, but after any earlier `getCharacters` call in the same process it
    /// copies. So this asserts the property that must hold rather than
    /// asserting the old code fails, which would be flaky by test ordering.
    func testTheModelsTextDoesNotMoveWhileTheWriterKeepsTyping() throws {
        let model = ScreenplayModel()
        model.load(TypingWorkload.script)
        let host = EditorHostView(frame: NSRect(x: 0, y: 0, width: 760, height: 600))
        host.textView.string = TypingWorkload.script
        host.layoutSubtreeIfNeeded()

        let surface = FountainEditorSurface(
            text: Binding(get: { model.text }, set: { model.text = $0 }),
            script: model.script, diagnostics: model.diagnostics, mode: .styled,
            fontSize: 12, revision: model.revision,
            replacementToken: model.replacementToken, session: FountainEditorSession()
        )
        let coordinator = surface.makeCoordinator()
        coordinator.host = host
        host.textView.setSelectedRange(NSRange(location: 0, length: 0))
        host.textView.insertText("A", replacementRange: NSRange(location: 0, length: 0))
        coordinator.emitTextIfChanged()

        // What a detached parse would have been handed.
        let handedToTheParser = model.text
        let length = (handedToTheParser as NSString).length

        // The writer keeps going while that parse is in flight.
        for _ in 0..<8 {
            host.textView.insertText("B", replacementRange: NSRange(location: 0, length: 0))
        }

        XCTAssertEqual(
            (handedToTheParser as NSString).length, length,
            "the string handed to the parser grew underneath it"
        )
        XCTAssertTrue(handedToTheParser.hasPrefix("A"))
        XCTAssertFalse(handedToTheParser.hasPrefix("B"))
        XCTAssertNotEqual(handedToTheParser, host.textView.string)
    }
}

// MARK: - The caret readout

/// The status bar wants two integers; it used to build a `LineIndex` over the
/// whole document to get them, twice per keystroke.
@MainActor
final class CaretPositionTests: XCTestCase {

    func testAgreesWithLineIndexEverywhereInsideTheDocument() throws {
        let source = TypingWorkload.script
        let ns = source as NSString
        let index = LineIndex(source: source)

        // Line boundaries, where an off-by-one would hide, plus a scattering
        // through the body. Sampled rather than exhaustive: the scan is O(caret)
        // by design, so checking every offset would be quadratic.
        var offsets: [Int] = []
        for start in stride(from: 0, to: index.lineStarts.count, by: 11) {
            offsets.append(index.lineStarts[start])
            offsets.append(index.lineStarts[start] + 1)
            offsets.append(max(index.lineStarts[start] - 1, 0))
        }
        offsets.append(contentsOf: stride(from: 0, to: ns.length, by: 3_331))
        offsets.append(ns.length - 1)

        for offset in offsets where offset >= 0 && offset < ns.length {
            let line = index.lineNumber(containing: offset)
            let expected = (line: line + 1, column: offset - index.lineStarts[line] + 1)
            let actual = EditorText.lineAndColumn(in: ns, at: offset)
            XCTAssertEqual(actual.line, expected.line, "line at offset \(offset)")
            XCTAssertEqual(actual.column, expected.column, "column at offset \(offset)")
        }
    }

    func testAgreesWithLineIndexOnTheReferenceScript() throws {
        guard let source = TypingWorkload.corpusScript else {
            throw XCTSkip("Reference corpus not present on this machine.")
        }
        let ns = source as NSString
        let index = LineIndex(source: source)
        for offset in stride(from: 0, to: ns.length, by: 313) {
            let line = index.lineNumber(containing: offset)
            let actual = EditorText.lineAndColumn(in: ns, at: offset)
            XCTAssertEqual(actual.line, line + 1, "line at offset \(offset)")
            XCTAssertEqual(actual.column, offset - index.lineStarts[line] + 1, "column at \(offset)")
        }
    }

    /// The corpus is full of smart quotes and dashes, and the scan works in
    /// UTF-16 units, so a scalar whose encoding *contains* a 0x0A byte must not
    /// be mistaken for a line break: U+0A15 encodes as 0x0A15 and U+3A0A as
    /// 0x3A0A. Emoji are surrogate pairs, which are two units for one character.
    func testAgreesWithLineIndexThroughNonASCII() throws {
        let source = "a\nsmart “quote” — dash…\nU+0A15: \u{0A15}\nU+3A0A: \u{3A0A}\n"
            + "\u{1F3AC}\u{1F3AC}\ncombining e\u{0301}\nend"
        let ns = source as NSString
        let index = LineIndex(source: source)
        for offset in 0..<ns.length {
            let line = index.lineNumber(containing: offset)
            let actual = EditorText.lineAndColumn(in: ns, at: offset)
            XCTAssertEqual(actual.line, line + 1, "line at offset \(offset)")
            XCTAssertEqual(actual.column, offset - index.lineStarts[line] + 1, "column at \(offset)")
        }
        XCTAssertEqual(EditorText.lineAndColumn(in: ns, at: ns.length).line, 7)
    }

    func testClampsOutsideTheDocument() throws {
        let ns = "one\ntwo\n" as NSString
        XCTAssertEqual(EditorText.lineAndColumn(in: ns, at: -5).line, 1)
        XCTAssertEqual(EditorText.lineAndColumn(in: ns, at: -5).column, 1)
        XCTAssertEqual(EditorText.lineAndColumn(in: ns, at: 9_999).line, 3)
    }

    func testEmptyDocument() throws {
        let position = EditorText.lineAndColumn(in: "" as NSString, at: 0)
        XCTAssertEqual(position.line, 1)
        XCTAssertEqual(position.column, 1)
    }

    /// The caret on the empty line after a trailing newline.
    ///
    /// `LineIndex` deliberately does not create a phantom line for a document
    /// ending in `\n` — the parser has no line there to classify. The caret
    /// does sit on one, though, so the old readout reported the *previous* line
    /// and a column past its end. This is the one place the two disagree, and
    /// the scan is the one that matches what the writer sees.
    func testCaretAfterATrailingNewlineIsOnTheNewLine() throws {
        let source = "one\ntwo\n"
        let ns = source as NSString
        let caret = ns.length

        let position = EditorText.lineAndColumn(in: ns, at: caret)
        XCTAssertEqual(position.line, 3)
        XCTAssertEqual(position.column, 1)

        // What LineIndex says, so the difference is written down rather than
        // discovered again.
        let index = LineIndex(source: source)
        let line = index.lineNumber(containing: caret)
        XCTAssertEqual(line + 1, 2)
        XCTAssertEqual(caret - index.lineStarts[line] + 1, 5)
    }
}

// MARK: - The debounce

/// Nothing was wrong here, and that is worth pinning.
///
/// A burst of keystrokes must collapse into one reparse: `scheduleReparse`
/// cancels the outstanding task before starting the next, and the sleep is
/// checked for cancellation before any work runs. Measured: 40 edits, one
/// parse.
@MainActor
final class ReparseDebounceTests: XCTestCase {

    func testABurstOfEditsCollapsesIntoOneReparse() async throws {
        let model = ScreenplayModel()
        model.load(TypingWorkload.script)
        let before = model.revision

        for step in 0..<40 {
            model.text.append("x")
            // Yield now and then, as a real typist does between characters.
            if step % 8 == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        }
        try? await Task.sleep(for: .milliseconds(900))

        XCTAssertEqual(
            model.revision - before, 1,
            "40 edits produced \(model.revision - before) reparses. The debounce is no longer "
                + "coalescing, so a burst of typing runs the parser once per character."
        )
        XCTAssertEqual(model.script.source, model.text)
    }
}
