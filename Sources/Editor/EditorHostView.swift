import AppKit
import FountainKit
import SwiftUI

/// Scroll view and text view.
///
/// Ported from topside's `TextKitEditorHostView`. See Rule 1 in
/// `FountainEditorSurface`: nothing in here may read `textView.layoutManager`.
@MainActor
public final class EditorHostView: NSView {
    public let scrollView: NSScrollView
    public let textView: NSTextView

    /// The range styling currently covers, so scrolling knows when to extend it.
    var lastStyledRange: NSRange?
    /// The runs `applyStyle` last wrote, so the next call can tell whether
    /// anything about the styling actually changed.
    private var lastAppliedRuns: [ElementStyler.Run]?
    /// Document length when `lastStyledRange` was recorded, so the next pass can
    /// tell text that appeared since — which `LiveStyler` has already styled —
    /// from text that was never covered at all.
    private var lastAppliedLength = 0
    /// Text that `LiveStyler` declined to style, which the next `applyStyle`
    /// therefore has to cover even if no run's signature changed.
    private var unstyledRange: NSRange?
    #if DEBUG
    /// Counts the times the debounced pass actually wrote attributes. A test
    /// asserts this stays at zero while the writer types, which is the whole
    /// claim: the render pass after typing stops is gone because there is no
    /// longer anything for it to do.
    private(set) var styleWrites = 0
    func resetStyleWrites() { styleWrites = 0 }
    #endif
    /// Styles typed text inside the edit transaction, so it is laid out correct
    /// the first time. See `LiveStyler`.
    let liveStyler = LiveStyler()
    /// The `/` command menu, and the completion list — one popup, see
    /// `SlashMenuModel.Kind`.
    let slashMenu = SlashMenuModel()
    /// What this script has already called its people and places. Refreshed
    /// from each parse by the surface; empty until then, which only means the
    /// list has nothing to offer yet.
    var vocabulary = ScriptVocabulary()
    private var slashMenuHost: NSHostingView<SlashMenuView>?
    /// When set, text lays out in a fixed-width column centred in the pane —
    /// the page's 1.5"–7.5" measure, so styled mode reads like a page.
    private var scriptColumnWidth: CGFloat?

    public override init(frame frameRect: NSRect) {
        // TextKit 2. `NSTextLayoutManager` lays out only the fragments the
        // viewport needs, so opening a 91 KB script does not pay for laying out
        // every line up front.
        textView = ScreenplayTextView(usingTextLayoutManager: true)
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

        // Styling happens inside the edit, not after it. NSTextView leaves the
        // storage delegate free; TextKit 2's own hook into the storage is
        // `textStorageObserver`, which `NSTextContentStorage` owns and this does
        // not touch.
        textView.textStorage?.delegate = liveStyler
        liveStyler.markUnstyled = { [weak self] range in self?.markUnstyled(range) }
        (textView as? ScreenplayTextView)?.onTextDidChange = { [weak self] in
            guard let self, let storage = self.textView.textStorage else { return }
            self.liveStyler.flush(storage, undoManager: self.textView.undoManager)
            self.refreshSlashMenu()
        }
        (textView as? ScreenplayTextView)?.onSelectionDidChange = { [weak self] in
            self?.refreshSlashMenu()
        }
        // Only the keys the menu owns; everything else falls through to the text
        // view, which is what keeps typing filtering the list.
        (textView as? ScreenplayTextView)?.interceptCommand = { [weak self] selector in
            self?.handleSlashCommand(selector) ?? false
        }
    }

    // MARK: - The slash menu

    /// Re-evaluates whether the `/` menu should be open, and where.
    ///
    /// Runs on every text change and every caret move, so it is on the typing
    /// path: `SlashQuery.detect` looks at one line and gives up on the first
    /// character when that line does not start with `/`, which is every line in
    /// a screenplay.
    func refreshSlashMenu() {
        let source = textView.string as NSString
        let caret = textView.selectedRange().location

        if let match = SlashQuery.detect(in: source, caret: caret) {
            slashMenu.update(
                kind: .slash,
                items: SlashCommand.matching(match.query).map(\.menuItem),
                range: match.range
            )
        } else if let completion = Completion.suggest(
            in: source, caret: caret, vocabulary: vocabulary
        ) {
            slashMenu.update(
                kind: .completion,
                items: completion.menuItems,
                range: completion.range
            )
        } else {
            slashMenu.dismiss()
        }
        layoutSlashMenu()
    }

