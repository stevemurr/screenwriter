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
    /// Transitions are right-aligned to this, *not* to `rightEdge`. Measured:
    /// `CUT TO:` sits at x=513.633 and `CUT BACK TO:` at x=477.656, and both
    /// end at 564.0.
    public var transitionRight: CGFloat = 564
    /// Page numbers are right-aligned to the 1" right margin.
    public var pageNumberRight: CGFloat = 540
    public var pageNumberBaseline: CGFloat = 48
    /// Title-page rows are set 1.2× rather than solid: 14.4pt apart, with the
    /// first row's baseline at y=579.4 in PDF coordinates.
    public var titleLineHeight: CGFloat = 14.4
    public var titleBlockTop: CGFloat = 204.272

    // MARK: - Character measures
    //
    // The wrap width of each column, in characters. These are measured, not
    // derived: taking the longest line Highland ever drew at each x across the
    // 20 exports whose source is identifiable gives 63 / 34 / 29 out of 38 896,
    // 32 504 and 6 269 samples respectively. Deriving them instead — dialogue
    // inset symmetrically about the action column, `(612 - 179 - 179) / 7.1904`
    // — yields 35, one too many, and re-wraps roughly one dialogue line in
    // twelve. The columns are simply not symmetric.

    /// Action, transitions, centred text, and sections.
    public var actionMeasure: Int = 63
    public var dialogueMeasure: Int = 34
    public var parentheticalMeasure: Int = 29
    /// A parenthetical's second and later lines hang at x=214.195 and stop two
    /// characters short of the first line's right edge. Both maxima are exact
    /// over 6 269 first lines and 788 continuations.
    public var parentheticalContinuationMeasure: Int = 27
    /// Scene headings stop short of the action column's right edge, leaving the
    /// 7"–7.5" gutter for a scene number.
    ///
    /// The corpus pins this to 54...57 and no tighter: `INT. FBI BUILDING -
    /// SUPERVISOR'S OFFICE - CONTINUOUS` (52) and a 54-character first line of
    /// a wrapped heading both fit, while `INT. BANNISTER RESIDENCE - GREENHOUSE
    /// - NIGHT - CONTINUOUS` (58) wraps. 55 is the value that falls on a round
    /// 7.0" right edge, which is where a design would put it.
    public var sceneHeadingMeasure: Int = 55

    public init() {}

    public static let letter = PageLayout()

    /// Lines of body text per page: 55 at the measured geometry.
    ///
    /// `bodyTop` is the top of the first line's box and `bodyBottom` the bottom
    /// of the last one's, so the count is the plain quotient — an earlier `+ 1`
    /// here counted the first line twice and returned 56. The oracle is
    /// unambiguous: Highland's first baseline is at y=711 and its last at y=63,
    /// which is 55 lines of 12pt.
    public var linesPerPage: Int {
        max(Int(((bodyBottom - bodyTop) / lineHeight).rounded(.down)), 1)
    }

    /// Right edge for a given element kind.
    public func rightEdge(for kind: ElementKind) -> CGFloat {
        leftEdge(for: kind) + CGFloat(charactersPerLine(for: kind)) * characterWidth
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
    /// The measure for the second and later lines of an element. Only a
    /// parenthetical differs from its own first line.
    public func continuationCharactersPerLine(for kind: ElementKind) -> Int {
        kind == .parenthetical ? parentheticalContinuationMeasure : charactersPerLine(for: kind)
    }

    public func charactersPerLine(for kind: ElementKind) -> Int {
        switch kind {
        case .dialogue, .lyrics: return dialogueMeasure
        case .parenthetical: return parentheticalMeasure
        // A cue long enough to wrap does not occur in the corpus — the longest
        // is 25 characters. It shares the dialogue measure so that a pathological
        // one still wraps somewhere sensible rather than off the page.
        case .character: return dialogueMeasure
        case .sceneHeading: return sceneHeadingMeasure
        default: return actionMeasure
        }
    }

    /// The continuation cue printed at the top of a split dialogue block.
    /// Highland uses a curly apostrophe here, and matching it matters for a
    /// byte-level diff against their PDFs.
    public static func continuedCue(_ name: String) -> String {
        "\(name) (CONT\u{2019}D)"
    }

    public static let moreMarker = "(MORE)"
}
