import AppKit
import FountainKit
import SwiftUI

/// The document workspace: scenes sidebar · Fountain source · page preview.
///
/// The three mockups use three different segmented controls
/// (`Write|Preview|Production`, `Beat Board|Script|Timeline`,
/// `Outline|Focus|Preview`), which conflate two separate ideas. They are split
/// here: **mode** changes the workspace layout, while the sidebar, preview and
/// inspector are independent pane toggles.
struct RootView: View {
    @Bindable var model: ScreenplayModel
    let document: ScreenplayDocument

    @State private var session: FountainEditorSession
    @State private var selection: OutlineSelection?
    @State private var isEditingTitlePage = false
    @AppStorage(PrefKey.editorFontSize) private var editorFontSize = EditorTypeSize.default
    @AppStorage(PrefKey.autoFixEnabled) private var autoFixEnabled = AutoLint.defaultEnabled
    @AppStorage(PrefKey.disabledLintRules) private var disabledLintRules = ""

    /// `session` is injectable so a test can move the caret from outside and
    /// watch what re-renders. Owning it as `@State` is otherwise correct — it is
    /// per-window UI state, not document state — but it also makes the one
    /// invariant worth testing here untestable, because nothing outside can
    /// write to it. The default keeps every production call site unchanged.
    @MainActor
    init(
        model: ScreenplayModel,
        document: ScreenplayDocument,
        session: FountainEditorSession? = nil
    ) {
        self.model = model
        self.document = document
        _session = State(initialValue: session ?? FountainEditorSession())
    }

    /// Deliberately free of any read of `session.state`.
    ///
    /// `FountainEditorSession` is `@Observable` and its whole surface state is
    /// one stored property, so *any* read of `session.state` here — a caret
    /// offset, a line number — subscribes this body to every caret movement.
    /// This body is expensive to run: it constructs the sidebar's inputs, which
    /// includes `model.sceneMetrics` building a 95-entry dictionary. None of
    /// that can change when the caret moves.
    ///
    /// So the two panes that genuinely follow the caret read it themselves, in
    /// their own bodies, and the caret-derived values that used to be computed
    /// here have moved with them. Arrowing through the script now invalidates
    /// `PreviewPane`, `InspectorPane` and `StatusBar` and nothing else. See
    /// `WorkspaceRenderCostTests.testMovingTheCaretDoesNotRebuildTheWorkspace`.
    var body: some View {
        #if DEBUG
        RenderCounters.workspaceBodies += 1
        #endif
        return VStack(spacing: 0) {
            workspaceLayout
            Divider()
            StatusBar(model: model, session: session)
        }
        .background(Color(nsColor: Style.editorBackground))
        .toolbar { toolbarContent }
        .sheet(isPresented: $isEditingTitlePage) {
            TitlePageInspector(model: model) { isEditingTitlePage = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showTitlePageInspector)) { note in
            // Only the document the command was aimed at.
            guard note.object as? ScreenplayModel === model else { return }
            isEditingTitlePage = true
        }
        .onChange(of: model.text) { _, _ in
            document.noteTextEdited()
        }
        .onChange(of: model.workspace) { _, mode in
            if mode == .board {
                // The board mock is a planning workspace: navigator, cards and
                // selected-scene metadata belong together. They remain normal
                // toolbar toggles after the workspace opens.
                model.showsOutline = true
                model.showsInspector = true
                let hasSceneSelection: Bool
                if case .some(.scene(let index)) = selection {
                    hasSceneSelection = model.script.scenes.contains { $0.index == index }
                } else {
                    hasSceneSelection = false
                }
                if !hasSceneSelection, let first = model.script.scenes.first {
                    selection = .scene(first.index)
                }
            }
        }
        .onChange(of: model.revision) { _, _ in
            runAutoFix()
        }
        .onChange(of: selection) { _, target in
            // Selecting in the sidebar moves the caret, which is what makes the
            // list a navigator rather than a read-only outline.
            guard let offset = target?.sourceOffset(in: model.script) else { return }
            session.jump(to: offset)
        }
    }

