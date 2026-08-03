import Foundation
import Testing
@testable import FountainKit

/// The parser is a full linear reparse, not an incremental one. That is only
/// defensible because `ScreenplayModel` runs it **off the main actor behind a
/// coalescing debounce** — measured at ~15ms on the largest script in the
/// reference library, an inline reparse per keystroke would drop frames.
///
/// This suite guards the two properties that decision rests on: the parse stays
/// well inside the debounce window, and it stays linear. If either fails,
/// incremental parsing stops being premature optimisation and becomes required.
@Suite("Parser performance")
struct ScriptParserPerformanceTests {

    /// The largest script in the reference library, 91 KB.
    private static var largestScript: String? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(
                "Code/github.com/stevemurr/screenplays/Anal Informant/anal-informant.fountain"
            )
        return try? String(contentsOf: url, encoding: .utf8)
    }

    @Test("A full reparse of the largest script stays inside the debounce window")
    func fullReparseLatency() throws {
        let source = try #require(
            Self.largestScript,
            "Reference corpus not present on this machine."
        )

        // Warm up, so the measurement is not dominated by first-touch faults.
        _ = ScriptParser.parse(source)

        var slowest: Double = 0
        for _ in 0..<10 {
            let start = DispatchTime.now().uptimeNanoseconds
            let script = ScriptParser.parse(source)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            slowest = max(slowest, elapsed)
            #expect(script.scenes.count == 95)
        }

        // The budget is the 120ms debounce in `ScreenplayModel`, not a frame:
        // the parse runs off the main actor, so it never blocks typing. 40ms
        // leaves room for a machine slower than this one while still catching a
        // real regression — an earlier version of this parser took 25ms because
        // `String.count` (a grapheme count) ran on every line.
        let slowestText = String(format: "%.2f", slowest)
        #expect(
            slowest < 40,
            "Full reparse took \(slowestText)ms, over the 40ms budget. Consider incremental parsing."
        )
    }

    @Test("Parsing is linear enough to scale")
    func scaling() throws {
        let source = try #require(Self.largestScript)
        let doubled = source + "\n\n" + source

        func measure(_ text: String) -> Double {
            _ = ScriptParser.parse(text)
            let start = DispatchTime.now().uptimeNanoseconds
            _ = ScriptParser.parse(text)
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }

        let single = measure(source)
        let double = measure(doubled)
        // Generous bound: catches an accidental O(n²) without being flaky about
        // ordinary timing noise.
        let doubleText = String(format: "%.2f", double)
        let singleText = String(format: "%.2f", single)
        #expect(
            double < single * 4 + 5,
            "Doubling the input took \(doubleText)ms vs \(singleText)ms — parsing may not be linear."
        )
    }
}
