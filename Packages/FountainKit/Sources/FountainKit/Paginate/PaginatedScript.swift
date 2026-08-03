import Foundation

/// One typeset line, positioned on its page.
///
/// This is deliberately the *only* output shape. Three consumers need three
/// different things — the status bar wants a count, the preview wants to follow
/// the caret, the PDF renderer wants coordinates — and giving each its own
/// model is how the preview stops predicting the export. They all read this.
public struct PageLine: Sendable, Hashable {
    public enum Alignment: Sendable, Hashable {
        case left
        /// Transitions, right-aligned to `PageLayout.transitionRight`.
        case right
        /// `> centred <` and the title page.
        case centered
    }

    /// The element kind this line was typeset from. `(MORE)` and the repeated
    /// cue report `.character`, since that is how they are set.
    public var kind: ElementKind
    /// The text exactly as it prints: forcing mark removed, emphasis
    /// delimiters removed, wrapped, no trailing space. This is what a
    /// byte-level diff against Highland's PDF compares.
    public var text: String
    /// Which spans of `text` are bold, italic or underlined. Empty for most
    /// lines. Offsets are UTF-16, into `text`.
    public var emphasis: [EmphasisRun]
    public var alignment: Alignment

    /// Index into `ParsedScript.elements`, or nil for a line this engine
    /// generated: `(MORE)` and `NAME (CONT'D)`.
    public var elementIndex: Int?
    /// UTF-16 offset into the source of this line's first character. Best
    /// effort inside an element — always within that element's range, so the
    /// preview can follow the caret to the right page and the right line.
    public var sourceOffset: Int
    /// One-based scene ordinal, matching `ScriptScene.index`. Nil for anything
    /// ahead of the first scene heading.
    public var sceneIndex: Int?

    /// Zero-based row on the page. `y` is derived from it.
    public var row: Int
    /// Left edge in points. For `.right` and `.centered` this is still the
    /// computed left edge of the drawn text, so a renderer can ignore alignment
    /// and simply draw at `x`.
    public var x: CGFloat
    /// Top of the line's box, measured down from the top of the page —
    /// the same axis as `PageLayout.bodyTop`.
    public var y: CGFloat

    /// True for `(MORE)` and the repeated `NAME (CONT'D)` cue.
    public var isGenerated: Bool { elementIndex == nil }
    public var isBlank: Bool { kind == .blank }

    public init(
        kind: ElementKind,
        text: String,
        emphasis: [EmphasisRun] = [],
        alignment: Alignment = .left,
        elementIndex: Int?,
        sourceOffset: Int,
        sceneIndex: Int?,
        row: Int,
        x: CGFloat,
        y: CGFloat
    ) {
        self.kind = kind
        self.text = text
        self.emphasis = emphasis
        self.alignment = alignment
        self.elementIndex = elementIndex
        self.sourceOffset = sourceOffset
        self.sceneIndex = sceneIndex
        self.row = row
        self.x = x
        self.y = y
    }
}

/// One page of the paginated script.
public struct PaginatedPage: Sendable, Hashable, Identifiable {
    /// Zero-based position in `PaginatedScript.pages`, title page included.
    public var index: Int
    /// The printed page ordinal: 1 for the first body page. Zero on the title
    /// page, which is outside the numbering.
    public var number: Int
    /// The number as it prints — `"2."` — or nil when the page carries none.
    /// Page 1 is unnumbered by default and the title page always is.
    ///
    /// This is a string rather than an `Int` on purpose. A production-locked
    /// script numbers inserted pages `12`, `12A`, `12B`, and that is the only
    /// place that change has to land: `Paginator.pageLabel(for:of:settings:)`
    /// decides it, and everything downstream already treats it as text.
    public var label: String?
    /// Every line, blanks included, in reading order.
    public var lines: [PageLine]
    /// One-based scene ordinals appearing on this page, in order.
    public var sceneIndices: [Int]
    /// UTF-16 range of the source this page renders. Contiguous with its
    /// neighbours, so an offset lands on exactly one page.
    public var sourceRange: NSRange
    public var isTitlePage: Bool

    public var id: Int { index }

    /// Lines that actually print something.
    public var contentLines: [PageLine] { lines.filter { !$0.isBlank } }

    public init(
        index: Int,
        number: Int,
        label: String?,
        lines: [PageLine],
        sceneIndices: [Int],
        sourceRange: NSRange,
        isTitlePage: Bool = false
    ) {
        self.index = index
        self.number = number
        self.label = label
        self.lines = lines
        self.sceneIndices = sceneIndices
        self.sourceRange = sourceRange
        self.isTitlePage = isTitlePage
    }
}

