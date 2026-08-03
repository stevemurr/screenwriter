import Foundation

/// A screenplay element, as classified from one or more source lines.
///
/// Fountain is line-oriented but context-sensitive: a character cue is only a
/// cue because a blank line precedes it and a non-blank line follows it. The
/// parser resolves that context; this type is the resolved answer.
public enum ElementKind: String, Sendable, Hashable, Codable {
    /// `INT. GLASS HOUSE - NIGHT`, or forced with a leading `.`
    case sceneHeading
    /// Narrative description. Forced with a leading `!`.
    case action
    /// `LENA`, or forced with a leading `@`. Uppercase by convention, not by rule.
    case character
    /// `(beat)` on its own line, between a cue and its dialogue.
    case parenthetical
    /// The spoken line following a cue.
    case dialogue
    /// `CUT TO:`, or forced with a leading `>`. Right-aligned when printed.
    case transition
    /// `> centred text <`
    case centered
    /// `# Act One`, `## Beat 1`. The outline hierarchy; printed by default.
    case section
    /// `= A synopsis line.` Excluded from print by default.
    case synopsis
    /// `[[a note]]` occupying a whole line. Excluded from print by default.
    case note
    /// `~lyrics`. Never once used in the reference corpus, but cheap to support.
    case lyrics
    /// `===` — a forced page break.
    case pageBreak
    /// Text between `/*` and `*/`. Never printed.
    case boneyard
    /// A blank separator line. Retained so byte-exact round-tripping is trivial.
    case blank
}

/// One classified element and the source it came from.
///
/// `range` is a UTF-16 range into the original document string, so it maps
/// directly onto `NSTextStorage` without conversion. Every byte of the source
/// belongs to exactly one element — including blanks and boneyard — which is
/// what makes reordering a scene a matter of moving one contiguous range.
public struct Element: Sendable, Hashable {
    public var kind: ElementKind
    /// UTF-16 range in the source document.
    public var range: NSRange
    /// Zero-based index of the first source line this element covers.
    public var lineIndex: Int
    /// Number of source lines this element covers.
    public var lineCount: Int
    /// The element's text with any forcing mark (`.`, `@`, `!`, `>`, `#`, `=`,
    /// `~`) removed — what the screenplay actually reads as.
    public var text: String
    /// The forcing mark that was stripped, if any. Styled mode dims it in place
    /// rather than hiding it, so it needs to know where it was.
    public var forcingMark: Character?
    /// Nesting depth for `section` (1 for `#`, 2 for `##`, …); 0 otherwise.
    public var depth: Int
    /// A `#42#` scene number suffix on a heading, with the hashes stripped.
    public var sceneNumber: String?
    /// True when a cue is marked for dual dialogue with a trailing `^`.
    public var isDualDialogue: Bool

    public init(
        kind: ElementKind,
        range: NSRange,
        lineIndex: Int,
        lineCount: Int = 1,
        text: String,
        forcingMark: Character? = nil,
        depth: Int = 0,
        sceneNumber: String? = nil,
        isDualDialogue: Bool = false
    ) {
        self.kind = kind
        self.range = range
        self.lineIndex = lineIndex
        self.lineCount = lineCount
        self.text = text
        self.forcingMark = forcingMark
        self.depth = depth
        self.sceneNumber = sceneNumber
        self.isDualDialogue = isDualDialogue
    }
}