    func dismissSlashMenu() {
        slashMenu.dismiss()
        layoutSlashMenu()
    }

    /// Inserts a command's shorthand in place of the typed `/query`.
    ///
    /// Through `insertText(_:replacementRange:)` rather than the storage, so it
    /// is one undoable step and the live styler runs over it — pick "Act" and
    /// the line is already in section colour before the menu has closed.
    func commitSlashCommand(_ command: EditorMenuItem) {
        let range = slashMenu.queryRange
        slashMenu.dismiss()
        guard NSMaxRange(range) <= (textView.string as NSString).length else {
            layoutSlashMenu()
            return
        }
        textView.insertText(command.insertion, replacementRange: range)
        textView.setSelectedRange(
            NSRange(location: command.caretLocation(insertedAt: range.location), length: 0)
        )
        layoutSlashMenu()
    }

    /// Returns true when the menu consumed the key.
    private func handleSlashCommand(_ selector: Selector) -> Bool {
        guard slashMenu.isVisible else { return false }
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            slashMenu.moveSelection(by: -1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            slashMenu.moveSelection(by: 1)
            return true
        case #selector(NSResponder.insertTab(_:)):
            guard let command = slashMenu.selected else { return false }
            commitSlashCommand(command)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            // On a completion the line is real text and Return means new line,
            // unless the writer has deliberately picked a row. On a `/` line
            // there is nothing else Return could mean.
            guard slashMenu.kind == .slash || slashMenu.hasChosenExplicitly,
                  let command = slashMenu.selected
            else {
                dismissSlashMenu()
                return false
            }
            commitSlashCommand(command)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismissSlashMenu()
            return true
        default:
            return false
        }
    }

    /// Places the menu under the line the `/` is on, flipping above it when
    /// there is no room below.
    private func layoutSlashMenu() {
        guard slashMenu.isVisible else {
            slashMenuHost?.removeFromSuperview()
            slashMenuHost = nil
            return
        }

        let host: NSHostingView<SlashMenuView>
        if let existing = slashMenuHost {
            host = existing
        } else {
            host = NSHostingView(
                rootView: SlashMenuView(model: slashMenu) { [weak self] command in
                    self?.commitSlashCommand(command)
                }
            )
            // `NSHostingView` opts into Auto Layout on creation, which quietly
            // ignores the frame set below and parks the menu in the corner.
            // This view positions the menu by hand, against the caret.
            host.translatesAutoresizingMaskIntoConstraints = true
            addSubview(host)
            slashMenuHost = host
        }

        let size = NSSize(
            width: SlashMenuView.width,
            height: SlashMenuView.height(rows: slashMenu.items.count)
        )
        guard let caretLine = caretLineRect() else { return }

        // This view is not flipped, so "below the caret's line" is *lower* y —
        // `minY - height`, not `maxY + gap`. Getting that backwards put the menu
        // above the line, which then failed the fits-on-screen test and flipped
        // it to the bottom edge of the editor, nowhere near the caret.
        let gap: CGFloat = 5
        var origin = NSPoint(x: caretLine.minX, y: caretLine.minY - size.height - gap)
        if origin.y < bounds.minY {
            let above = caretLine.maxY + gap
            // Below if there is room, above if there is not, and whichever is
            // roomier when neither fits.
            origin.y = above + size.height <= bounds.maxY
                ? above
                : max(bounds.maxY - size.height, bounds.minY)
        }
        origin.x = min(
            max(origin.x, bounds.minX + 8),
            max(bounds.maxX - size.width - 8, bounds.minX + 8)
        )
        host.frame = NSRect(origin: origin, size: size)
    }

