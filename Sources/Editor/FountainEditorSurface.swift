import AppKit
import FountainKit
import Observation
import SwiftUI

/// Where the viewport was, expressed as a character offset so it survives a
/// relayout caused by a change of type size.
public struct EditorScrollAnchor: Sendable, Hashable {
    public var characterOffset: Int = 0
    public var horizontalOffset: CGFloat = 0
    public init(characterOffset: Int = 0, horizontalOffset: CGFloat = 0) {
        self.characterOffset = characterOffset
        self.horizontalOffset = horizontalOffset
    }
}

/// A request from outside the editor to move the caret — clicking a scene in
/// the sidebar, say.
///
/// Carries a token rather than just an offset so that jumping twice to the same
/// place still registers as two separate requests.
public struct EditorJump: Sendable, Hashable {
    public var token: UInt64
    public var offset: Int
}

/// A request from outside the editor to *change* the text — auto-fixes, for now.
///
/// Routed through the text view rather than the model's `text` for two reasons
/// that are both about not being noticed: `NSTextView` registers the change with
/// the undo manager, so one ⌘Z takes the fix back; and it adjusts the selection
/// for the edit, so a fix applied above the caret does not shift the caret out
/// from under the writer. Assigning `model.text` does neither.
public struct EditorEditRequest: Sendable, Hashable {
    public var token: UInt64
    /// Back-to-front, as `AutoFix.edits` returns them.
    public var edits: [AutoFix.Edit]
}

public struct EditorSurfaceState: Sendable {
    public var selectedRanges: [NSRange] = [NSRange(location: 0, length: 0)]
    public var scrollAnchor = EditorScrollAnchor()
    public var ownsFocus = false
    /// Caret position for the status bar, one-based.
    public var caretLine = 1
    public var caretColumn = 1
    public var pendingJump: EditorJump?
    public var pendingEdits: EditorEditRequest?
    public init() {}
}

@MainActor
@Observable
public final class FountainEditorSession {
    public var state = EditorSurfaceState()
    private var jumpCounter: UInt64 = 0

    public init() {}

    /// Moves the caret to a source offset and scrolls it into view. This is what
    /// makes the sidebar a navigator rather than a read-only outline.
    public func jump(to offset: Int) {
        jumpCounter &+= 1
        state.pendingJump = EditorJump(token: jumpCounter, offset: offset)
    }

    /// Asks the surface to apply text edits through the text view.
    public func apply(_ edits: [AutoFix.Edit]) {
        guard !edits.isEmpty else { return }
        jumpCounter &+= 1
        state.pendingEdits = EditorEditRequest(token: jumpCounter, edits: edits)
    }
}

/// The Fountain source pane.
///
/// Adapted from `topside/Sources/WorkPane/Editor/TextKitEditorSurface.swift`,
/// which solved the hard parts already: TextKit 2 without falling back to
/// TextKit 1, scroll-anchor preservation,
/// undo that actually round-trips through a SwiftUI binding, and the guarded
/// path for applying computed attributes without disturbing the caret. The
/// Fountain-specific part is only which attributes get applied.
///
/// ## Rule 1
/// **Never touch `textView.layoutManager`.** Reading it once puts AppKit into
/// TextKit 1 compatibility mode, silently and permanently — no error, no
/// visible change, the incremental-layout performance simply disappears. Every
/// geometry query here goes through `textLayoutManager`, and no test may assert
/// on `layoutManager`.
public struct FountainEditorSurface: NSViewRepresentable {
    @Binding var text: String
    let script: ParsedScript
    let diagnostics: [Diagnostic]
    /// Editor-only type size; the page geometry is untouched by it.
    let fontSize: CGFloat
    /// Bumped by the owner when `script` reflects new content, so the styler
    /// knows to re-run without diffing the whole document.
    let revision: UInt64
    /// Changed when the text is replaced from outside (a file load or revert),
    /// as opposed to edited by the user.
    let replacementToken: UInt64
    let session: FountainEditorSession

