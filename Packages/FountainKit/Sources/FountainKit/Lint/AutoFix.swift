import Foundation

/// Chooses which lint fixes are safe to apply without being asked.
///
/// The linter already knows how to repair most of what it finds — `applied(to:)`
/// has existed since the diagnostics pane did. What this adds is the judgement
/// about *when*, and the answer is deliberately conservative, because the thing
/// being edited is the writer's screenplay and they did not press anything.
///
/// Three rules, all of them about not surprising anyone:
///
/// 1. **Never the line the caret is on.** `trailing-whitespace-on-cue` fires the
///    instant you type `MARLA` and a space. Fixing it there would delete the
///    space under the cursor as you typed it, every time, which is not a linter,
///    it is a fight.
/// 2. **Never overlapping fixes.** Two diagnostics can cover the same characters
///    — a lowercase heading with an en dash in it. Applying both would mean the
///    second one replacing text the first one already rewrote.
/// 3. **Back to front.** Applied in descending order of location, so each edit
///    leaves every remaining range still valid. No offset arithmetic, so no
///    offset arithmetic to get wrong.
public enum AutoFix {

    /// One replacement, in the source's own UTF-16 coordinates.
    public struct Edit: Sendable, Hashable {
        public var range: NSRange
        public var replacement: String

        public init(range: NSRange, replacement: String) {
            self.range = range
            self.replacement = replacement
        }
    }

    /// The fixes to apply, in the order to apply them.
    ///
    /// - Parameters:
    ///   - diagnostics: what the linter found, for the *current* text.
    ///   - disabled: rules the writer has switched off.
    ///   - protecting: a range that must not be touched — in practice the line
    ///     the caret is on, expanded to whole lines by the caller.
    public static func edits(
        for diagnostics: [Diagnostic],
        excluding disabled: Set<LintRule> = [],
        protecting protected: NSRange? = nil
    ) -> [Edit] {
        let candidates = diagnostics
            .filter { $0.isFixable && $0.rule.canAutoFix && !disabled.contains($0.rule) }
            .filter { diagnostic in
                guard let protected else { return true }
                return NSIntersectionRange(diagnostic.range, protected).length == 0
                    // A zero-length caret range at a boundary still counts as
                    // "where the writer is", so touching-but-not-overlapping is
                    // refused too.
                    && !NSLocationInRange(diagnostic.range.location, protected)
            }
            .sorted { $0.range.location > $1.range.location }

        var edits: [Edit] = []
        var lowestApplied = Int.max
        for diagnostic in candidates {
            guard let replacement = diagnostic.replacement else { continue }
            guard NSMaxRange(diagnostic.range) <= lowestApplied else { continue }
            edits.append(Edit(range: diagnostic.range, replacement: replacement))
            lowestApplied = diagnostic.range.location
        }
        return edits
    }

    /// Applies `edits` to a string. The editor applies them through the text
    /// view instead, so that undo and the selection are AppKit's problem rather
    /// than ours — this exists for the CLI and for tests.
    public static func apply(_ edits: [Edit], to source: String) -> String {
        let result = NSMutableString(string: source)
        for edit in edits {
            guard NSMaxRange(edit.range) <= result.length else { continue }
            result.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return result as String
    }
}

extension LintRule {
    /// Whether this rule may ever repair a document unattended.
    ///
    /// The line is drawn at *structure*: a rule may correct how a line is
    /// spelled, never how many scenes the document has. Three stay manual
    /// however confident the fix looks, and the third was found by the corpus
    /// test rather than by reasoning:
    ///
    /// - `duplicateSceneNumber` has no fix at all — a scene number is identity,
    ///   and guessing a new one silently re-anchors the sidecar metadata that
    ///   was attached to it.
    /// - `sluglineAsSection` rewrites `## 1. EXT. RAVINE - DAY` into a real
    ///   heading, which changes the outline as well as the page. 42 of them in
    ///   the corpus, all in the same six episodes; turning them all into scenes
    ///   at once is a structural edit to somebody's script.
    /// - `ambiguousForcedMark` rewrites a leading `.` to `!`, which is correct
    ///   advice — the line does typeset as a slugline — and catastrophic
    ///   unattended. `Ergosphere/ergosphere.fountain` uses `.` as a general beat
    ///   prefix on eleven lines, so applying this rule to it takes the script
    ///   from **11 scenes to 0** and empties the navigator. `Whorey` goes 5 to
    ///   2. Both are documents the writer is actively using.
    ///
    /// What is left only ever changes how a line reads: a dash, a case, a
    /// missing period, invisible trailing spaces, a blank line before a heading
    /// this parser already treats as one. `acrossTheCorpus` is what holds that
    /// line — it fails if a rule added here moves a single scene.
    public var canAutoFix: Bool {
        switch self {
        case .duplicateSceneNumber, .sluglineAsSection, .ambiguousForcedMark:
            return false
        case .sceneHeadingEnDash, .lowercaseSceneHeading,
             .sceneHeadingSeparator, .trailingWhitespaceOnCue,
             .sceneHeadingNeedsBlankLine:
            return true
        }
    }
}
