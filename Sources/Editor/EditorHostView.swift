import AppKit

/// Scroll view, text view, and line-number gutter.
///
/// Ported from topside's `TextKitEditorHostView`. See Rule 1 in
/// `FountainEditorSurface`: nothing in here may read `textView.layoutManager`.
@MainActor
public final class EditorHostView: NSView {
    public let scrollView: NSScrollView
    public let textView: NSTextView
    let rulerView: LineNumberRulerView

    private var showsLineNumbers = true
    /// The range styling currently covers, so scrolling knows when to extend it.
    var lastStyledRange: NSRange?
    /// When set, text lays out in a fixed-width column centred in the pane —
    /// the page's 1.5"–7.5" measure, so styled mode reads like a page.
    private var scriptColumnWidth: CGFloat?

    public override init(frame frameRect: NSRect) {
        // TextKit 2. `NSTextLayoutManager` lays out only the fragments the
        // viewport needs, so opening a 91 KB script does not pay for laying out
        // every line up front.
        textView = NSTextView(usingTextLayoutManager: true)
        if let container = textView.textContainer {
            container.size = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
            container.widthTracksTextView = true
        }
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        // Required, not cosmetic: the parser keys on the first character of a
        // line (`.`, `@`, `!`, `>`, `#`, `=`, `~`), and macOS substitutions
        // would silently rewrite quotes and dashes underneath it.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: 14, height: 16)
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        // Set on the text view itself, not through SwiftUI. `.accessibilityIdentifier`
        // on an NSViewRepresentable labels the SwiftUI wrapper, and the NSTextView
        // underneath stays anonymous — so `app.textViews["editor.surface"]` never
        // matches and every UI test fails at the same line. This is the plumbing
        // topside had and this port dropped.
        textView.setAccessibilityIdentifier(EditorHostView.accessibilityIdentifier)
        textView.setAccessibilityRole(.textArea)
        textView.setAccessibilityLabel("Fountain source")
        textView.setAccessibilityEnabled(true)

        scrollView = NSScrollView(frame: .zero)
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Style.editorBackground
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView

        rulerView = LineNumberRulerView(textView: textView, scrollView: scrollView)
        scrollView.verticalRulerView = rulerView
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        super.init(frame: frameRect)
        // Styling follows the viewport, so the viewport has to say when it moved.
        scrollView.contentView.postsBoundsChangedNotifications = true
        addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        // AppKit does not automatically expose a TextKit 2 document view beneath
        // its scroll view. Making the geometry host an explicit group whose sole
        // semantic child is the real editor is what puts it in the AX tree.
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityChildren([textView])
    }

    static let accessibilityIdentifier = "editor.surface" 

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public func setShowsLineNumbers(_ shows: Bool) {
        guard showsLineNumbers != shows else { return }
        showsLineNumbers = shows
        scrollView.hasVerticalRuler = shows
        scrollView.rulersVisible = shows
        rulerView.invalidateLineIndex()
        needsLayout = true
    }

    public func setScriptColumn(_ width: CGFloat?) {
        guard scriptColumnWidth != width else { return }
        scriptColumnWidth = width
        needsLayout = true
    }

    /// Centres the script column in styled mode by widening the text container
    /// inset. Computed on layout because it depends on the pane's current width.
    public override func layout() {
        super.layout()
        let available = scrollView.contentSize.width
        let inset: CGFloat
        if let column = scriptColumnWidth {
            inset = max((available - column) / 2, 24)
        } else {
            inset = 14
        }
        if abs(textView.textContainerInset.width - inset) > 0.5 {
            textView.textContainerInset = NSSize(width: inset, height: 16)
            textView.needsLayout = true
        }
    }
}

