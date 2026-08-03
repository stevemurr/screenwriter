#if DEBUG
import Foundation

/// Counts the derived work the workspace views do, so a test can assert on it.
///
/// A SwiftUI `body` that runs more often than it needs to is invisible: nothing
/// looks wrong on screen, a profile is a flat smear across the framework, and
/// the only symptom is that a long script feels heavier than a short one. These
/// counters make "typing one character rebuilt the outline tree four times" a
/// number a test can fail on.
///
/// Debug only, and deliberately not a signpost — a signpost cannot be asserted
/// on, and a counter costs one increment. Every increment happens on the main
/// actor inside a view body; the counters are `nonisolated(unsafe)` only so the
/// increment cannot trap if a value type is ever constructed off it.
enum RenderCounters {
    /// `OutlineTree.make(from:)` — O(scenes + sections), once per outline build.
    nonisolated(unsafe) static var outlineTreeBuilds = 0
    /// `OutlineSidebar.body` evaluations, so a test can assert that a body
    /// evaluation builds the tree exactly once rather than once per reader.
    nonisolated(unsafe) static var outlineBodies = 0
    /// `BoardLayout(script:)` — O(scenes + sections).
    nonisolated(unsafe) static var boardLayoutBuilds = 0
    /// `ScrollViewProxy.scrollTo` calls the preview makes to follow the caret.
    nonisolated(unsafe) static var previewScrolls = 0
    /// `PagePreview.body` evaluations.
    nonisolated(unsafe) static var previewBodies = 0
    /// `RootView.body` evaluations — the whole workspace tree. This one is the
    /// expensive body: it constructs every pane's inputs, `model.sceneMetrics`
    /// among them. It must not run when only the caret has moved.
    nonisolated(unsafe) static var workspaceBodies = 0
    /// `PreviewPane.body` + `InspectorPane.body` — the two panes that read the
    /// caret. Counted so a test asserting the workspace did *not* rebuild can
    /// also show that the caret move was observed by something, rather than
    /// passing because nothing happened at all.
    nonisolated(unsafe) static var caretFollowerBodies = 0

    static func reset() {
        outlineTreeBuilds = 0
        outlineBodies = 0
        boardLayoutBuilds = 0
        previewScrolls = 0
        previewBodies = 0
        workspaceBodies = 0
        caretFollowerBodies = 0
    }
}
#endif
