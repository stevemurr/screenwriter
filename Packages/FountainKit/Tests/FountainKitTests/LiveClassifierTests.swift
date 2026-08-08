import Foundation
import Testing
@testable import FountainKit

/// The live classifier exists to remove a flicker, and it is only allowed to do
/// that if it is never *wrong*. Every test here asks the same question in a
/// different way: does classifying a window around an edit give the same answer
/// the full parse gives for those same lines?
///
/// If it does not, the editor styles a line one way while typing and another way
/// 120ms later — which is a worse flicker than the one this replaced, because it
/// changes the text's meaning rather than just when it arrives.
@Suite("Live classification agrees with the full parse")
struct LiveClassifierTests {

    /// The kinds a full parse assigns to the lines covered by `window`.
    private func fullParseKinds(of window: NSRange, in source: String) -> [(NSRange, ElementKind)] {
        ScriptParser.parse(source).elements
            .filter { NSIntersectionRange($0.range, window).length > 0 || $0.range.length == 0 }
            .filter { NSLocationInRange($0.range.location, window) }
            .map { ($0.range, $0.kind) }
    }

    private func liveKinds(of window: NSRange, in source: String) -> [(NSRange, ElementKind)] {
        LiveClassifier.classify(window, in: source as NSString).map { ($0.range, $0.kind) }
    }

    /// Classifying a window must reproduce the full parse over that window, for
    /// every edit position in the document.
    private func agreesEverywhere(
        _ source: String,
        _ comment: Comment? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let ns = source as NSString
        let parsed = ScriptParser.parse(source)
        // A boneyard is explicitly out of scope — the caller refuses those
        // documents — so a script containing one would not be a fair test.
        #expect(
            !parsed.elements.contains { $0.kind == .boneyard },
            "this fixture must not contain a boneyard",
            sourceLocation: sourceLocation
        )