    /// Applies the enabled auto-fixes once a parse has settled.
    ///
    /// Reading `session.state` here does **not** subscribe this view to the
    /// caret: an `onChange` action runs outside SwiftUI's observation tracking,
    /// which only records reads made while a body is evaluating. That
    /// distinction is the whole reason `RootView.body` can avoid touching
    /// `session.state` while this can — see the note on `body`.
    ///
    /// The loop terminates because the fixes are computed from the diagnostics
    /// of the parse that just landed: applying them changes the text, which
    /// parses again, and that parse no longer reports them. `AutoFixTests`
    /// pins the fixed point.
    private func runAutoFix() {
        guard autoFixEnabled else { return }
        let source = model.text as NSString
        let caret = session.state.selectedRanges.first?.location ?? 0
        // Whole lines: a fix anywhere on the line being written is a fix under
        // the writer's hands.
        let protected = source.lineRange(
            for: NSRange(location: min(max(caret, 0), source.length), length: 0)
        )
        session.apply(
            AutoFix.edits(
                for: model.diagnostics,
                excluding: AutoLint.decode(disabledLintRules),
                protecting: protected
            )
        )
    }

    @ViewBuilder
    private var workspaceLayout: some View {
        if model.workspace == .board {
            boardLayout
        } else {
            writingLayout
        }
    }

    private var boardLayout: some View {
        HStack(spacing: 0) {
            if model.showsOutline {
                OutlineSidebar(
                    script: model.script,
                    metrics: model.sceneMetrics,
                    pageCount: model.pageCount,
                    selection: $selection
                )
                .frame(width: Style.sidebarWidth)
                Divider()
            }

            BeatBoardView(
                model: model,
                undoManager: document.undoManager,
                selection: $selection
            )
            .frame(minWidth: Style.editorMinimumWidth)

            if model.showsInspector {
                Divider()
                InspectorPane(model: model, session: session, selection: selection)
                    .frame(width: Style.inspectorWidth)
            }
        }
    }

    private var writingLayout: some View {
        HStack(spacing: 0) {
            if model.showsOutline {
                OutlineSidebar(
                    script: model.script,
                    metrics: model.sceneMetrics,
                    pageCount: model.pageCount,
                    selection: $selection
                )
                .frame(width: Style.sidebarWidth)
                Divider()
            }

            editorPane
                .frame(minWidth: Style.editorMinimumWidth)

            if model.showsPreview {
                Divider()
                PreviewPane(paginated: model.paginated, session: session)
                .frame(minWidth: Style.previewMinimumWidth)
            }

            if model.showsInspector {
                Divider()
                InspectorPane(model: model, session: session, selection: selection)
                    .frame(width: Style.inspectorWidth)
            }
        }
    }

