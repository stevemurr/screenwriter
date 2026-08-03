import Foundation
import Testing
@testable import FountainKit

/// Eighths are the unit the schedule is written in, so the rounding rule is a
/// product decision, not an implementation detail. These tests pin it.
@Suite("Eighths")
struct EighthsTests {

    @Test("A page is eight eighths")
    func wholePage() {
        let length = Eighths(lines: 55, linesPerPage: 55)
        #expect(length.total == 8)
        #expect(length.pages == 1)
        #expect(length.remainder == 0)
        #expect(length.description == "1")
    }

    @Test("Rounding is to the nearest eighth")
    func nearest() {
        // 6.875 lines to the eighth at 55 lines a page.
        #expect(Eighths(lines: 7, linesPerPage: 55).total == 1)     // 1.02 -> 1
        #expect(Eighths(lines: 10, linesPerPage: 55).total == 1)    // 1.45 -> 1
        #expect(Eighths(lines: 11, linesPerPage: 55).total == 2)    // 1.60 -> 2
        #expect(Eighths(lines: 41, linesPerPage: 55).total == 6)    // 5.96 -> 6
        #expect(Eighths(lines: 90, linesPerPage: 55).total == 13)   // 13.09 -> 13
    }

    @Test("A tie rounds away from zero")
    func ties() {
        // 8 lines of a 32-line page is exactly 2 eighths; 4 lines is exactly 1.
        #expect(Eighths(lines: 4, linesPerPage: 32).total == 1)
        // 6 lines of a 32-line page is 1.5 eighths.
        #expect(Eighths(lines: 6, linesPerPage: 32).total == 2)
    }

    @Test("A scene that exists is never zero eighths")
    func floorOfOneEighth() {
        // Two lines of a 55-line page rounds to zero and must not.
        #expect(Eighths(lines: 1, linesPerPage: 55).total == 1)
        #expect(Eighths(lines: 2, linesPerPage: 55).description == "1/8")
        // Only genuinely empty is zero.
        #expect(Eighths(lines: 0, linesPerPage: 55).total == 0)
        #expect(Eighths(lines: 0, linesPerPage: 55).description == "0")
    }

    @Test("Descriptions read the way the schedule does")
    func descriptions() {
        #expect(Eighths(total: 1).description == "1/8")
        #expect(Eighths(total: 7).description == "7/8")
        #expect(Eighths(total: 8).description == "1")
        #expect(Eighths(total: 13).description == "1 5/8")
        #expect(Eighths(total: 19).description == "2 3/8")
        #expect(Eighths(total: 24).description == "3")
    }

    @Test("Summing does not round a second time")
    func summing() {
        let scenes = [Eighths(total: 1), Eighths(total: 1), Eighths(total: 1)]
        #expect(scenes.summed.total == 3)
        #expect(scenes.summed.description == "3/8")
        #expect(([] as [Eighths]).summed == .zero)
    }

    @Test("Eighths order and add")
    func arithmetic() {
        #expect(Eighths(total: 3) < Eighths(total: 9))
        #expect((Eighths(total: 3) + Eighths(total: 9)).total == 12)
        #expect(Eighths(total: 12).pageFraction == 1.5)
    }

    @Test("A degenerate page never divides by zero")
    func degenerate() {
        #expect(Eighths(lines: 10, linesPerPage: 0).total == 0)
        #expect(Eighths(total: -4).total == 0)
    }
}