        for offset in 0...ns.length {
            let edit = NSRange(location: offset, length: 0)
            guard let window = LiveClassifier.window(for: edit, in: ns) else { continue }
            // Rule 7: the head of the document is the title page's, and the
            // caller refuses it. Skip what the caller would never ask for.
            if window.location == 0 { continue }

            let expected = fullParseKinds(of: window, in: source)
            let actual = liveKinds(of: window, in: source)
            let where_ = "\(comment?.description ?? "") window \(window) at offset \(offset)"
            #expect(
                expected.map(\.1) == actual.map(\.1),
                Comment(rawValue: "\(where_): full parse said \(expected.map(\.1)), "
                    + "live said \(actual.map(\.1))"),
                sourceLocation: sourceLocation
            )
            #expect(
                expected.map(\.0) == actual.map(\.0),
                Comment(rawValue: "\(where_): ranges diverged"),
                sourceLocation: sourceLocation
            )
        }
    }

    @Test("Every element kind, classified locally, matches the full pass")
    func everyKind() {
        agreesEverywhere(
            """
            INT. DINER - NIGHT

            Rain sheets the window. MARLA sits alone.

            MARLA
            (quietly)
            You said ten. It's a quarter past.
            And you are still not sorry.

            DEL ^
            Traffic.

            = She decides nothing at all.

            # Act One

            ## Sequence Two

            > CUT TO: <

            CUT TO:

            .FORCED HEADING

            !Forced action that looks like a heading: INT. NOWHERE

            @lowercase cue
            Forced dialogue.

            ~A lyric line

            [[a whole-line note]]

            ===

            EXT. PARKING LOT - CONTINUOUS #42#

            Neon pools in the potholes.
            """
        )
    }

    /// The case that made the forward walk cover two blocks rather than one.
    ///
    /// Splitting a block with a blank line reclassifies the lines *below* the
    /// new blank — they stop being dialogue and become action — and those lines
    /// are past the first blank the walk meets. A one-block window styled the
    /// half above the caret correctly and left the half below it wrong until the
    /// debounce fired, which is the exact flicker this removes.
    @Test("A blank line inserted mid-block reclassifies what follows it")
    func splittingABlock() {
        let before = "INT. ROOM - DAY\n\nMARLA\nYou said ten.\nIt's a quarter past.\n\nShe waits.\n"
        let after = "INT. ROOM - DAY\n\nMARLA\nYou said ten.\n\nIt's a quarter past.\n\nShe waits.\n"

        let caret = (before as NSString).range(of: "It's").location
        guard let window = LiveClassifier.window(
            for: NSRange(location: caret, length: 0),
            in: after as NSString
        ) else {
            Issue.record("no window for the split")
            return
        }

        let live = LiveClassifier.classify(window, in: after as NSString)
        let split = live.first { $0.text == "It's a quarter past." }
        #expect(split?.kind == .action, "the orphaned line is action once the block is split")
        #expect(
            NSMaxRange(window) >= (after as NSString).range(of: "It's").location,
            "the window must reach past the inserted blank line, or the line it reclassifies is never restyled"
        )
        agreesEverywhere(after, "after the split")
    }

    /// Deleting the blank line above a cue demotes it to dialogue, and the
    /// backward walk has to reach the block it just merged into.
    @Test("A blank line deleted above a cue demotes it")
    func mergingBlocks() {
        let after = "INT. ROOM - DAY\n\nShe waits.\nMARLA\nYou said ten.\n"
        let caret = (after as NSString).range(of: "MARLA").location
        guard let window = LiveClassifier.window(
            for: NSRange(location: caret, length: 0),
            in: after as NSString
        ) else {
            Issue.record("no window for the merge")
            return
        }
        let live = LiveClassifier.classify(window, in: after as NSString)
        #expect(live.first { $0.text == "MARLA" }?.kind == .action)
        #expect(window.location <= (after as NSString).range(of: "She waits.").location)
        agreesEverywhere(after, "after the merge")
    }

    /// A cue becomes a cue only once there is content under it, so typing the
    /// first character of the line below has to restyle the line above.
    @Test("Typing under an uppercase line promotes it to a cue")
    func promotingACue() {
        let source = "INT. ROOM - DAY\n\nMARLA\nY\n"
        let caret = (source as NSString).range(of: "Y").location
        guard let window = LiveClassifier.window(
            for: NSRange(location: caret, length: 1),
            in: source as NSString
        ) else {
            Issue.record("no window")
            return
        }
        let live = LiveClassifier.classify(window, in: source as NSString)
        #expect(live.first { $0.text == "MARLA" }?.kind == .character)
        #expect(live.first { $0.text == "Y" }?.kind == .dialogue)
    }

    @Test("Windows are refused where the parser needs the whole document")
    func refusals() {
        // The head of the document is the title page's; the caller checks this,
        // but the window still has to be *offered* so the caller can see it.
        let titled = "Title: A Script\nAuthor: Nobody\n\nINT. ROOM - DAY\n" as NSString
        #expect(LiveClassifier.window(for: NSRange(location: 3, length: 0), in: titled)?.location == 0)

        // A document with no blank line in it at all: refused rather than walked
        // to both ends on every keystroke.
        let wall = String(repeating: "Prose with no blank lines anywhere in it at all.\n", count: 600)
        let ns = wall as NSString
        #expect(LiveClassifier.window(for: NSRange(location: ns.length / 2, length: 0), in: ns) == nil)

        #expect(LiveClassifier.window(for: NSRange(location: 0, length: 0), in: "" as NSString) == nil)
    }

    /// Out-of-range edits must clamp rather than trap: the delegate is handed an
    /// edited range by AppKit, and a deletion at the end of the document reports
    /// a range that reaches the old length.
    @Test("Edited ranges outside the document clamp")
    func clamping() {
        let ns = "INT. ROOM - DAY\n\nShe waits.\n" as NSString
        #expect(LiveClassifier.window(for: NSRange(location: -5, length: 0), in: ns) != nil)
        #expect(LiveClassifier.window(for: NSRange(location: 9_999, length: 40), in: ns) != nil)
        #expect(LiveClassifier.window(for: NSRange(location: ns.length, length: 0), in: ns) != nil)
    }

    /// The strongest version of the claim: every edit position in every real
    /// screenplay on this machine.
    @Test("Agrees with the full parse across the reference corpus")
    func acrossTheCorpus() throws {
        guard !Corpus.relativePaths.isEmpty else {
            Corpus.recordAbsence("LiveClassifierTests.acrossTheCorpus")
            return
        }

        for path in Corpus.relativePaths {
            let source = try Corpus.source(of: path)
            let ns = source as NSString
            let parsed = ScriptParser.parse(source)
            // Boneyards are refused by the caller, and the title page owns the
            // head of the document.
            if parsed.elements.contains(where: { $0.kind == .boneyard }) { continue }
            let titlePageEnd = parsed.titlePage.map { NSMaxRange($0.range) } ?? 0

            let full = parsed.elements
            // Sampled rather than exhaustive: 17 scripts by every offset is
            // quadratic. Every 97th offset is co-prime with any line length in
            // the corpus, so it lands mid-line, at line starts, and on blanks.
            for offset in stride(from: 0, to: ns.length, by: 97) {
                guard let window = LiveClassifier.window(
                    for: NSRange(location: offset, length: 0), in: ns
                ), window.location >= titlePageEnd else { continue }

                let expected = full
                    .filter { NSLocationInRange($0.range.location, window) }
                    .map(\.kind)
                let actual = LiveClassifier.classify(window, in: ns).map(\.kind)
                #expect(
                    expected == actual,
                    Comment(rawValue: "\(path) at offset \(offset), window \(window): "
                        + "full parse \(expected) vs live \(actual)")
                )
            }
        }
    }
}
