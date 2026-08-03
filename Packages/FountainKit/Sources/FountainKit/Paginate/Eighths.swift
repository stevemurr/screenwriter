import Foundation

/// A length in eighths of a page — the unit a 1st AD actually schedules in.
///
/// A scene is never "0.87 pages"; it is `7/8`. Production paperwork has counted
/// in eighths since scripts were typed, because an eighth of a page is about an
/// inch of paper and an inch of paper is about a minute to shoot. The UI shows
/// `1 5/8 pp`, `7/8 pp`, `2 3/8 pp`, and this type is what produces those.
///
/// **The rounding rule: nearest eighth, with a floor of one.**
///
/// - *Nearest*, not up: rounding up is the other common convention, but with 95
///   scenes in the reference script it would inflate the total by up to twelve
///   pages against the same script's real page count. Rounding to nearest lets
///   the errors cancel, so the summed scene lengths stay honest against the
///   page count they are meant to explain.
/// - *Floor of one*: a two-line scene is 2/55 of a page, which rounds to zero.
///   A scene that exists takes time to shoot, so it reports `1/8`. Only a scene
///   with no printed lines at all is zero.
/// - Ties round away from zero, so 1.5 eighths is `2/8`, not `1/8`.
public struct Eighths: Sendable, Hashable, Comparable, CustomStringConvertible {
    /// The length in eighths. 8 is one page.
    public let total: Int

    public init(total: Int) {
        self.total = max(total, 0)
    }

    /// Measures `lines` of body text against a page of `linesPerPage`.
    public init(lines: Int, linesPerPage: Int) {
        guard lines > 0, linesPerPage > 0 else {
            self.init(total: 0)
            return
        }
        let exact = Double(lines) * 8 / Double(linesPerPage)
        self.init(total: max(Int(exact.rounded(.toNearestOrAwayFromZero)), 1))
    }

    public static let zero = Eighths(total: 0)

    /// Whole pages.
    public var pages: Int { total / 8 }
    /// The leftover eighths, 0...7.
    public var remainder: Int { total % 8 }
    /// The length as a fraction of a page, for arithmetic rather than display.
    public var pageFraction: Double { Double(total) / 8 }

    /// `2 3/8`, `7/8`, `3`. No unit — the caller appends `pp`, so a sidebar and
    /// a tooltip can disagree about that without disagreeing about the number.
    public var description: String {
        switch (pages, remainder) {
        case (0, 0): return "0"
        case (0, let eighths): return "\(eighths)/8"
        case (let pages, 0): return "\(pages)"
        case (let pages, let eighths): return "\(pages) \(eighths)/8"
        }
    }

    public static func < (lhs: Eighths, rhs: Eighths) -> Bool {
        lhs.total < rhs.total
    }

    public static func + (lhs: Eighths, rhs: Eighths) -> Eighths {
        Eighths(total: lhs.total + rhs.total)
    }
}

extension Sequence where Element == Eighths {
    /// Sums without re-rounding, so a section's length is the sum of its scenes'
    /// rounded lengths rather than a second approximation of an approximation.
    public var summed: Eighths {
        Eighths(total: reduce(0) { $0 + $1.total })
    }
}
