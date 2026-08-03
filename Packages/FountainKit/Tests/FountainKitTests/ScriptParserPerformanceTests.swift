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

    /// Milliseconds of CPU actually spent on this thread.
    ///
    /// Not wall-clock: swift-testing runs suites concurrently, so a wall-clock
    /// budget measures how busy the machine happened to be rather than how much
    /// work the parser did. This suite failed in debug and passed in release for
    /// exactly that reason — in isolation both were comfortably inside budget.
    private static func cpuMilliseconds(_ body: () -> Void) -> Double {
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        body()
        return Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1_000_000
    }

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
            var script = ParsedScript.empty
            let elapsed = Self.cpuMilliseconds { script = ScriptParser.parse(source) }
            slowest = max(slowest, elapsed)
            #expect(script.scenes.count == 95)
        }

        // The budget is the 120ms debounce in `ScreenplayModel`, not a frame:
        // the parse runs off the main actor, so it never blocks typing.
        //
        // Measured in isolation on this machine: 16ms optimised, 30ms
        // unoptimised. The budget differs by configuration because otherwise it
        // measures the compiler rather than the parser — a single number either
        // fails spuriously in debug or is too loose to catch anything in
        // release. Both leave enough headroom for a slower machine while still
        // catching a real regression: an earlier version of this parser took
        // 25ms optimised, because `String.count` — a grapheme count — ran over
        // every line of the document.
        #if DEBUG
        let budget: Double = 90
        #else
        let budget: Double = 40
        #endif
        let slowestText = String(format: "%.2f", slowest)
        #expect(
            slowest < budget,
            "Full reparse took \(slowestText)ms CPU, over the budget. Consider incremental parsing."
        )
    }

    @Test("Parsing is linear enough to scale")
    func scaling() throws {
        let source = try #require(Self.largestScript)
        let doubled = source + "\n\n" + source

        func measure(_ text: String) -> Double {
            _ = ScriptParser.parse(text)
            // Best of three: CPU time is immune to other suites competing for
            // the machine, but not to this thread being descheduled mid-parse.
            return (0..<3)
                .map { _ in Self.cpuMilliseconds { _ = ScriptParser.parse(text) } }
                .min() ?? .infinity
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
