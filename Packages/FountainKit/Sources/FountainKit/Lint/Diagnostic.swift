import Foundation

/// A lint rule's stable identifier.
///
/// Raw values are dotted-free kebab case because they are user-visible: they go
/// in the diagnostics list, in a future "ignore this rule" setting, and into the
/// golden files that pin the corpus. Renaming one is a breaking change.
///
/// Every case here was found by reading the reference corpus. Nothing is
/// hypothetical — a rule that never fires on 17 real scripts is a rule that will
/// only ever produce false positives.
public enum LintRule: String, Sendable, Hashable, Codable, CaseIterable {
    /// `## 1. EXT. RAVINE - DAY` — a scene heading written as a section.
    /// Six Trophy Boyz episodes do this, and Highland drops every one of those
    /// headings from the exported PDF. The single highest-value rule here.
    case sluglineAsSection = "slugline-as-section"

    /// `EXT. MOUNTAIN – MORNING` — U+2013 where the convention is a hyphen.
    case sceneHeadingEnDash = "scene-heading-en-dash"

    /// `.Open to a commercial…` and `>What is the theme…` — `.` and `>` used as
    /// generic "force" marks, so the line renders as a slugline or a
    /// right-aligned transition rather than the action or note it reads as.
    case ambiguousForcedMark = "ambiguous-forced-mark"

    /// `INT. Horace apartment desk` — a heading that is not uppercase.
    case lowercaseSceneHeading = "lowercase-scene-heading"

    /// `I/E MONTAGE IMAGE` — the prefix has no period after it.
    case sceneHeadingSeparator = "scene-heading-separator"

    /// A character cue with invisible trailing whitespace, left behind by
    /// Markdown's two-space hard break.
    case trailingWhitespaceOnCue = "trailing-whitespace-on-cue"

    /// Two headings carrying the same `#N#`. Scene numbers are the identity
    /// sidecar metadata re-attaches by, so a collision is a real conflict.
    case duplicateSceneNumber = "duplicate-scene-number"

    /// A scene heading glued to the line above it. Our parser and Highland both
    /// accept it; the Fountain spec requires the blank line, so stricter tools
    /// read the heading as action.
    case sceneHeadingNeedsBlankLine = "scene-heading-needs-blank-line"

    /// A short human name, for a rule list in settings.
    public var title: String {
        switch self {
        case .sluglineAsSection: return "Scene heading written as a section"
        case .sceneHeadingEnDash: return "En dash in a scene heading"
        case .ambiguousForcedMark: return "Ambiguous forcing mark"
        case .lowercaseSceneHeading: return "Lowercase scene heading"
        case .sceneHeadingSeparator: return "Scene heading prefix without a period"
        case .trailingWhitespaceOnCue: return "Trailing whitespace on a character cue"
        case .duplicateSceneNumber: return "Duplicate scene number"
        case .sceneHeadingNeedsBlankLine: return "Scene heading without a blank line before it"
        }
    }

    /// Warning means *this will not come out the way you wrote it* — the line
    /// prints as the wrong element, or vanishes. Everything else is a
    /// suggestion, which the app is expected to render quietly.
    public var severity: Diagnostic.Severity {
        switch self {
        case .sluglineAsSection, .ambiguousForcedMark, .duplicateSceneNumber:
            return .warning
        case .sceneHeadingEnDash, .lowercaseSceneHeading, .sceneHeadingSeparator,
             .trailingWhitespaceOnCue, .sceneHeadingNeedsBlankLine:
            return .suggestion
        }
    }
}

/// One piece of non-blocking advice about a document.
///
/// Rule 9 is *parse leniently, lint loudly*: the parser resolves every line to
/// some element and never refuses input, so this type carries the whole of the
/// "are you sure?" conversation. A diagnostic is therefore always advisory —
/// there is deliberately no `.error` severity, because nothing here stops a
/// document opening, rendering, or exporting.
///
/// `range` is a UTF-16 range into the source, so it maps straight onto
/// `NSTextStorage` for a squiggle, and `replacement` is the text that would
/// replace exactly that range if the user accepts the fix. Keeping the two in
/// one range means a fix-it is a single `replaceCharacters(in:with:)` and the
/// highlight always shows precisely what would change.
public struct Diagnostic: Sendable, Hashable, Identifiable {
    public enum Severity: String, Sendable, Hashable, Codable, Comparable {
        /// The document will print differently from how it reads.
        case warning
        /// A convention worth following, with nothing at stake if it is not.
        case suggestion

        /// Warnings sort before suggestions.
        private var rank: Int {
            switch self {
            case .warning: return 0
            case .suggestion: return 1
            }
        }

        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.rank < rhs.rank
        }
    }

    public var rule: LintRule
    public var severity: Severity
    /// One sentence, addressed to the writer, saying what will happen — not what
    /// the spec says.
    public var message: String
    /// UTF-16 range in the source: what to highlight, and what a fix replaces.
    public var range: NSRange
    /// Zero-based source line, for reports and for jumping the caret.
    public var lineIndex: Int
    /// Text that would replace `range`, or nil when there is no safe automatic
    /// fix (a duplicate scene number cannot be guessed at).
    public var replacement: String?

    public init(
        rule: LintRule,
        severity: Severity? = nil,
        message: String,
        range: NSRange,
        lineIndex: Int,
        replacement: String? = nil
    ) {
        self.rule = rule
        self.severity = severity ?? rule.severity
        self.message = message
        self.range = range
        self.lineIndex = lineIndex
        self.replacement = replacement
    }

    /// Stable enough to key a SwiftUI list: one rule fires at most once per
    /// source offset.
    public var id: String { "\(rule.rawValue)@\(range.location)" }

    /// True when the app can offer a one-click fix.
    public var isFixable: Bool { replacement != nil }

    /// The source with this diagnostic's fix applied. Returns the source
    /// unchanged when there is no fix.
    public func applied(to source: String) -> String {
        guard let replacement else { return source }
        let ns = source as NSString
        guard range.location >= 0, range.location + range.length <= ns.length else { return source }
        return ns.replacingCharacters(in: range, with: replacement)
    }
}
