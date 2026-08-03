import FountainKit
import SwiftUI

/// The read-only page preview.
///
/// Draws whatever the `Paginator` produced, at the coordinates it produced, so
/// this predicts the exported PDF rather than approximating it — the same
/// engine feeds both. If a line lands in the wrong place here, it lands in the
/// wrong place in the export, which is exactly the property worth having.
///
/// An earlier version of this file filtered elements itself and claimed in a
/// comment that sections print. They do not: across nineteen of the user's own
/// Highland exports there is not a single printed section line. Deciding what
/// prints is `PrintSettings`' job now, not this view's.
struct PagePreview: View {
    let paginated: PaginatedScript?
    let caretOffset: Int
    @Binding var showsPages: Bool

    private var layout: PageLayout { PageLayout.letter }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "PAGE PREVIEW") {
                HStack(spacing: 8) {
                    if let paginated, let page = paginated.page(forSourceOffset: caretOffset) {
                        Text(page.isTitlePage
                             ? "Title page"
                             : "Page \(page.number) of \(paginated.bodyPageCount)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("preview.pageNumber")
                    }
                    Picker("", selection: $showsPages) {
                        Text("Page").tag(true)
                        Text("Continuous").tag(false)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .accessibilityIdentifier("preview.mode")
                }
            }

            if let paginated, !paginated.pages.isEmpty {
                pageScroller(paginated)
            } else {
                ContentUnavailableView(
                    "Nothing to preview",
                    systemImage: "doc",
                    description: Text("Start typing and pages will appear here.")
                )
                .controlSize(.small)
            }
        }
        .background(Color(nsColor: Style.canvasBackground))
    }

    private func pageScroller(_ paginated: PaginatedScript) -> some View {
        GeometryReader { geometry in
            let pagePadding: CGFloat = showsPages ? 20 : 0
            let availableWidth = max(1, geometry.size.width - pagePadding * 2)
            let previewScale = min(1, availableWidth / layout.pageWidth)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: showsPages ? 20 : 0) {
                        ForEach(paginated.pages) { page in
                            PageCanvas(
                                page: page,
                                layout: layout,
                                separated: showsPages,
                                scale: previewScale
                            )
                            .id(page.index)
                        }
                    }
                    .padding(pagePadding)
                    .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("preview.pages")
                .onChange(of: caretOffset) { _, offset in
                    // The preview follows the caret, so typing near a page break
                    // shows the break rather than making the writer hunt for it.
                    guard let index = paginated.pageIndex(forSourceOffset: offset) else { return }
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(index, anchor: .top)
                    }
                }
            }
        }
    }
}

/// One page, drawn at the paginator's own coordinates.
private struct PageCanvas: View {
    let page: PaginatedPage
    let layout: PageLayout
    /// Page mode draws a paper card; continuous mode runs the text together.
    let separated: Bool
    /// Preview-only scaling. Pagination and export retain full-size coordinates.
    let scale: CGFloat

    /// Asked for, never guessed: `Font.custom` fails silently on a bad name.
    private var fontName: String { ScreenplayFont.postScriptName }

    /// Continuous mode trims the page's empty top and bottom margins so the text
    /// flows without a band of white between every page.
    private var height: CGFloat {
        guard !separated else { return layout.pageHeight }
        let lastRow = page.lines.filter { !$0.isBlank }.map(\.y).max() ?? layout.bodyTop
        return lastRow + layout.lineHeight * 2
    }

    private var topInset: CGFloat { separated ? 0 : -layout.bodyTop + layout.lineHeight }

    var body: some View {
        Canvas { context, _ in
            context.scaleBy(x: scale, y: scale)
            for line in page.lines where !line.isBlank {
                context.draw(
                    Text(styled(line)),
                    at: CGPoint(x: line.x, y: line.y + topInset),
                    anchor: .topLeading
                )
            }
            if separated, let label = pageLabel {
                context.draw(
                    Text(label)
                        .font(.custom(fontName, size: layout.fontSize))
                        .foregroundColor(Style.paperInk),
                    at: CGPoint(x: layout.pageNumberRight, y: layout.pageNumberBaseline),
                    anchor: .topTrailing
                )
            }
        }
        .frame(width: layout.pageWidth * scale, height: height * scale)
        .background(Style.paper)
        .clipShape(RoundedRectangle(cornerRadius: separated ? Style.cornerRadius : 0))
        .shadow(color: separated ? .black.opacity(0.22) : .clear, radius: 6, y: 2)
    }

    /// Page 1 is unnumbered, and a title page never carries one.
    private var pageLabel: String? {
        guard !page.isTitlePage else { return nil }
        return page.label
    }

    private func styled(_ line: PageLine) -> AttributedString {
        var attributed = AttributedString(line.text)
        attributed.font = .custom(fontName, size: layout.fontSize)
        attributed.foregroundColor = Style.paperInk

        let utf16 = Array(line.text.utf16)
        for run in line.emphasis {
            guard run.range.lowerBound >= 0, run.range.upperBound <= utf16.count else { continue }
            guard let lower = AttributedString.Index(
                    attributed.startIndex, offsetByCharacters: run.range.lowerBound, in: attributed
                  ),
                  let upper = AttributedString.Index(
                    attributed.startIndex, offsetByCharacters: run.range.upperBound, in: attributed
                  )
            else { continue }
            var font = Font.custom(fontName, size: layout.fontSize)
            if run.style.contains(.bold) { font = font.bold() }
            if run.style.contains(.italic) { font = font.italic() }
            attributed[lower..<upper].font = font
            if run.style.contains(.underline) {
                attributed[lower..<upper].underlineStyle = .single
            }
        }
        return attributed
    }
}

private extension AttributedString.Index {
    /// Offsets an index by a character count, returning nil rather than trapping
    /// when the count runs past the end.
    init?(
        _ start: AttributedString.Index,
        offsetByCharacters count: Int,
        in string: AttributedString
    ) {
        var index = start
        for _ in 0..<count {
            guard index < string.endIndex else { return nil }
            index = string.index(afterCharacter: index)
        }
        self = index
    }
}
