import Foundation

/// What goes on the page, independently of where the page breaks fall.
///
/// The defaults are not a guess: each one was read back out of the user's own
/// Highland exports. Where a default contradicts what Highland's print panel
/// appears to offer, the export wins — the whole point of this milestone is
/// that the preview predicts the PDF.
public struct PrintSettings: Sendable, Hashable {
    /// A `Title:` block becomes an unnumbered page ahead of page 1. Every
    /// export in the corpus that has a title page has exactly one.
    public var includeTitlePage = true

    /// `# Act One` / `## Beat 3`.
    ///
    /// **Off**, against the obvious reading of Highland's print panel. This was
    /// the single most surprising measurement in the corpus: across all 19
    /// exports whose source is identifiable, Highland rendered *zero* section
    /// lines. `Anal Informant - MASTER` has 17 sections and none of them is in
    /// its 83-page PDF; the six Trophy Boyz episodes write their sluglines as
    /// `## 1. EXT. RAVINE - DAY` and Highland drops every one, which is exactly
    /// the silent data loss CLAUDE.md flags as the highest-value lint rule.
    ///
    /// Turning it on costs a line per section and rarely changes the page
    /// count — `Anal Informant` stays at 83 — so it is safe to offer, and it is
    /// the only honest way to print an outline.
    public var printSections = false

    /// `= A synopsis line.` Off; no export in the corpus contains one.
    public var printSynopses = false

    /// `[[a note]]`. Off.
    public var printNotes = false

    /// Whether page 1 carries its number. Off: Highland's first body page is
    /// blank in the top-right corner and the second reads `2.`.
    public var numberFirstPage = false

    /// A `*` in the right margin of any line belonging to a revised element.
    /// On, matching Highland; inert until revision tracking exists, since
    /// nothing marks an element as revised yet.
    public var showRevisionStars = true

    /// `#42#` scene numbers in the margins. Off — Highland prints them only for
    /// a production draft, and none of the corpus exports has them, including
    /// the one whose source carries 95 of them.
    public var printSceneNumbers = false

    /// Page geometry. Separated from the content toggles so a future A4 or
    /// half-page-sides layout is a value, not a fork of this type.
    public var layout = PageLayout.letter

    public init() {}

    /// Highland's saved defaults, as measured. The same thing as `init()`;
    /// named so a call site can say what it means.
    public static let highland = PrintSettings()

    /// Everything the author wrote, including the structural marks. Useful for
    /// a "print my outline" command and for showing what the toggles do.
    public static var everything: PrintSettings {
        var settings = PrintSettings()
        settings.printSections = true
        settings.printSynopses = true
        settings.printNotes = true
        return settings
    }

    /// Whether an element kind reaches the page at all.
    public func prints(_ kind: ElementKind) -> Bool {
        switch kind {
        case .section: return printSections
        case .synopsis: return printSynopses
        case .note: return printNotes
        case .boneyard: return false
        default: return true
        }
    }
}