    private var editorPane: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "FOUNTAIN") { EmptyView() }
            FountainEditorSurface(
                text: $model.text,
                script: model.script,
                diagnostics: model.diagnostics,
                fontSize: CGFloat(EditorTypeSize.resolve(editorFontSize)),
                revision: model.revision,
                replacementToken: model.replacementToken,
                session: session
            )

            if model.showsDiagnostics {
                DiagnosticsPane(
                    diagnostics: model.diagnostics,
                    onSelect: { session.jump(to: $0.range.location) },
                    onFix: { model.applyFix($0) }
                )
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("", selection: $model.workspace) {
                ForEach(WorkspaceMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            // Sized to its content rather than to a number. It was 276pt wide
            // for three options and 184 for two, both of which left the control
            // stretched well past the words in it.
            .fixedSize()
            .accessibilityIdentifier("workspace.mode")
        }
        ToolbarItem(placement: .navigation) {
            Toggle(isOn: $model.showsOutline) {
                Label("Scenes", systemImage: "sidebar.left")
            }
            .help("Show or hide the scenes sidebar")
            .accessibilityIdentifier("toggle.outline")
        }
        ToolbarItemGroup {
            if model.workspace != .board {
                Toggle(isOn: $model.showsPreview) {
                    Label("Preview", systemImage: "doc.text.image")
                }
                .help("Show or hide the page preview")
                .accessibilityIdentifier("toggle.preview")
            }

            Toggle(isOn: $model.showsInspector) {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .help("Show or hide the scene inspector")
            .accessibilityIdentifier("toggle.inspector")
        }
        ToolbarItem {
            Button {
                NSApp.sendAction(#selector(ScreenplayDocument.exportPDF(_:)), to: nil, from: nil)
            } label: {
                Label("Export PDF", systemImage: "square.and.arrow.up")
            }
            .help("Export a PDF of this screenplay")
            .accessibilityIdentifier("toolbar.exportPDF")
        }
        ToolbarItem {
            Button {
                isEditingTitlePage = true
            } label: {
                Label("Title Page", systemImage: "doc.badge.gearshape")
            }
            .help("Edit the title page")
            .accessibilityIdentifier("toolbar.titlepage")
        }
    }
}

/// The preview, resolving the caret's page inside its own body.
///
/// Two separate reductions, and both are needed:
///
/// - Reading `session.state` **here** rather than in `RootView.body` keeps a
///   caret move from invalidating the sidebar, the editor pane and the
///   inspector along with it.
/// - Handing `PagePreview` a *page index* rather than a raw offset keeps the
///   preview itself still while the caret moves within a page. That was the
///   visible bug: the pane snapped to the top of the current page on every
///   keystroke, so the foot of a page could not be read while typing into it.
///   The binary search costs nothing; passing the offset through cost a body
///   evaluation over all 86 pages and an animated scroll.
private struct PreviewPane: View {
    let paginated: PaginatedScript?
    let session: FountainEditorSession

    var body: some View {
        #if DEBUG
        RenderCounters.caretFollowerBodies += 1
        #endif
        return PagePreview(
            paginated: paginated,
            caretPage: paginated?.pageIndex(
                forSourceOffset: session.state.selectedRanges.first?.location ?? 0
            )
        )
    }
}

/// The scene inspector, resolving which scene it describes inside its own body.
///
/// The scene is whatever is selected in the sidebar, falling back to whichever
/// scene the caret sits in — which is why this has to read the caret, and why it
/// reads it here. Moving the caret within one scene leaves `sceneIndex`
/// unchanged, so `SceneInspector` itself does not re-render.
private struct InspectorPane: View {
    @Bindable var model: ScreenplayModel
    let session: FountainEditorSession
    let selection: OutlineSelection?

    var body: some View {
        #if DEBUG
        RenderCounters.caretFollowerBodies += 1
        #endif
        return SceneInspector(model: model, sceneIndex: sceneIndex)
    }

    private var sceneIndex: Int? {
        if case .scene(let index) = selection { return index }
        return model.script.scene(
            at: session.state.selectedRanges.first?.location ?? 0
        )?.index
    }
}

/// The counts along the bottom edge, matching the mockups.
private struct StatusBar: View {
    @Bindable var model: ScreenplayModel
    let session: FountainEditorSession

    var body: some View {
        // The design pass's grouping — dividers, and the editor mode alongside
        // the caret — with the accessibility work kept. Scene and character
        // counts moved to the sidebar footer, which is where the mockups put
        // them and where the UI tests read them.
        HStack(spacing: 12) {
            Text("Line \(session.state.caretLine), Column \(session.state.caretColumn)")
                .accessibilityIdentifier("status.caret")
                .accessibilityLabel("Line \(session.state.caretLine), Column \(session.state.caretColumn)")
            Divider()
                .frame(height: 14)
            DiagnosticsSummary(
                warnings: model.warningCount,
                suggestions: model.suggestionCount,
                isExpanded: $model.showsDiagnostics
            )
            Spacer()
            Text("\(model.pageCount) pages")
                .accessibilityIdentifier("status.pages")
                .accessibilityLabel("\(model.pageCount) pages")
            Divider()
                .frame(height: 14)
            Text("\(model.wordCount) words")
                .accessibilityIdentifier("status.words")
                .accessibilityLabel("\(model.wordCount) words")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: Style.statusBarHeight)
        .background(Color(nsColor: Style.chromeBackground))
    }
}