    public init(
        text: Binding<String>,
        script: ParsedScript,
        diagnostics: [Diagnostic],
        fontSize: CGFloat,
        revision: UInt64,
        replacementToken: UInt64,
        session: FountainEditorSession
    ) {
        self._text = text
        self.script = script
        self.diagnostics = diagnostics
        self.fontSize = fontSize
        self.revision = revision
        self.replacementToken = replacementToken
        self.session = session
    }

    public func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    public func makeNSView(context: Context) -> EditorHostView {
        let host = EditorHostView()
        context.coordinator.host = host
        host.textView.delegate = context.coordinator
        context.coordinator.observeUndo(for: host.textView)
        context.coordinator.observeViewport(for: host)
        context.coordinator.applyExternalText(text, replacementToken: replacementToken, resetUndo: true)
        context.coordinator.applyTypeSize(fontSize)
        context.coordinator.scheduleStyling(
            script: script, diagnostics: diagnostics,
            fontSize: fontSize, revision: revision
        )
        return host
    }

    public func updateNSView(_ host: EditorHostView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.host = host

        if context.coordinator.appliedReplacementToken != replacementToken {
            context.coordinator.applyExternalText(
                text,
                replacementToken: replacementToken,
                resetUndo: true
            )
        } else if !context.coordinator.textViewHolds(text), !context.coordinator.isEmittingUserEdit {
            // A binding change with no replacement token is still applied
            // byte-exactly, but it must not be mistaken for a user edit.
            context.coordinator.applyExternalText(
                text,
                replacementToken: replacementToken,
                resetUndo: false
            )
        }

        context.coordinator.applyTypeSize(fontSize)
        context.coordinator.applyPendingEdits(session.state.pendingEdits)
        context.coordinator.applyPendingJump(session.state.pendingJump)
        context.coordinator.scheduleStyling(
            script: script, diagnostics: diagnostics,
            fontSize: fontSize, revision: revision
        )
    }

    public static func dismantleNSView(_ host: EditorHostView, coordinator: Coordinator) {
        coordinator.stylingTask?.cancel()
        coordinator.removeUndoObservers()
        coordinator.removeViewportObserver()
        host.textView.delegate = nil
    }

    @MainActor
    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: FountainEditorSurface
        weak var host: EditorHostView?
        var appliedReplacementToken: UInt64?
        var isEmittingUserEdit = false
        var stylingTask: Task<Void, Never>?
        private var appliedJumpToken: UInt64?
        private var appliedEditToken: UInt64?
        private var appliedFontSize: CGFloat?
        private var styleKey: StyleKey?
        private var styledRuns: [ElementStyler.Run]?
        private var viewportObserver: NSObjectProtocol?
        private var undoObservers: [NSObjectProtocol] = []

        private struct StyleKey: Equatable {
            let revision: UInt64
            let fontSize: CGFloat
            let source: String
        }

        init(parent: FountainEditorSurface) { self.parent = parent }

        // MARK: - Delegate

