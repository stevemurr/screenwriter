import AppKit
import FountainKit

/// Courier Prime, bundled with the app.
///
/// The font is not installed on a stock macOS — only Courier New is — and
/// Highland's PDFs are set in Courier Prime at 12pt with a 7.1904pt advance.
/// Matching their output, which is the fidelity target for export, requires the
/// real font rather than a metric-compatible substitute.
///
/// `ATSApplicationFontsPath: Fonts` in Info.plist registers everything in
/// `Resources/Fonts/` at launch, so no manual `CTFontManagerRegisterFontsForURL`
/// call is needed. This type only resolves and validates.
public enum ScreenplayFont {
    /// PostScript names, in the order the system is asked for them.
    ///
    /// The bundled face's PostScript name is `CourierPrime-Regular`; the bare
    /// `CourierPrime` does **not** resolve, and `Courier Prime` works only
    /// because it is the family name. This matters beyond `NSFont`, which
    /// returns nil on a bad name: SwiftUI's `Font.custom` silently falls back to
    /// the system font instead, so a wrong name here renders the whole page
    /// preview in a proportional typeface with nothing to indicate why.
    private static let regularCandidates = ["CourierPrime-Regular", "Courier Prime"]
    private static let boldCandidates = ["CourierPrime-Bold", "Courier Prime Bold"]
    private static let italicCandidates = ["CourierPrime-Italic", "Courier Prime Italic"]

    /// The PostScript name that actually resolved, for anything that takes a
    /// font by name rather than by instance — SwiftUI's `Font.custom`, chiefly.
    /// Never guess this string; ask for it.
    public static var postScriptName: String {
        regularCandidates.first { NSFont(name: $0, size: 12) != nil } ?? "Courier New"
    }

    public static func postScriptName(bold: Bool = false, italic: Bool = false) -> String {
        let candidates: [String]
        switch (bold, italic) {
        case (true, true): candidates = ["CourierPrime-BoldItalic"]
        case (true, false): candidates = boldCandidates
        case (false, true): candidates = italicCandidates
        case (false, false): candidates = regularCandidates
        }
        return candidates.first { NSFont(name: $0, size: 12) != nil } ?? postScriptName
    }

    /// True when the bundled font actually registered. Surfaced in Settings so a
    /// packaging mistake shows up as a visible warning rather than as PDFs that
    /// are silently a few points off.
    public static var isCourierPrimeAvailable: Bool {
        resolve(regularCandidates) != nil
    }

    public static func regular(size: CGFloat = 12) -> NSFont {
        resolve(regularCandidates, size: size) ?? fallback(size: size)
    }

    public static func bold(size: CGFloat = 12) -> NSFont {
        resolve(boldCandidates, size: size) ?? NSFontManager.shared.convert(
            regular(size: size),
            toHaveTrait: .boldFontMask
        )
    }

    public static func italic(size: CGFloat = 12) -> NSFont {
        resolve(italicCandidates, size: size) ?? NSFontManager.shared.convert(
            regular(size: size),
            toHaveTrait: .italicFontMask
        )
    }

    /// Courier New is metric-compatible enough to keep the app usable, but it is
    /// not what Highland set their PDFs in. Never silently ship it in an export.
    private static func fallback(size: CGFloat) -> NSFont {
        NSFont(name: "Courier New", size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private static func resolve(_ names: [String], size: CGFloat = 12) -> NSFont? {
        for name in names {
            if let font = NSFont(name: name, size: size) { return font }
        }
        return nil
    }

    /// The measured advance width of the resolved font, for comparing against
    /// `PageLayout.characterWidth` (7.1904pt) in a diagnostic. The font is
    /// monospaced, so any glyph answers the question.
    public static func measuredAdvance(size: CGFloat = 12) -> CGFloat {
        let font = regular(size: size)
        return NSAttributedString(string: "M", attributes: [.font: font]).size().width
    }
}