/// A viewport-bounded line-number gutter for TextKit 2.
///
/// Ported from topside. The cached `lineStarts` index exists because TextKit 2
/// hands back the fragment at a point but not its line number, and counting
/// newlines from the start of the file per draw is O(document) — which would
/// give back exactly the cost TextKit 2 exists to remove.
@MainActor
final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?

    static let thickness: CGFloat = Style.gutterWidth

    /// NSRulerView recomputes its own thickness when the scroll view tiles and
    /// consults `requiredThickness` to do it, so assigning `ruleThickness` once
    /// in `init` does not survive. The value is owned here.
    override var requiredThickness: CGFloat { Self.thickness }

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        // Without a client view the ruler has nothing to size and scroll
        // against, which is how its geometry drifts from the width we ask for.
        clientView = textView
        ruleThickness = Self.thickness
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var lineStarts: [Int] = [0]
    private var lineStartsSource: String?

    func invalidateLineIndex() {
        lineStartsSource = nil
        needsDisplay = true
    }

    private func lineNumber(forCharacterOffset offset: Int, in source: String) -> Int {
        if lineStartsSource != source {
            var starts = [0]
            let utf16 = source as NSString
            var index = 0
            while index < utf16.length {
                if utf16.character(at: index) == 0x0A { starts.append(index + 1) }
                index += 1
            }
            lineStarts = starts
            lineStartsSource = source
        }
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= offset { low = middle } else { high = middle - 1 }
        }
        return low + 1
    }

    /// NSRulerView's own `draw(_:)` paints chrome around the hash marks,
    /// including a separator that runs up through the pane header. Only the
    /// numbers are wanted.
    override func draw(_ dirtyRect: NSRect) {
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView,
              let layout = textView.textLayoutManager,
              let content = layout.textContentManager else { return }

        let gutter = NSRect(x: 0, y: 0, width: Self.thickness, height: bounds.height)
        Style.chromeBackground.setFill()
        gutter.intersection(rect).fill()
        Style.separator.withAlphaComponent(0.6).setFill()
        NSRect(x: Self.thickness - 1, y: rect.minY, width: 1, height: rect.height).fill()

        let visibleRect = scrollView?.documentVisibleRect ?? textView.visibleRect
        let origin = textView.textContainerOrigin
        let source = textView.string
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        if source.isEmpty {
            draw(number: 1, y: origin.y, attributes: attributes)
            return
        }

        // Start at the fragment covering the top of the viewport and walk
        // forward only as far as the viewport reaches — bounded by what is on
        // screen, not by the size of the file.
        let topInContainer = max(visibleRect.minY - origin.y, 0)
        let first = layout.textLayoutFragment(for: CGPoint(x: 0, y: topInContainer))
        let start = first?.rangeInElement.location ?? content.documentRange.location

        layout.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            let y = frame.minY + origin.y - visibleRect.minY
            if y > bounds.height { return false }
            let offset = content.offset(
                from: content.documentRange.location,
                to: fragment.rangeInElement.location
            )
            // One number per fragment: a fragment is a paragraph, so a wrapped
            // line is numbered once, at its first visual line.
            draw(
                number: lineNumber(forCharacterOffset: offset, in: source),
                y: y,
                attributes: attributes
            )
            return true
        }
    }

    private func draw(number: Int, y: CGFloat, attributes: [NSAttributedString.Key: Any]) {
        let label = "\(number)" as NSString
        let size = label.size(withAttributes: attributes)
        label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y), withAttributes: attributes)
    }
}

extension EditorHostView {

    /// The character range styling covers: whatever TextKit 2 has laid out for
    /// the viewport, plus a margin either side.
    ///
    /// Styling the whole document was what made typing unusable. Every
    /// `setAttributes` over the full range invalidates every laid-out fragment,
    /// so TextKit 2 re-estimates the document's height and the scrollbar jumps —
    /// on every debounced reparse, which is continuously while typing. TextKit 2
    /// only lays out the viewport; styling should only cover what it laid out.
    ///
    /// The margin means a small scroll does not immediately expose unstyled
    /// text, and the caret's neighbourhood is always covered.
    func styledCharacterRange(margin: Int = 6000) -> NSRange {
        let length = (textView.string as NSString).length
        guard length > 0 else { return NSRange(location: 0, length: 0) }

        guard let layout = textView.textLayoutManager,
              let content = layout.textContentManager,
              let viewport = layout.textViewportLayoutController.viewportRange
        else {
            // Not laid out yet — style a bounded window from the top rather than
            // the whole document.
            return NSRange(location: 0, length: min(length, margin * 2))
        }

        let start = content.offset(from: content.documentRange.location, to: viewport.location)
        let end = content.offset(from: content.documentRange.location, to: viewport.endLocation)
        let lower = max(start - margin, 0)
        let upper = min(end + margin, length)
        return NSRange(location: lower, length: max(upper - lower, 0))
    }

    /// Applies styling without moving the viewport or the caret.
    ///
    /// The scroll position is restored by putting the clip view's origin back
    /// exactly. The previous approach called `scrollRangeToVisible` on the
    /// character at the top of the viewport, which scrolls that character *into
    /// view* — snapping it to an edge rather than leaving the page where it was.
    func applyStyle(base: [NSAttributedString.Key: Any], runs: [ElementStyler.Run]) {
        guard let storage = textView.textStorage else { return }
        let range = styledCharacterRange()
        guard range.length > 0 else { return }

        let origin = scrollView.contentView.bounds.origin
        let selection = textView.selectedRanges
        let undoManager = textView.undoManager
        undoManager?.disableUndoRegistration()
        defer { undoManager?.enableUndoRegistration() }

        storage.beginEditing()
        storage.setAttributes(base, range: range)
        for run in runs {
            let overlap = NSIntersectionRange(run.range, range)
            if overlap.length > 0 { storage.addAttributes(run.attributes, range: overlap) }
        }
        storage.endEditing()
        lastStyledRange = range

        // Only if something actually moved: assigning selection can itself
        // scroll, so it is not a free no-op.
        if textView.selectedRanges.map(\.rangeValue) != selection.map(\.rangeValue) {
            textView.selectedRanges = selection
        }
        if scrollView.contentView.bounds.origin != origin {
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    /// True when the viewport has moved far enough that styling no longer covers
    /// it, so scrolling can re-style without doing so on every frame.
    func needsRestyleForViewport() -> Bool {
        guard let last = lastStyledRange else { return true }
        let current = styledCharacterRange(margin: 0)
        return !NSLocationInRange(current.location, last)
            || !NSLocationInRange(max(NSMaxRange(current) - 1, current.location), last)
    }
}
