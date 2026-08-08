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
    /// Which page the caret is on — not where in the document it is.
    ///
    /// This used to be the raw caret offset, and that made every keystroke a new
    /// view value: a fresh `body`, a fresh `ForEach` over every page, and an
    /// animated `scrollTo` the top of the page the writer was already on. The
    /// preview can only ever scroll to a page top, so the offset carried nothing
    /// this view could act on. Measured on the 95-scene reference script: of
    /// 89,287 caret positions, 86 change page — 99.9% of those scrolls only
    /// undid the writer's own scrolling.
    let caretPage: Int?

    private var layout: PageLayout { PageLayout.letter }

    var body: some View {
        #if DEBUG
        RenderCounters.previewBodies += 1
        #endif
        return VStack(spacing: 0) {
            PaneHeader(title: "PAGE PREVIEW") {
                HStack(spacing: 8) {
                    if let paginated, let page = currentPage(in: paginated) {
                        Text(page.isTitlePage
                             ? "Title page"
                             : "Page \(page.number) of \(paginated.bodyPageCount)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("preview.pageNumber")
                    }
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

    /// Tolerates an index from a pagination the caret has already moved past —
    /// the page count changes a debounce after the text does.
    private func currentPage(in paginated: PaginatedScript) -> PaginatedPage? {
        guard let caretPage, paginated.pages.indices.contains(caretPage) else { return nil }
        return paginated.pages[caretPage]
    }

    private func pageScroller(_ paginated: PaginatedScript) -> some View {
        GeometryReader { geometry in
            let pagePadding: CGFloat = 20
            let availableWidth = max(1, geometry.size.width - pagePadding * 2)
            let previewScale = min(1, availableWidth / layout.pageWidth)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 20) {
                        ForEach(paginated.pages) { page in
                            PageCanvas(
                                page: page,
                                layout: layout,
                                scale: previewScale
                            )
                            .id(page.index)
                        }
                    }
                    .padding(pagePadding)
                    .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("preview.pages")
                .onChange(of: caretPage) { _, index in
                    // The preview follows the caret onto a new page, so writing
                    // across a page break shows the break. It deliberately does
                    // *not* follow within a page: there is nothing finer to
                    // scroll to, and re-running this on every keystroke dragged
                    // the preview back to the page top each time, so a writer
                    // could not read the foot of a page while typing into it.
                    guard let index, paginated.pages.indices.contains(index) else { return }
                    #if DEBUG
                    RenderCounters.previewScrolls += 1
                    #endif
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(index, anchor: .top)
                    }
                }
            }
        }
    }
}

/// One page, drawn at the paginator's own coordinates.
struct PageCanvas: View {
    let page: PaginatedPage
    let layout: PageLayout
    /// Preview-only scaling. Pagination and export retain full-size coordinates.
    let scale: CGFloat

    /// Asked for, never guessed: `Font.custom` fails silently on a bad name.
    private var fontName: String { ScreenplayFont.postScriptName }

    var body: some View {
        Canvas { context, _ in
            context.scaleBy(x: scale, y: scale)
            for line in page.lines where !line.isBlank {
                context.draw(
                    Text(styled(line)),
                    at: CGPoint(x: line.x, y: line.y),
                    anchor: .topLeading
                )
            }
            if let label = pageLabel {
                context.draw(
                    Text(label)
                        .font(.custom(fontName, size: layout.fontSize))
                        .foregroundColor(Style.paperInk),
                    at: CGPoint(x: layout.pageNumberRight, y: layout.pageNumberBaseline),
                    anchor: .topTrailing
                )
            }
        }
        .frame(width: layout.pageWidth * scale, height: layout.pageHeight * scale)
        .background(Style.paper)
        .clipShape(RoundedRectangle(cornerRadius: Style.cornerRadius))
        .shadow(color: .black.opacity(0.22), radius: 6, y: 2)
    }

    /// Page 1 is unnumbered, and a title page never carries one.
    private var pageLabel: String? {
        guard !page.isTitlePage else { return nil }
        return page.label
    }

    /// Internal, not private, so `WorkspaceRenderCostTests` can put a budget on
    /// it: this runs for every printed line of every page that is redrawn.
    func styled(_ line: PageLine) -> AttributedString {
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
