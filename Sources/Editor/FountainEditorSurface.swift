import AppKit
import FountainKit
import Observation
import SwiftUI

/// Where the viewport was, expressed as a character offset so it survives a
/// relayout caused by switching modes or toggling the gutter.
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

public struct EditorSurfaceState: Sendable {
    public var selectedRanges: [NSRange] = [NSRange(location: 0, length: 0)]
    public var scrollAnchor = EditorScrollAnchor()
    public var ownsFocus = false
    /// Caret position for the status bar, one-based.
    public var caretLine = 1
    public var caretColumn = 1
    public var pendingJump: EditorJump?
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
}

/// The Fountain source pane.
///
/// Adapted from `topside/Sources/WorkPane/Editor/TextKitEditorSurface.swift`,
/// which solved the hard parts already: TextKit 2 without falling back to
/// TextKit 1, a viewport-bounded line-number ruler, scroll-anchor preservation,
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
    let mode: EditorMode
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
        mode: EditorMode,
        revision: UInt64,
        replacementToken: UInt64,
        session: FountainEditorSession
    ) {
        self._text = text
        self.script = script
        self.mode = mode
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
        context.coordinator.applyExternalText(text, replacementToken: replacementToken, resetUndo: true)
        context.coordinator.applyMode(mode)
        context.coordinator.scheduleStyling(script: script, mode: mode, revision: revision)
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
        } else if host.textView.string != text, !context.coordinator.isEmittingUserEdit {
            // A binding change with no replacement token is still applied
            // byte-exactly, but it must not be mistaken for a user edit.
            context.coordinator.applyExternalText(
                text,
                replacementToken: replacementToken,
                resetUndo: false
            )
        }

        context.coordinator.applyMode(mode)
        context.coordinator.applyPendingJump(session.state.pendingJump)
        context.coordinator.scheduleStyling(script: script, mode: mode, revision: revision)
    }

    public static func dismantleNSView(_ host: EditorHostView, coordinator: Coordinator) {
        coordinator.stylingTask?.cancel()
        coordinator.removeUndoObservers()
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
        private var appliedMode: EditorMode?
        private var styleKey: StyleKey?
        private var undoObservers: [NSObjectProtocol] = []

        private struct StyleKey: Equatable {
            let revision: UInt64
            let mode: EditorMode
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
        func emitTextIfChanged() {
            guard let textView = host?.textView else { return }
            let source = textView.string
            guard source != parent.text else { return }
            host?.rulerView.invalidateLineIndex()
            isEmittingUserEdit = true
            parent.text = source
            isEmittingUserEdit = false
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

        // MARK: - Applying text and mode

        func applyExternalText(_ source: String, replacementToken: UInt64, resetUndo: Bool) {
            guard let host else { return }
            stylingTask?.cancel()
            styleKey = nil
            let textView = host.textView
            let priorRanges = normalizedRanges(
                parent.session.state.selectedRanges,
                utf16Length: (source as NSString).length
            )
            let priorAnchor = parent.session.state.scrollAnchor

            if textView.string != source {
                textView.string = source
                applyBaseAttributes()
            }
            textView.selectedRanges = priorRanges.map(NSValue.init(range:))
            if resetUndo { textView.undoManager?.removeAllActions() }
            appliedReplacementToken = replacementToken
            host.rulerView.invalidateLineIndex()
            restoreScroll(anchor: priorAnchor)
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

        /// Switching modes preserves the caret and the viewport, because the
        /// document did not change — only its attributes and container geometry.
        func applyMode(_ mode: EditorMode) {
            guard let host, appliedMode != mode else { return }
            let anchor = currentScrollAnchor()
            let ranges = host.textView.selectedRanges
            appliedMode = mode
            styleKey = nil
            host.setShowsLineNumbers(mode == .plainText)
            host.setScriptColumn(mode == .styled ? Style.scriptColumnWidth : nil)
            applyBaseAttributes()
            host.textView.selectedRanges = ranges
            restoreScroll(anchor: anchor)
        }

        private func applyBaseAttributes() {
            guard let textView = host?.textView, let storage = textView.textStorage else { return }
            let styler = ElementStyler(mode: parent.mode)
            let undoManager = textView.undoManager
            undoManager?.disableUndoRegistration()
            storage.setAttributes(
                styler.baseAttributes(),
                range: NSRange(location: 0, length: storage.length)
            )
            undoManager?.enableUndoRegistration()
            textView.backgroundColor = Style.editorBackground
            textView.insertionPointColor = .textColor
        }

        // MARK: - Styling

        func scheduleStyling(script: ParsedScript, mode: EditorMode, revision: UInt64) {
            let key = StyleKey(revision: revision, mode: mode, source: script.source)
            guard key != styleKey else { return }
            styleKey = key
            stylingTask?.cancel()
            guard !script.source.isEmpty else { return }

            // Styling runs off the main actor and is applied only if the text
            // view still holds the exact source it was computed from.
            stylingTask = Task { [weak self] in
                let runs = await Task.detached(priority: .userInitiated) {
                    ElementStyler(mode: mode).runs(for: script)
                }.value
                guard !Task.isCancelled else { return }
                self?.applyRuns(runs, key: key)
            }
        }

        private func applyRuns(_ runs: [ElementStyler.Run], key: StyleKey) {
            guard key == styleKey,
                  let textView = host?.textView,
                  textView.string == key.source,
                  let storage = textView.textStorage
            else { return }

            let selectedRanges = textView.selectedRanges
            let anchor = currentScrollAnchor()
            let undoManager = textView.undoManager
            undoManager?.disableUndoRegistration()
            defer { undoManager?.enableUndoRegistration() }

            let styler = ElementStyler(mode: key.mode)
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes(styler.baseAttributes(), range: full)
            for run in runs where NSMaxRange(run.range) <= storage.length {
                storage.addAttributes(run.attributes, range: run.range)
            }
            storage.endEditing()

            textView.selectedRanges = selectedRanges
            restoreScroll(anchor: anchor)
        }

        // MARK: - Viewport and caret

        private func captureState() {
            guard let textView = host?.textView else { return }
            let ranges = textView.selectedRanges.map(\.rangeValue)
            parent.session.state.selectedRanges = ranges
            parent.session.state.scrollAnchor = currentScrollAnchor()
            parent.session.state.ownsFocus = textView.window?.firstResponder === textView
            if let caret = ranges.first?.location {
                let index = LineIndex(source: textView.string)
                let line = index.lineNumber(containing: caret)
                parent.session.state.caretLine = line + 1
                parent.session.state.caretColumn = caret - index.lineStarts[line] + 1
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
            // A visible origin left of the document is ruler geometry, not a
            // scroll position: with the gutter shown, minX sits at minus its
            // thickness.
            return EditorScrollAnchor(
                characterOffset: character,
                horizontalOffset: max(visible.minX, 0)
            )
        }

        private func restoreScroll(anchor: EditorScrollAnchor) {
            guard let textView = host?.textView else { return }
            let upperBound = (textView.string as NSString).length
            let location = min(max(anchor.characterOffset, 0), upperBound)
            textView.scrollRangeToVisible(NSRange(location: location, length: 0))
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
