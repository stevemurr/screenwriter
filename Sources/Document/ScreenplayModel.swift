import Foundation
import FountainKit
import Observation

/// The live state of one open screenplay.
///
/// Reference type, held by `ScreenplayDocument`. A value-typed `FileDocument`
/// would copy this string and its parse tree on every keystroke; at 91 KB —
/// the largest script in the reference library — that is not a trade worth
/// making.
@MainActor
@Observable
public final class ScreenplayModel {
    /// The source of truth. Everything else is derived.
    public var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            scheduleReparse()
        }
    }

    private var parseTask: Task<Void, Never>?

    /// How long typing must pause before a reparse runs. Long enough to coalesce
    /// a burst of keystrokes, short enough that the outline and preview still
    /// feel attached to the text.
    private static let debounce = Duration.milliseconds(120)

    public private(set) var script: ParsedScript = .empty
    /// Non-blocking advice about the document. Computed alongside the parse and
    /// off the same actor, because the two always have to agree about ranges.
    public private(set) var diagnostics: [Diagnostic] = []
    /// The script laid out into US-Letter pages. Same engine that drives export,
    /// so the preview predicts the PDF rather than approximating it.
    public private(set) var paginated: PaginatedScript?
    public var printSettings = PrintSettings.highland
    public var previewShowsPages = true
    public var showsDiagnostics = false
    /// Bumped on every reparse so the editor surface knows the styling is stale.
    public private(set) var revision: UInt64 = 0
    /// Bumped only when the text is replaced from outside — a file load or a
    /// revert — never by a user edit.
    public private(set) var replacementToken: UInt64 = 0

    public var mode: EditorMode = .plainText
    public var workspace: WorkspaceMode = .write
    public var showsPreview = true
    public var showsOutline = true
    public var showsInspector = false

    // MARK: - Production metadata

    /// Sidecar data: status, shooting days, cast, locations, production notes.
    /// Fountain has nowhere to record any of it.
    public private(set) var metadata = ScreenplayMetadata()
    /// How the stored records map onto the scenes of the current parse.
    /// Recomputed with every parse, because scenes move.
    public private(set) var resolution: MetadataResolution?
    /// Set when metadata changes; cleared once written beside the document.
    public private(set) var metadataNeedsSaving = false

    /// The record for a scene, if one has been resolved onto it.
    public func sceneMetadata(forSceneAt index: Int) -> SceneMetadata? {
        guard let match = resolution?.match(forSceneAt: index) else { return nil }
        return metadata.scenes.first { $0.id == match.recordID }
    }

    /// How confidently a scene's record was matched — an inexact match is worth
    /// showing differently rather than presenting as fact.
    public func matchTier(forSceneAt index: Int) -> MatchTier? {
        resolution?.match(forSceneAt: index)?.tier
    }

    /// Edits a scene's record, creating one anchored to the current scene if
    /// this is the first thing recorded about it.
    public func updateSceneMetadata(
        forSceneAt index: Int,
        _ mutate: (inout SceneMetadata) -> Void
    ) {
        guard let scene = script.scenes.first(where: { $0.index == index }) else { return }

        if let existing = sceneMetadata(forSceneAt: index),
           let position = metadata.scenes.firstIndex(where: { $0.id == existing.id }) {
            mutate(&metadata.scenes[position])
            // Re-anchor to where the scene is now, so the next resolution starts
            // from the truth rather than from where it used to be.
            metadata.scenes[position].anchor = anchor(for: scene)
        } else {
            var record = SceneMetadata(anchor: anchor(for: scene))
            mutate(&record)
            metadata.scenes.append(record)
        }
        metadataNeedsSaving = true
        resolve()
    }

    private func anchor(for scene: ScriptScene) -> SceneAnchor {
        SceneIdentity.anchors(for: script)
            .first { $0.orderIndex == scene.index - 1 }
            ?? SceneAnchor(
                sceneNumber: scene.number,
                heading: scene.heading,
                orderIndex: scene.index - 1
            )
    }

    private func resolve() {
        resolution = SceneIdentityResolver.resolve(metadata, against: script)
    }

    public func loadMetadata(for documentURL: URL?) {
        guard let documentURL else {
            metadata = ScreenplayMetadata()
            resolve()
            return
        }
        do {
            metadata = try MetadataStore.load(for: documentURL)
        } catch {
            // A damaged sidecar must not block opening the screenplay. The store
            // preserves the bad file rather than overwriting it.
            Log.document.error("Metadata sidecar unreadable: \(String(describing: error))")
            metadata = ScreenplayMetadata()
        }
        metadataNeedsSaving = false
        resolve()
    }

    public func saveMetadata(for documentURL: URL) throws {
        // Nothing recorded and nothing to clean up: do not litter the folder
        // with an empty sidecar beside every script.
        guard !metadata.scenes.isEmpty || metadataNeedsSaving else { return }
        try MetadataStore.save(metadata, for: documentURL)
        metadataNeedsSaving = false
    }

    /// The payload filename to write back under, so a bundle that arrived as
    /// `text.md` is not silently renamed.
    public var textFileName: String = TextBundle.defaultTextFileName
    /// Sidecar files from an opened bundle, preserved untouched on write.
    public var bundleExtras: [String: Data] = [:]
    public var bundleInfoData: Data?

    public init() {}

    /// Installs text that came from disk rather than from the user.
    ///
    /// Parses synchronously: a document must open with its outline already
    /// populated, and the cost is paid once rather than per keystroke.
    public func load(_ source: String) {
        text = source
        parseTask?.cancel()
        apply(Self.analyse(source, settings: printSettings), for: source)
        replacementToken &+= 1
    }

    /// Reparses off the main actor after typing pauses.
    ///
    /// Measured at ~15ms for the largest script in the reference library
    /// (91 KB), which is close enough to a 60Hz frame that doing it inline on
    /// every keystroke would drop frames. It is therefore debounced *and* run
    /// off the main actor — the editor surface already tolerates a parse result
    /// arriving a moment after the text, because it re-checks that the text view
    /// still holds the source a result was computed from before applying it.
    private func scheduleReparse() {
        parseTask?.cancel()
        let source = text
        let settings = printSettings
        parseTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            let analysis = await Task.detached(priority: .userInitiated) {
                ScreenplayModel.analyse(source, settings: settings)
            }.value
            guard !Task.isCancelled else { return }
            self?.apply(analysis, for: source)
        }
    }

    /// Everything derived from one snapshot of the text, computed together so
    /// the three can never disagree about ranges.
    private struct Analysis: Sendable {
        var script: ParsedScript
        var diagnostics: [Diagnostic]
        var paginated: PaginatedScript
        var wordCount: Int
    }

    /// Nonisolated so it can run on a detached task: this is the expensive work,
    /// and none of it touches the main actor.
    private nonisolated static func analyse(_ source: String, settings: PrintSettings) -> Analysis {
        let script = ScriptParser.parse(source)
        return Analysis(
            script: script,
            diagnostics: Linter.lint(script),
            paginated: Paginator.paginate(script, settings: settings),
            // Counted here rather than read from `script` on demand. See
            // `wordCount` below.
            wordCount: script.wordCount
        )
    }

    private func apply(_ analysis: Analysis, for source: String) {
        // Discard a result the document has already moved past.
        //
        // This only works because the editor hands over a *snapshot*: while the
        // surface was emitting `textView.string` directly, both sides of this
        // comparison aliased the same live storage and it could never fail. See
        // `EditorText.snapshot(of:)`.
        guard text == source else { return }
        script = analysis.script
        diagnostics = analysis.diagnostics
        paginated = analysis.paginated
        wordCount = analysis.wordCount
        resolve()
        revision &+= 1
    }

    public var warningCount: Int { diagnostics.count { $0.severity == .warning } }
    public var suggestionCount: Int { diagnostics.count { $0.severity == .suggestion } }

    /// Applies a diagnostic's suggested fix.
    ///
    /// Re-lints synchronously first: the fix is a range into a specific parse,
    /// and applying it against a document that has moved on would corrupt text
    /// rather than repair it.
    public func applyFix(_ diagnostic: Diagnostic) {
        reparseNow()
        guard let current = diagnostics.first(where: { $0.id == diagnostic.id }),
              current.isFixable
        else { return }
        text = current.applied(to: text)
        reparseNow()
    }

    /// Forces any pending reparse to complete now. For tests and for anything
    /// that must act on a current parse, such as export.
    public func reparseNow() {
        parseTask?.cancel()
        apply(Self.analyse(text, settings: printSettings), for: text)
    }

    // MARK: - Derived, for the status bar and sidebar

    /// Body pages, excluding the title page — what a writer means by "how long
    /// is it".
    public var pageCount: Int { paginated?.bodyPageCount ?? 0 }

    /// How long a scene runs, in eighths of a page.
    public func metric(forSceneAt index: Int) -> SceneMetric? {
        paginated?.scenes.first { $0.sceneIndex == index }
    }

    public var sceneCount: Int { script.scenes.count }
    public var characterCount: Int { script.characters.count }

    /// Stored, not `script.wordCount`.
    ///
    /// `ParsedScript.wordCount` is computed, and the status bar reads it from
    /// `StatusBar.body` — a body that re-runs on every keystroke, because the
    /// caret readout beside it changes. So a value that can only change once
    /// per debounced reparse was being recomputed at typing rate, on the main
    /// actor.
    ///
    /// It cost **20.3ms** when this was written. Two later fixes took that to
    /// **0.23ms**: `LineIndex` stopped producing bridged `NSString`s, which
    /// alone accounted for 18ms of it, and then `ParsedScript.wordCount` became
    /// a UTF-8 scan.
    ///
    /// Caching a 0.23ms value is a much weaker claim than caching a 20ms one,
    /// and it is kept on its merits rather than by inertia: the count cannot
    /// change between reparses, so recomputing it per keystroke is work with a
    /// provably identical answer, and `analyse` is already assembling the
    /// parse, the lint and the pagination on a detached task with nowhere
    /// cheaper to put it. It costs one `Int` and buys back 3% of a frame.
    public private(set) var wordCount: Int = 0
}

