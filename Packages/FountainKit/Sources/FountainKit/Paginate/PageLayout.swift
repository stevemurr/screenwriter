import Foundation

/// US-Letter screenplay page geometry, in PostScript points.
///
/// Every number here was measured from the user's own Highland-produced PDFs
/// (48 of them; `Anal Informant - MASTER.pdf`, 83 pages, is canonical). This is
/// the single source of truth shared by the styled editing surface, the page
/// preview, and the PDF renderer — if they ever disagree, the preview stops
/// predicting the export, which is the one thing it exists to do.
public struct PageLayout: Sendable, Hashable {
    public var pageWidth: CGFloat = 612
    public var pageHeight: CGFloat = 792

    /// Courier Prime at 12pt. Monospaced, so wrapping is arithmetic rather than
    /// text measurement — see `charactersPerLine(for:)`.
    public var fontSize: CGFloat = 12
    public var characterWidth: CGFloat = 7.1904
    public var lineHeight: CGFloat = 12

    /// Baseline-box top of the body text — a 1.0" top margin.
    public var bodyTop: CGFloat = 72.672
    public var bodyBottom: CGFloat = 732.8

    /// Left edges by element, measured from the page's left edge.
    public var actionLeft: CGFloat = 108          // 1.5"
    public var dialogueLeft: CGFloat = 179
    public var parentheticalLeft: CGFloat = 207
    /// A fixed indent, *not* a centred cue. Verified across the corpus.
    public var characterLeft: CGFloat = 249
    public var moreLeft: CGFloat = 214.2

    /// Right edge shared by action and transitions.
    public var rightEdge: CGFloat = 561
    /// Page numbers are right-aligned to the 1" right margin.
    public var pageNumberRight: CGFloat = 540
    public var pageNumberBaseline: CGFloat = 48

    public init() {}

    public static let letter = PageLayout()

    /// Lines of body text per page: 55 at the measured geometry.
    public var linesPerPage: Int {
        Int(((bodyBottom - bodyTop) / lineHeight).rounded(.down)) + 1
    }

    /// Right edge for a given element kind.
    public func rightEdge(for kind: ElementKind) -> CGFloat {
        switch kind {
        case .dialogue, .parenthetical, .character, .lyrics:
            // Dialogue is inset symmetrically about the action column.
            return pageWidth - dialogueLeft
        default:
            return rightEdge
        }
    }

    /// Left edge for a given element kind.
    public func leftEdge(for kind: ElementKind) -> CGFloat {
        switch kind {
        case .character: return characterLeft
        case .parenthetical: return parentheticalLeft
        case .dialogue, .lyrics: return dialogueLeft
        default: return actionLeft
        }
    }

    /// How many characters fit on one line of the given element.
    ///
    /// Courier is monospaced and emphasis runs (`*bold*`, `_underline_`) do not
    /// change advance width, so this is exact rather than an estimate — no text
    /// measurement is needed anywhere in pagination.
    public func charactersPerLine(for kind: ElementKind) -> Int {
        let width = rightEdge(for: kind) - leftEdge(for: kind)
        return max(Int((width / characterWidth).rounded(.down)), 1)
    }

    /// The continuation cue printed at the top of a split dialogue block.
    /// Highland uses a curly apostrophe here, and matching it matters for a
    /// byte-level diff against their PDFs.
    public static func continuedCue(_ name: String) -> String {
        "\(name) (CONT\u{2019}D)"
    }

    public static let moreMarker = "(MORE)"
}