    /// The caret's line, in this view's coordinates.
    ///
    /// Rule 1: through `textLayoutManager`. Asking `layoutManager` for a glyph
    /// rect would drop the whole editor into TextKit 1.
    private func caretLineRect() -> NSRect? {
        guard let layout = textView.textLayoutManager,
              let content = layout.textContentManager
        else { return nil }
        // A caret at the very end of the document sits at `documentRange`'s end
        // location, and nothing *starts* there — `textLayoutFragment(for:)`
        // returns nil, so the menu was placed nowhere. Ask about the character
        // before it instead, which is on the same line.
        let length = (textView.string as NSString).length
        let caret = min(max(textView.selectedRange().location, 0), max(length - 1, 0))
        guard let location = content.location(content.documentRange.location, offsetBy: caret)
        else { return nil }
        // The character that opened the menu was typed a moment ago and TextKit 2
        // lays out lazily, so without this there is no fragment to ask about yet
        // and the menu is placed nowhere at all.
        if let range = NSTextRange(location: content.documentRange.location, end: location) {
            layout.ensureLayout(for: range)
        }
        guard let fragment = layout.textLayoutFragment(for: location) else { return nil }

        // The caret's own x, not the line's left edge.
        //
        // `layoutFragmentFrame` spans the whole text container, so its `minX` is
        // the column, not the cursor — the menu opened under the left margin
        // however far along the line the writer was. The line fragment knows
        // where each character sits; ask it.
        var frame = fragment.layoutFragmentFrame
        let fragmentStart = content.offset(
            from: content.documentRange.location,
            to: fragment.rangeInElement.location
        )
        if let line = fragment.textLineFragments.first(where: {
            NSLocationInRange(caret - fragmentStart, $0.characterRange)
                || NSMaxRange($0.characterRange) == caret - fragmentStart
        }) {
            let inLine = caret - fragmentStart - line.characterRange.location
            frame.origin.x += line.typographicBounds.minX
                + line.locationForCharacter(at: inLine).x
            frame.origin.y += line.typographicBounds.minY
            frame.size.height = line.typographicBounds.height
        }
        frame.size.width = 1
        frame.origin.x += textView.textContainerOrigin.x
        frame.origin.y += textView.textContainerOrigin.y
        return convert(frame, from: textView)
    }

