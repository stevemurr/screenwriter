import Foundation
import Testing
@testable import FountainKit

/// The parser is a full linear reparse, not an incremental one. That is only
/// defensible because `ScreenplayModel` runs it **off the main actor behind a
/// coalescing debounce** — and it is comfortable rather than marginal now that
/// the largest script in the reference library parses in ~1.6ms rather than
/// ~16.8ms.
///
/// This suite guards the two properties that decision rests on: the parse stays
/// well inside the debounce window, and it stays linear. If either fails,
/// incremental parsing stops being premature optimisation and becomes required.
///
/// The equivalence of the fast paths that got it there lives next door, in
/// `ParserFastPathTests`. Speed without that is not worth having.
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
        // Measured in isolation on an M1 Max: **1.6ms optimised, 9.4ms
        // unoptimised**. The budget differs by configuration because otherwise
        // it measures the compiler rather than the parser — a single number
        // either fails spuriously in debug or is too loose to catch anything in
        // release.
        //
        // These numbers were 16.8ms and 30ms until every line stopped being a
        // bridged `NSString`; see `ParserFastPathTests`. The budget came down
        // with them deliberately. A budget of 40ms against a 1.6ms parse would
        // let a twenty-five-fold regression through in silence, which is how the
        // `String.count` regression survived as long as it did. What is left is
        // roughly 5x headroom in release and 3x in debug — enough for a slower
        // machine, not enough to hide a mistake.
        #if DEBUG
        let budget: Double = 30
        #else
        let budget: Double = 8
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