extension ScreenplayModel {
    /// Scene lengths keyed by scene index, for the sidebar.
    public var sceneMetrics: [Int: SceneMetric] {
        Dictionary(uniqueKeysWithValues: (paginated?.scenes ?? []).map { ($0.sceneIndex, $0) })
    }
}

/// The workspace layouts from the mockups.
///
/// The three mockups drew three different segmented controls, conflating two
/// ideas: which tools are on screen, and which panes are open. Only the first is
/// a mode. The sidebar, preview, and inspector stay independent toggles.
public enum WorkspaceMode: String, CaseIterable, Sendable {
    /// Scenes, source, preview — the writing layout.
    case write
    /// The beat board: sequence columns of draggable scene cards.
    case board
    /// Adds the production inspector to the writing layout.
    case production

    public var title: String {
        switch self {
        case .write: return "Write"
        case .board: return "Board"
        case .production: return "Production"
        }
    }
}

extension ScreenplayModel {
    /// Applies a scene move as one undoable step.
    ///
    /// Registered against the document's undo manager rather than the text
    /// view's, because a drag happens on the board where the text view is not
    /// even on screen. One registration means ⌘Z puts both the text and the
    /// board back in a single press, which is what the plan called for.
    public func apply(
        _ edit: SceneReorder.Edit,
        undoManager: UndoManager?,
        actionName: String = "Move Scene"
    ) {
        let before = text
        let after = SceneReorder.apply(edit, to: before)
        guard after != before else { return }

        undoManager?.registerUndo(withTarget: self) { model in
            model.replaceText(before, undoManager: undoManager, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
        text = after
        // The board reads scenes and metadata straight after a drop, so the
        // parse cannot be left to the debounce here.
        reparseNow()
    }

    private func replaceText(_ value: String, undoManager: UndoManager?, actionName: String) {
        let before = text
        undoManager?.registerUndo(withTarget: self) { model in
            model.replaceText(before, undoManager: undoManager, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
        text = value
        reparseNow()
    }
}