    /// Puts an anchored line back at the *top* of the viewport.
    ///
    /// Lives here rather than in the coordinator because the test that guards it
    /// needs the real implementation: a copy of this logic in the test passed
    /// happily while the app scrolled to the top of the script.
    ///
    /// `scrollRangeToVisible` is deliberately not used: it scrolls the minimum
    /// distance to bring the character *into view*, so an anchor just off the top
    /// lands at the bottom edge and the page appears to jump by a screen.
    func restoreScroll(anchor: EditorScrollAnchor) {
        guard let layout = textView.textLayoutManager,
              let content = layout.textContentManager
        else { return }

        let length = (textView.string as NSString).length
        let offset = min(max(anchor.characterOffset, 0), length)
        guard let location = content.location(content.documentRange.location, offsetBy: offset)
        else { return }

        // Lay out as far as the anchor before asking where it is.
        //
        // TextKit 2 lays out the viewport and nothing else, and a change big
        // enough to need an anchor — a type-size change re-heights every
        // fragment in the document — throws that layout away. Without this the
        // fragment comes back unpositioned, its frame origin is zero, and
        // "restore the anchor" scrolls the writer to the top of their script.
        // Bounded by the anchor, not by the document: everything past it stays
        // unlaid, which is the property TextKit 2 is here for.
        if let range = NSTextRange(location: content.documentRange.location, end: location) {
            layout.ensureLayout(for: range)
        }
        guard let fragment = layout.textLayoutFragment(for: location) else { return }

        let y = fragment.layoutFragmentFrame.minY + textView.textContainerOrigin.y
        scrollView.contentView.scroll(
            to: NSPoint(x: max(anchor.horizontalOffset, 0), y: max(y, 0))
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Records text the live styler declined, so the debounced pass covers it.
    func markUnstyled(_ range: NSRange) {
        unstyledRange = unstyledRange.map { NSUnionRange($0, range) } ?? range
    }

    /// Forces the next `applyStyle` to write the whole window rather than a
    /// diff — for a mode or type-size change, where every run's attributes
    /// change but no run's *signature* does.
    func invalidateAppliedStyle() {
        lastAppliedRuns = nil
        lastStyledRange = nil
        lastAppliedLength = 0
        // A load or a revert replaces the whole document. Styling the "edit" it
        // recorded would mean classifying all of it on the main actor, to reach
        // the same answer the parse is already computing off it.
        liveStyler.discardPendingEdit()
        unstyledRange = nil
    }

    static let accessibilityIdentifier = "editor.surface" 

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
    /// The sub-range of `window` that actually has to be rewritten, or nil when
    /// nothing does.
    ///
    /// With `LiveStyler` in front of it, the debounced pass is usually applying
    /// styling that is *already on screen and already correct*. Writing it again
    /// is not free: `setAttributes` over the window invalidates every laid-out
    /// fragment in it, so TextKit re-lays out the visible page and the writer
    /// sees a render pass a beat after they stop typing — the second half of the
    /// jank this work removes, and the half that survived making the first half
    /// instant.
    ///
    /// The comparison is by signature, not by range, and that is the point:
    /// typing a character into a line of dialogue changes every subsequent
    /// element's *location* while changing nothing about how any of them are
    /// drawn. `NSTextStorage` already carried the attributes along with the
    /// text. So a pure prefix/suffix signature match means there is genuinely
    /// nothing to write.
    private func dirtyRange(from old: [ElementStyler.Run], to new: [ElementStyler.Run]) -> NSRange? {
        var prefix = 0
        let shared = min(old.count, new.count)
        while prefix < shared, old[prefix].signature == new[prefix].signature { prefix += 1 }

        var suffix = 0
        while suffix < shared - prefix,
              old[old.count - 1 - suffix].signature == new[new.count - 1 - suffix].signature {
            suffix += 1
        }

        // Every run in `new` matched one in `old`. Either nothing moved, or what
        // moved took its attributes with it. `old` having runs left over means
        // text was deleted, and deleted text needs no styling.
        let changed = new[prefix..<(new.count - suffix)]
        guard !changed.isEmpty else { return nil }
        let location = changed.map(\.range.location).min() ?? 0
        let end = changed.map { NSMaxRange($0.range) }.max() ?? 0
        guard end > location else { return nil }
        return NSRange(location: location, length: end - location)
    }

    /// The covered range is the whole window, not just what was rewritten:
    /// anything outside it was already styled by an earlier pass, or by
    /// `LiveStyler` inside the edit that produced it.
    private func recordApplied(window: NSRange, runs: [ElementStyler.Run], length: Int) {
        lastStyledRange = window
        lastAppliedRuns = runs
        lastAppliedLength = length
        unstyledRange = nil
    }

    func applyStyle(base: [NSAttributedString.Key: Any], runs: [ElementStyler.Run]) {
        guard let storage = textView.textStorage else { return }
        let window = styledCharacterRange()
        guard window.length > 0 else { return }

        // Only diff when the previous pass covered everything this one needs to.
        // A scroll that reveals unstyled text, a mode change, or a fresh document
        // all take the full path.
        //
        // "Covered" allows for the document having grown since: text that
        // appeared after the last pass is exactly the text `LiveStyler` styled
        // inside the edit. If it declined, `unstyledRange` is set below and
        // forces the write anyway. Without this the optimisation would never
        // fire on a short script, where the window is the whole document and so
        // grows by a character on every keystroke.
        let growth = max(storage.length - lastAppliedLength, 0)
        var range = window
        if let previous = lastAppliedRuns,
           let covered = lastStyledRange,
           window.location >= covered.location,
           NSMaxRange(window) <= NSMaxRange(covered) + growth {
            var dirty = dirtyRange(from: previous, to: runs)
            // Text the live styler refused is dirty whether or not any signature
            // changed — nothing has styled it yet.
            if let pending = unstyledRange {
                dirty = dirty.map { NSUnionRange($0, pending) } ?? pending
            }
            range = dirty.map { NSIntersectionRange($0, window) } ?? NSRange(location: 0, length: 0)
            guard range.length > 0 else {
                recordApplied(window: window, runs: runs, length: storage.length)
                return
            }
        }

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
        #if DEBUG
        styleWrites += 1
        #endif
        recordApplied(window: window, runs: runs, length: storage.length)

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