/// A scene's extent in the paginated script.
public struct SceneMetric: Sendable, Hashable, Identifiable {
    /// One-based, matching `ScriptScene.index`.
    public var sceneIndex: Int
    /// A `#42#` number from the heading, if the author wrote one.
    public var number: String?
    public var heading: String
    /// Printed page numbers the scene touches, first through last.
    public var pages: ClosedRange<Int>
    /// Printed lines belonging to the scene.
    ///
    /// **The heading counts and the blank lines above it do not.** A 1st AD
    /// measures a scene from its slugline to its last line, so that is what
    /// this is. The blank line Highland inserts above a heading belongs to the
    /// page, not to either scene, and counting it would make every scene an
    /// eighth longer than the schedule says.
    public var lineCount: Int
    public var length: Eighths

    public var id: Int { sceneIndex }

    public init(
        sceneIndex: Int,
        number: String?,
        heading: String,
        pages: ClosedRange<Int>,
        lineCount: Int,
        length: Eighths
    ) {
        self.sceneIndex = sceneIndex
        self.number = number
        self.heading = heading
        self.pages = pages
        self.lineCount = lineCount
        self.length = length
    }

    /// `1 5/8 pp`, `7/8 pp`.
    public var lengthDescription: String { "\(length) pp" }
}

/// The paginated script: what the preview scrolls, what the renderer draws, and
/// where the status bar's page count comes from.
public struct PaginatedScript: Sendable {
    public var pages: [PaginatedPage]
    public var scenes: [SceneMetric]
    public var settings: PrintSettings
    /// The source this was paginated from, so a consumer can check the result
    /// is still current before applying it — the same guard `ParsedScript` uses.
    public var source: String

    public init(
        pages: [PaginatedPage] = [],
        scenes: [SceneMetric] = [],
        settings: PrintSettings = .highland,
        source: String = ""
    ) {
        self.pages = pages
        self.scenes = scenes
        self.settings = settings
        self.source = source
    }

    public static let empty = PaginatedScript()

    public var layout: PageLayout { settings.layout }

    /// Sheets of paper, title page included. This is the number the status bar
    /// shows and the number `mdls` reports for the exported PDF.
    public var pageCount: Int { pages.count }

    /// Numbered script pages, title page excluded.
    public var bodyPageCount: Int { pages.count { !$0.isTitlePage } }

    /// Length of the whole script, for the same readout the scene list uses.
    public var length: Eighths {
        Eighths(
            lines: pages.reduce(0) { $0 + $1.lines.count { line in !line.isBlank } },
            linesPerPage: layout.linesPerPage
        )
    }

    // MARK: - Offset mapping

    /// The page holding a UTF-16 source offset, for following the caret.
    ///
    /// Pages tile the source, so this is exact rather than nearest; an offset
    /// past the end lands on the last page.
    public func page(forSourceOffset offset: Int) -> PaginatedPage? {
        guard let index = pageIndex(forSourceOffset: offset) else { return nil }
        return pages[index]
    }

    /// The index into `pages`, which is what a `ScrollView` needs.
    public func pageIndex(forSourceOffset offset: Int) -> Int? {
        guard !pages.isEmpty else { return nil }
        // Binary search over page starts. Pages are ordered and contiguous.
        var low = 0
        var high = pages.count - 1
        var found = 0
        while low <= high {
            let middle = (low + high) / 2
            if pages[middle].sourceRange.location <= offset {
                found = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return found
    }

    /// The first source offset on a page, for jumping the editor to it.
    public func sourceOffset(forPage index: Int) -> Int? {
        guard pages.indices.contains(index) else { return nil }
        return pages[index].sourceRange.location
    }

    /// The first source offset of a *printed* page number, so "go to page 12"
    /// works from the number the reader sees rather than the array index.
    public func sourceOffset(forPageNumber number: Int) -> Int? {
        guard let page = pages.first(where: { !$0.isTitlePage && $0.number == number })
        else { return nil }
        return page.sourceRange.location
    }

    /// The line nearest a source offset, for putting a caret on the preview.
    public func line(forSourceOffset offset: Int) -> PageLine? {
        guard let page = page(forSourceOffset: offset) else { return nil }
        var best: PageLine?
        for line in page.lines where !line.isBlank {
            if line.sourceOffset <= offset { best = line } else { break }
        }
        return best ?? page.lines.first { !$0.isBlank }
    }

    /// The metric for a scene ordinal.
    public func metric(forScene index: Int) -> SceneMetric? {
        scenes.first { $0.sceneIndex == index }
    }
}
