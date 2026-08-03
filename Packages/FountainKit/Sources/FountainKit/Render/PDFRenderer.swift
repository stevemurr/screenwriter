import CoreGraphics
import CoreText
import Foundation

/// Draws a `PaginatedScript` to PDF.
///
/// Deliberately dumb: it decides nothing. Every position comes from the
/// paginator, which is the same source the on-screen preview draws from — so
/// the two cannot drift apart, and a fidelity failure is always the paginator's
/// to fix rather than something to be papered over here.
///
/// Core Graphics and Core Text only; no AppKit, so this stays inside FountainKit
/// and is testable without an app.
public enum PDFRenderer {

    /// The four faces a screenplay needs. Supplied by the caller because font
    /// registration belongs to the app bundle, not to this package.
    public struct FontSet: Sendable {
        public var regular: CTFont
        public var bold: CTFont
        public var italic: CTFont
        public var boldItalic: CTFont

        public init(regular: CTFont, bold: CTFont, italic: CTFont, boldItalic: CTFont) {
            self.regular = regular
            self.bold = bold
            self.italic = italic
            self.boldItalic = boldItalic
        }

        /// Resolves by PostScript name, falling back to Courier New.
        ///
        /// The fallback is metric-compatible enough to stay readable but is *not*
        /// what Highland set their PDFs in, so `courierPrimeIsAvailable` exists
        /// for callers that would rather warn than ship a near-miss.
        public static func named(_ base: String, size: CGFloat) -> FontSet {
            func font(_ candidates: [String]) -> CTFont {
                for name in candidates {
                    let font = CTFontCreateWithName(name as CFString, size, nil)
                    if (CTFontCopyPostScriptName(font) as String).caseInsensitiveCompare(name)
                        == .orderedSame {
                        return font
                    }
                }
                return CTFontCreateWithName("Courier New" as CFString, size, nil)
            }
            return FontSet(
                regular: font(["\(base)-Regular", base, "Courier New"]),
                bold: font(["\(base)-Bold", "Courier New Bold"]),
                italic: font(["\(base)-Italic", "Courier New Italic"]),
                boldItalic: font(["\(base)-BoldItalic", "Courier New Bold Italic"])
            )
        }

        public static func courierPrime(size: CGFloat) -> FontSet {
            named("CourierPrime", size: size)
        }

        func face(for style: EmphasisRun.Style) -> CTFont {
            switch (style.contains(.bold), style.contains(.italic)) {
            case (true, true): return boldItalic
            case (true, false): return bold
            case (false, true): return italic
            case (false, false): return regular
            }
        }
    }

    /// Metadata written into the PDF's document dictionary.
    public struct DocumentInfo: Sendable {
        public var title: String?
        public var author: String?
        public init(title: String? = nil, author: String? = nil) {
            self.title = title
            self.author = author
        }
    }

    /// Renders to PDF data, or nil if Core Graphics refuses a context.
    public static func render(
        _ paginated: PaginatedScript,
        fonts: FontSet,
        layout: PageLayout = .letter,
        info: DocumentInfo = DocumentInfo()
    ) -> Data? {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var mediaBox = CGRect(x: 0, y: 0, width: layout.pageWidth, height: layout.pageHeight)

        var properties: [CFString: Any] = [:]
        if let title = info.title { properties[kCGPDFContextTitle] = title }
        if let author = info.author { properties[kCGPDFContextAuthor] = author }
        properties[kCGPDFContextCreator] = "Screenwriter"

        guard let context = CGContext(
            consumer: consumer,
            mediaBox: &mediaBox,
            properties as CFDictionary
        ) else { return nil }

        for page in paginated.pages {
            context.beginPDFPage(nil)
            draw(page, in: context, fonts: fonts, layout: layout)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    private static func draw(
        _ page: PaginatedPage,
        in context: CGContext,
        fonts: FontSet,
        layout: PageLayout
    ) {
        for line in page.lines where !line.isBlank && !line.text.isEmpty {
            draw(
                text: line.text,
                emphasis: line.emphasis,
                x: line.x,
                y: line.y,
                in: context,
                fonts: fonts,
                layout: layout
            )
        }
        // Page 1 is unnumbered and a title page never carries a number, both of
        // which the paginator has already decided by leaving `label` nil.
        if let label = page.label, !page.isTitlePage {
            let width = CGFloat(label.count) * layout.characterWidth
            draw(
                text: label,
                emphasis: [],
                x: layout.pageNumberRight - width,
                y: layout.pageNumberBaseline - layout.baselineOffset,
                in: context,
                fonts: fonts,
                layout: layout
            )
        }
    }

    private static func draw(
        text: String,
        emphasis: [EmphasisRun],
        x: CGFloat,
        y: CGFloat,
        in context: CGContext,
        fonts: FontSet,
        layout: PageLayout
    ) {
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: fonts.regular,
                .foregroundColor: CGColor(gray: 0, alpha: 1)
            ]
        )
        let length = (text as NSString).length
        for run in emphasis {
            let range = NSRange(
                location: max(run.range.lowerBound, 0),
                length: min(run.range.count, length - max(run.range.lowerBound, 0))
            )
            guard range.location < length, range.length > 0 else { continue }
            attributed.addAttribute(.font, value: fonts.face(for: run.style), range: range)
            if run.style.contains(.underline) {
                attributed.addAttribute(
                    .underlineStyle,
                    value: CTUnderlineStyle.single.rawValue,
                    range: range
                )
            }
        }

        // PDF space is bottom-up; the paginator measures down from the top of
        // the page, and `y` is the top of the line's box rather than its
        // baseline.
        let baseline = layout.pageHeight - y - layout.baselineOffset
        context.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
    }
}

private extension NSAttributedString.Key {
    /// Core Text spells these differently from AppKit, and this package cannot
    /// import AppKit.
    static let font = NSAttributedString.Key(kCTFontAttributeName as String)
    static let foregroundColor = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
    static let underlineStyle = NSAttributedString.Key(kCTUnderlineStyleAttributeName as String)
}
