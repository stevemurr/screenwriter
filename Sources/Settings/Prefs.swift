import Foundation

/// Defaults keys, namespaced so a typo is a compile error rather than a setting
/// that silently never persists.
enum PrefKey {
    static let editorFontSize = "editorFontSize"
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
