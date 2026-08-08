import Foundation
import FountainKit

/// Defaults keys, namespaced so a typo is a compile error rather than a setting
/// that silently never persists.
enum PrefKey {
    static let editorFontSize = "editorFontSize"
    static let autoFixEnabled = "autoFixEnabled"
    static let disabledLintRules = "disabledLintRules"
}

/// Which lint rules repair the document without being asked.
///
/// **Off by default, deliberately.** The rules that survive `canAutoFix` are all
/// cosmetic, and the corpus test proves none of them moves a scene — but the
/// document being edited is the writer's screenplay and they did not press
/// anything. Opting in is one switch; noticing that something has been quietly
/// rewriting your pages is not.
enum AutoLint {
    static let defaultEnabled = false

    /// The rules the settings pane offers, in the order it lists them. Only the
    /// ones that can ever fire — a switch for a rule that never auto-applies
    /// would be a switch that does nothing.
    static let configurableRules: [LintRule] = LintRule.allCases.filter(\.canAutoFix)

    /// Defaults cannot store a `Set`, and a comma-joined list of raw values is
    /// legible in `defaults read` — which matters, because these raw values are
    /// already the stable user-visible identifiers the golden files use.
    static func decode(_ stored: String) -> Set<LintRule> {
        Set(stored.split(separator: ",").compactMap { LintRule(rawValue: String($0)) })
    }

    static func encode(_ rules: Set<LintRule>) -> String {
        rules.map(\.rawValue).sorted().joined(separator: ",")
    }

    static func isEnabled(_ rule: LintRule, disabled stored: String) -> Bool {
        !decode(stored).contains(rule)
    }

    static func setting(_ rule: LintRule, enabled: Bool, in stored: String) -> String {
        var rules = decode(stored)
        if enabled { rules.remove(rule) } else { rules.insert(rule) }
        return encode(rules)
    }
}

/// Type size for the editing surface only.
///
/// Deliberately *not* `PageLayout.fontSize`. That value is the measured
/// Highland geometry the paginator, the preview, and the PDF renderer all share
/// — changing it would move the page and break the one property this project is
/// built on. This scales what the writer looks at while typing and nothing else:
/// the exported PDF is identical at 9pt and at 24pt.
enum EditorTypeSize {
    static let `default`: Double = 12
    static let range: ClosedRange<Double> = 9...24

    /// Clamped, and NaN-proof — a corrupt defaults value must not produce a
    /// zero-sized font.
    static func resolve(_ stored: Double) -> Double {
        guard stored.isFinite, stored > 0 else { return `default` }
        return min(max(stored, range.lowerBound), range.upperBound)
    }

    /// How much larger than the page's own 12pt the editor is drawing.
    ///
    /// Styled mode indents in points, so the columns have to scale with the type
    /// or the screenplay stops looking like one — dialogue would sit at its
    /// 2.49" column while set in 20pt.
    static func scale(_ stored: Double) -> Double {
        resolve(stored) / `default`
    }
}
