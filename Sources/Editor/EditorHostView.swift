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
        textView.textContainerInset = NSSize(width: 10, height: 12)
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        scrollView = NSScrollView(frame: .zero)
        scrollView.drawsBackground = true
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView

        rulerView = LineNumberRulerView(textView: textView, scrollView: scrollView)
        scrollView.verticalRulerView = rulerView
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        super.init(frame: frameRect)
        addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

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
            inset = max((available - column) / 2, 16)
        } else {
            inset = 10
        }
        if abs(textView.textContainerInset.width - inset) > 0.5 {
            textView.textContainerInset = NSSize(width: inset, height: 12)
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

    static let thickness: CGFloat = 44

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
        textView.backgroundColor.setFill()
        gutter.intersection(rect).fill()

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
