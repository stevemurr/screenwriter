import AppKit
import FountainKit

/// Styles typed text *before it is ever drawn*.
///
/// ## The problem this replaces
/// Styling used to be entirely downstream of the debounced parse: a keystroke
/// reached `ScreenplayModel.text`, waited out a 120ms debounce, was parsed off
/// the main actor, bumped `revision`, and only then did the surface compute
/// attributes and write them into storage. So every character was laid out twice
/// — once with whatever attributes it inherited from its neighbour, and again a
/// beat later with the right ones. That second pass is the visible one, and
/// because the debounce gates it, it lands *after the writer stops typing*,
/// which is exactly when the eye is free to notice it.
///
/// ## The hook, and the one that looked right but was not
/// This runs in two halves: the storage delegate *records* which characters
/// changed, and `NSTextView.didChangeText()` — overridden in
/// `ScreenplayTextView` — styles them. `didChangeText` is called synchronously
/// at the end of every text-changing operation, long before the run loop reaches
/// a display cycle, so the attributes are in place the first time the new text
/// is ever drawn. Layout in TextKit is lazy; what matters is not being inside
/// the edit, it is being ahead of the draw.
///
/// Styling directly from `textStorage(_:willProcessEditing:…)` is the obvious
/// design and it is wrong, in a way worth writing down because it looks
/// completely fine until you type two characters. Writing attributes there calls
/// `edited(.editedAttributes:…)` re-entrantly, and `NSTextStorage` coalesces
/// that into the edit already in flight — so the range AppKit is told about
/// stops being "the character you typed" and becomes "the whole block that was
/// restyled". `NSTextView` then fixes the selection against that widened range
/// and puts the caret at the end of it. Measured: of twelve keystrokes typed
/// into the middle of a line, one landed there and the other eleven at the end
/// of the document.
///
/// ## What it refuses
/// `LiveClassifier` documents the two constructs that are not bounded by a blank
/// line — the boneyard and the title page — and this is where they are refused.
/// A refusal is not a failure: the debounced parse still styles the text a
/// moment later, which is precisely the old behaviour. Anything it declines to
/// do it reports through `markUnstyled`, so the async pass knows not to treat
/// that text as already handled.
///
/// See Rule 2: this writes *attributes only*. It never touches a character.
@MainActor
final class LiveStyler: NSObject, NSTextStorageDelegate {

    /// Set by the surface whenever the type size changes.
    var fontSize: CGFloat = 12

    /// Turned off for a document whose last full parse contained a boneyard.
    /// `/* … */` spans blank lines, so a window has no way to know it is inside
    /// one, and guessing would style live text differently from the parse.
    var allowsLiveStyling = true

    /// The title page's extent from the last full parse. Rule 7: title pages are
    /// parsed only at the head of the document, and `CUT TO:` matches a naive
    /// `Key:` pattern, so a window that reaches the head is refused.
    var titlePageEnd = 0

    /// Called with the edited range whenever an edit is *not* styled here, so
    /// the debounced pass knows it still owns that text.
    var markUnstyled: ((NSRange) -> Void)?

    /// Characters changed since the last flush, unioned. Recorded rather than
    /// styled on the spot for the reason in the type comment above.
    private var pendingEdit: NSRange?

    /// Edits larger than this are left to the debounced parse. A document load
    /// or a large paste replaces everything, and classifying it synchronously on
    /// the main actor would be the one thing this path must never do — the async
    /// parse is about to produce the same answer anyway.
    private static let maximumEdit = 4_096

    #if DEBUG
    /// Counted so a test can assert that typing styled through this path and not
    /// through the debounced one.
    private(set) var styledEdits = 0
    private(set) var refusedEdits = 0
    func resetCounts() {
        styledEdits = 0
        refusedEdits = 0
    }
    #endif

    /// Records what changed. Deliberately does no work: this runs inside the
    /// storage's edit, where writing attributes would widen the edited range out
    /// from under the caret.
    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        pendingEdit = pendingEdit.map { NSUnionRange($0, editedRange) } ?? editedRange
    }

    /// Discards anything recorded but not yet styled — for a document load or a
    /// revert, where the debounced pass is about to style everything anyway.
    func discardPendingEdit() {
        pendingEdit = nil
    }

    /// Styles what changed. Called from `ScreenplayTextView.didChangeText()`,
    /// which is synchronous with the edit and well ahead of the display cycle.
    func flush(_ textStorage: NSTextStorage, undoManager: UndoManager?) {
        guard let edited = pendingEdit else { return }
        pendingEdit = nil

        guard allowsLiveStyling, edited.length <= Self.maximumEdit else {
            refuse(edited)
            return
        }

        let source = textStorage.string as NSString
        guard let window = LiveClassifier.window(for: edited, in: source),
              window.location >= titlePageEnd,
              !LiveClassifier.couldOpenTitlePage(window, in: source),
              NSMaxRange(window) <= source.length
        else {
            refuse(edited)
            return
        }

        let styler = ElementStyler(fontSize: fontSize)
        let runs = styler.runs(for: LiveClassifier.classify(window, in: source))

        // Rule 2 holds here as everywhere: attributes only. Undo registration is
        // off for the same reason `applyStyle` turns it off — a ⌘Z must undo
        // what the writer typed, never how it was coloured.
        undoManager?.disableUndoRegistration()
        defer { undoManager?.enableUndoRegistration() }

        textStorage.beginEditing()
        textStorage.setAttributes(styler.baseAttributes(), range: window)
        for run in runs {
            textStorage.addAttributes(run.attributes, range: run.range)
        }
        textStorage.endEditing()
        #if DEBUG
        styledEdits += 1
        #endif
    }

    private func refuse(_ range: NSRange) {
        #if DEBUG
        refusedEdits += 1
        #endif
        markUnstyled?(range)
    }
}

/// An `NSTextView` that says when its text changed.
///
/// `didChangeText()` is AppKit's own end-of-edit hook: every path that changes
/// the text — typing, paste, undo, an input method committing — goes through it,
/// with the selection already fixed up. A delegate callback would cover most of
/// that but not all, and `EditorHostView` has to work with no delegate attached
/// at all, which is how `TypingCostTests` measures AppKit's own share of a
/// keystroke.
final class ScreenplayTextView: NSTextView {
    var onTextDidChange: (() -> Void)?
    var onSelectionDidChange: (() -> Void)?
    /// Returns true when something else has consumed the key — the `/` menu
    /// taking ↑, ↓, ⏎ and ⎋ while it is open. Everything it does not claim falls
    /// through to `NSTextView`, which is what lets typing keep filtering the
    /// list instead of being swallowed by it.
    var interceptCommand: ((Selector) -> Bool)?

    override func didChangeText() {
        super.didChangeText()
        onTextDidChange?()
    }

    override func setSelectedRanges(
        _ ranges: [NSValue],
        affinity: NSSelectionAffinity,
        stillSelecting: Bool
    ) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        onSelectionDidChange?()
    }

    override func doCommand(by selector: Selector) {
        if interceptCommand?(selector) == true { return }
        super.doCommand(by: selector)
    }
}