        public func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView,
                  textView === host?.textView else { return }
            captureState()
            emitTextIfChanged()
        }

        public func textViewDidChangeSelection(_ notification: Notification) {
            captureState()
        }

        /// Pushes the text view's contents out through the binding.
        ///
        /// Split out of `textDidChange` because undo does not route through it:
        /// a programmatic undo mutates storage without the delegate callback, so
        /// the binding kept the pre-undo value, the next `updateNSView` saw a
        /// mismatch, and helpfully restored what the user had just undone. Undo
        /// appeared to do nothing.
        ///
        /// ## The text has to leave here as a snapshot
        /// `textView.string` is a lazily bridged `NSString`, not a value — see
        /// `EditorText.snapshot(of:)`, which is also why this got *faster*.
        /// Comparing or storing a bridged string re-transcodes the whole
        /// document, and a keystroke paid that twice: once for the guard here
        /// and once in `ScreenplayModel.text`'s `didSet`. That was 7.9ms of the
        /// 12.8ms a keystroke cost. Snapshotting once costs 0.17ms and leaves
        /// every later comparison a native memcmp.
        func emitTextIfChanged() {
            guard let textView = host?.textView else { return }
            let source = EditorText.snapshot(of: textView.string as NSString)
            guard source != parent.text else { return }
            isEmittingUserEdit = true
            parent.text = source
            isEmittingUserEdit = false
        }

        /// Whether the text view still holds exactly this source.
        ///
        /// `NSString.isEqual` rather than Swift's `==`. Since `emitTextIfChanged`
        /// snapshots, the two sides now have different representations — native
        /// Swift storage against the text view's bridged `NSString` — and Swift's
        /// `==` has to transcode the whole document to compare them. That is
        /// 4ms on the 91 KB script, and this runs on every scroll notification
        /// and every SwiftUI update. `isEqual` compares in C, lengths first.
        func textViewHolds(_ source: String) -> Bool {
            guard let host else { return false }
            return (host.textView.string as NSString).isEqual(source as NSString)
        }

        func observeViewport(for host: EditorHostView) {
            guard viewportObserver == nil else { return }
            viewportObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: host.scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.restyleForViewportIfNeeded() }
            }
        }

        func removeViewportObserver() {
            if let viewportObserver { NotificationCenter.default.removeObserver(viewportObserver) }
            viewportObserver = nil
        }

        func observeUndo(for textView: NSTextView) {
            guard undoObservers.isEmpty else { return }
            let center = NotificationCenter.default
            for name in [
                NSNotification.Name.NSUndoManagerDidUndoChange,
                NSNotification.Name.NSUndoManagerDidRedoChange
            ] {
                let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    // Nothing is read from the notification, so its lack of
                    // Sendable conformance does not matter. Identifying the
                    // posting manager is unnecessary: `emitTextIfChanged`
                    // compares our own text view against the binding, so an
                    // unrelated manager's undo settles as a no-op.
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.captureState()
                        self.emitTextIfChanged()
                    }
                }
                undoObservers.append(token)
            }
        }

        func removeUndoObservers() {
            undoObservers.forEach(NotificationCenter.default.removeObserver)
            undoObservers.removeAll()
        }

        // MARK: - Applying text and type size

        func applyExternalText(_ source: String, replacementToken: UInt64, resetUndo: Bool) {
            guard let host else { return }
            stylingTask?.cancel()
            styleKey = nil
            // Nothing that was applied to the old text says anything about the
            // new text, so the next pass must write the whole window.
            host.invalidateAppliedStyle()
            let textView = host.textView
            let priorRanges = normalizedRanges(
                parent.session.state.selectedRanges,
                utf16Length: (source as NSString).length
            )
            let priorAnchor = parent.session.state.scrollAnchor

            if !textViewHolds(source) {
                textView.string = source
                applyBaseAttributes()
            }
            textView.selectedRanges = priorRanges.map(NSValue.init(range:))
            if resetUndo { textView.undoManager?.removeAllActions() }
            appliedReplacementToken = replacementToken
            restoreScroll(anchor: priorAnchor)
        }

        /// Applies auto-fixes through the text view's own editing path.
        ///
        /// `shouldChangeText(inRanges:replacementStrings:)` is what registers the
        /// whole set as **one** undoable action — so a writer who does not want a
        /// fix presses ⌘Z once, not once per fix — and `didChangeText()` closes
        /// it, which is also what runs the live styler over the changed lines.
        func applyPendingEdits(_ request: EditorEditRequest?) {
            guard let request, appliedEditToken != request.token, let host else { return }
            appliedEditToken = request.token
            guard !request.edits.isEmpty, let storage = host.textView.textStorage else { return }

            let length = storage.length
            // The edits were computed against a parse; the writer may have typed
            // since. Anything that no longer fits the document is dropped rather
            // than clamped, because a clamped range replaces the wrong text.
            let valid = request.edits.filter { NSMaxRange($0.range) <= length }
            guard valid.count == request.edits.count else { return }

            let textView = host.textView
            guard textView.shouldChangeText(
                inRanges: valid.map { NSValue(range: $0.range) },
                replacementStrings: valid.map(\.replacement)
            ) else { return }

            storage.beginEditing()
            for edit in valid {
                storage.replaceCharacters(in: edit.range, with: edit.replacement)
            }
            storage.endEditing()
            textView.didChangeText()
            captureState()
            emitTextIfChanged()
        }

        /// Moves the caret in response to a sidebar selection, and centres the
        /// target rather than merely scrolling it barely into view.
        func applyPendingJump(_ jump: EditorJump?) {
            guard let jump, appliedJumpToken != jump.token, let host else { return }
            appliedJumpToken = jump.token
            let textView = host.textView
            let length = (textView.string as NSString).length
            let offset = min(max(jump.offset, 0), length)
            let target = NSRange(location: offset, length: 0)
            textView.selectedRanges = [NSValue(range: target)]
            textView.scrollRangeToVisible(target)
            // Bias the target towards the top of the viewport: a scene heading
            // pinned to the bottom edge hides the scene it introduces.
            if let layout = textView.textLayoutManager,
               let content = layout.textContentManager,
               let location = content.location(
                   content.documentRange.location,
                   offsetBy: offset
               ),
               let fragment = layout.textLayoutFragment(for: location) {
                var frame = fragment.layoutFragmentFrame
                frame.size.height = min(host.scrollView.contentSize.height, frame.height * 8)
                textView.scrollToVisible(frame.offsetBy(dx: 0, dy: textView.textContainerOrigin.y))
            }
            if textView.window?.firstResponder !== textView {
                textView.window?.makeFirstResponder(textView)
            }
        }

        /// Changing the type size preserves the caret and the viewport, because
        /// the document did not change — only its attributes and the width of
        /// the column they lay out in.
        func applyTypeSize(_ fontSize: CGFloat) {
            guard let host, appliedFontSize != fontSize else { return }
            let anchor = currentScrollAnchor()
            let ranges = host.textView.selectedRanges
            appliedFontSize = fontSize
            styleKey = nil
            // Every run's attributes change and no run's signature does, so the
            // diff in `applyStyle` would correctly conclude there is nothing to
            // do. Tell it otherwise.
            host.invalidateAppliedStyle()
            host.liveStyler.fontSize = fontSize
            // The script column is a measure in characters, so it grows with the
            // type just as the indents do.
            host.setScriptColumn(
                Style.scriptColumnWidth * (fontSize / PageLayout.letter.fontSize)
            )
            applyBaseAttributes()
            host.textView.selectedRanges = ranges
            restoreScroll(anchor: anchor)
        }

        private func applyBaseAttributes() {
            guard let host else { return }
            // Through the same scoped path: a full-document write here would
            // reintroduce the scroll jump on every type-size change.
            let styler = ElementStyler(fontSize: parent.fontSize)
            host.applyStyle(base: styler.baseAttributes(), runs: styledRuns ?? [])
            host.textView.backgroundColor = Style.editorBackground
            host.textView.insertionPointColor = .textColor
        }

        // MARK: - Styling

        func scheduleStyling(
            script: ParsedScript,
            diagnostics: [Diagnostic],
            fontSize: CGFloat,
            revision: UInt64
        ) {
            let key = StyleKey(revision: revision, fontSize: fontSize, source: script.source)
            guard key != styleKey else { return }
            styleKey = key
            stylingTask?.cancel()

            // What the live styler is allowed to decide for itself, refreshed
            // from each parse. Both are Rule-shaped: a boneyard spans blank
            // lines so a local window cannot see it (and `LiveClassifier`
            // explains why), and a title page is only a title page at the head
            // of the document (Rule 7).
            if let host {
                host.liveStyler.allowsLiveStyling = !script.elements.contains { $0.kind == .boneyard }
                host.liveStyler.titlePageEnd = script.titlePage.map { NSMaxRange($0.range) } ?? 0
                // The completion list is only as good as the last parse, which
                // is the right cadence: a name typed a second ago is already in
                // the cast by the time you type it again.
                host.vocabulary = ScriptVocabulary(script: script)
            }
            guard !script.source.isEmpty else { return }

            // Styling runs off the main actor and is applied only if the text
            // view still holds the exact source it was computed from.
            stylingTask = Task { [weak self] in
                let runs = await Task.detached(priority: .userInitiated) {
                    let styler = ElementStyler(fontSize: fontSize)
                    let length = (script.source as NSString).length
                    return styler.runs(for: script)
                        + styler.diagnosticRuns(diagnostics, length: length)
                }.value
                guard !Task.isCancelled else { return }
                self?.applyRuns(runs, key: key)
            }
        }

        private func applyRuns(_ runs: [ElementStyler.Run], key: StyleKey) {
            guard key == styleKey,
                  let host,
                  textViewHolds(key.source)
            else { return }

            // Held so scrolling can extend styling into newly revealed text
            // without recomputing the whole document.
            styledRuns = runs
            let styler = ElementStyler(fontSize: key.fontSize)
            host.applyStyle(base: styler.baseAttributes(), runs: runs)
        }

        /// Extends styling when the viewport moves past what is already styled.
        ///
        /// Styling covers the laid-out viewport plus a margin, so ordinary
        /// scrolling costs nothing; only crossing the margin does any work.
        func restyleForViewportIfNeeded() {
            guard let host, let runs = styledRuns, let key = styleKey,
                  host.needsRestyleForViewport(),
                  textViewHolds(key.source)
            else { return }
            let styler = ElementStyler(fontSize: key.fontSize)
            host.applyStyle(base: styler.baseAttributes(), runs: runs)
        }

        // MARK: - Viewport and caret

        /// Runs twice per keystroke — once for the text change and once for the
        /// selection change AppKit posts alongside it — and again on every
        /// arrow key, so everything it does is paid at typing rate. See
        /// `EditorText.lineAndColumn` for why the caret readout no longer
        /// indexes the whole document to find two integers.
        private func captureState() {
            guard let textView = host?.textView else { return }
            let ranges = textView.selectedRanges.map(\.rangeValue)
            parent.session.state.selectedRanges = ranges
            parent.session.state.scrollAnchor = currentScrollAnchor()
            parent.session.state.ownsFocus = textView.window?.firstResponder === textView
            if let caret = ranges.first?.location {
                let position = EditorText.lineAndColumn(
                    in: textView.string as NSString,
                    at: caret
                )
                parent.session.state.caretLine = position.line
                parent.session.state.caretColumn = position.column
            }
        }

        private func currentScrollAnchor() -> EditorScrollAnchor {
            guard let host,
                  let layout = host.textView.textLayoutManager,
                  let content = layout.textContentManager
            else { return parent.session.state.scrollAnchor }

            let visible = host.scrollView.documentVisibleRect
            // Anchoring on the fragment at the top of the viewport. Asking for a
            // glyph range would mean reaching for `layoutManager`, which drops
            // the whole editor back to TextKit 1 — see Rule 1.
            let top = max(visible.minY - host.textView.textContainerOrigin.y, 0)
            let fragment = layout.textLayoutFragment(for: CGPoint(x: 0, y: top))
            let character = fragment.map {
                content.offset(from: content.documentRange.location, to: $0.rangeInElement.location)
            } ?? 0
            return EditorScrollAnchor(
                characterOffset: character,
                horizontalOffset: max(visible.minX, 0)
            )
        }

        /// Puts the anchored line back at the *top* of the viewport.
        ///
        /// Only for changes that genuinely alter the geometry — loading a
        /// document, or changing the type size, which re-heights every fragment.
        /// Restyling preserves the exact origin instead; see
        /// `EditorHostView.applyStyle`.
        private func restoreScroll(anchor: EditorScrollAnchor) {
            host?.restoreScroll(anchor: anchor)
        }

        private func normalizedRanges(_ ranges: [NSRange], utf16Length: Int) -> [NSRange] {
            let normalized = ranges.map { range -> NSRange in
                let location = min(max(range.location, 0), utf16Length)
                let length = min(max(range.length, 0), utf16Length - location)
                return NSRange(location: location, length: length)
            }
            return normalized.isEmpty ? [NSRange(location: 0, length: 0)] : normalized
        }
    }
}
