import AppKit
import FountainKit
import SwiftUI

/// The document workspace: scenes sidebar · Fountain source · page preview.
///
/// The three mockups use three different segmented controls
/// (`Write|Preview|Production`, `Beat Board|Script|Timeline`,
/// `Outline|Focus|Preview`), which conflate two separate ideas. They are split
/// here: **mode** changes the workspace layout, while the sidebar and preview
/// are independent pane toggles. Board and Production modes land in M8 and M7.
struct RootView: View {
    @Bindable var model: ScreenplayModel
    let document: ScreenplayDocument

    @State private var session = FountainEditorSession()
    @State private var selection: OutlineSelection?
    @State private var isEditingTitlePage = false
    @AppStorage(PrefKey.editorFontSize) private var editorFontSize = EditorTypeSize.default

    var body: some View {
        VStack(spacing: 0) {
            if model.workspace == .board {
                BeatBoardView(
                    model: model,
                    undoManager: document.undoManager,
                    selection: $selection
                )
            } else {
                writingLayout
            }
            Divider()
            StatusBar(model: model, session: session)
        }
        .background(Color(nsColor: Style.editorBackground))
        .toolbar { toolbarContent }
        .sheet(isPresented: $isEditingTitlePage) {
            TitlePageInspector(model: model) { isEditingTitlePage = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showTitlePageInspector)) { _ in
            isEditingTitlePage = true
        }
        .onChange(of: model.text) { _, _ in
            document.noteTextEdited()
        }
        .onChange(of: model.workspace) { _, mode in
            // Production is the writing layout with the inspector open; the
            // inspector stays an independent toggle everywhere else.
            if mode == .production { model.showsInspector = true }
        }
        .onChange(of: selection) { _, target in
            // Selecting in the sidebar moves the caret, which is what makes the
            // list a navigator rather than a read-only outline.
            guard let offset = target?.sourceOffset(in: model.script) else { return }
            session.jump(to: offset)
        }
    }

    private var writingLayout: some View {
        HStack(spacing: 0) {
            if model.showsOutline {
                    OutlineSidebar(
                        script: model.script,
                        metrics: model.sceneMetrics,
                        selection: $selection
                    )
                        .frame(width: 260)
                    Divider()
                }

                editorPane
                    .frame(minWidth: 380)

                if model.showsPreview {
                    Divider()
                    PagePreview(
                        paginated: model.paginated,
                        caretOffset: caretOffset,
                        showsPages: $model.previewShowsPages
                    )
                    .frame(minWidth: 340)
                }

            if model.showsInspector {
                Divider()
                SceneInspector(model: model, sceneIndex: selectedSceneIndex)
                    .frame(width: 300)
            }
        }
    }

    /// The scene the inspector describes: whatever is selected in the sidebar,
    /// falling back to whichever scene the caret sits in.
    private var selectedSceneIndex: Int? {
        if case .scene(let index) = selection { return index }
        return model.script.scene(at: caretOffset)?.index
    }

    private var caretOffset: Int {
        session.state.selectedRanges.first?.location ?? 0
    }

    private var editorPane: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "FOUNTAIN") {
                Picker("", selection: $model.mode) {
                    ForEach(EditorMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityIdentifier("editor.mode")
            }
            FountainEditorSurface(
                text: $model.text,
                script: model.script,
                diagnostics: model.diagnostics,
                mode: model.mode,
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
        ToolbarItem {
            Toggle(isOn: $model.showsPreview) {
                Label("Preview", systemImage: "doc.text.image")
            }
            .help("Show or hide the page preview")
            .accessibilityIdentifier("toggle.preview")
        }
        ToolbarItem {
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

/// The counts along the bottom edge, matching the mockups.
private struct StatusBar: View {
    @Bindable var model: ScreenplayModel
    let session: FountainEditorSession

    var body: some View {
        HStack(spacing: 16) {
            Text("Line \(session.state.caretLine), Column \(session.state.caretColumn)")
                .accessibilityIdentifier("status.caret")
            DiagnosticsSummary(
                warnings: model.warningCount,
                suggestions: model.suggestionCount,
                isExpanded: $model.showsDiagnostics
            )
            Spacer()
            Text("\(model.pageCount) pages")
                .accessibilityIdentifier("status.pages")
            Text("\(model.sceneCount) scenes")
                .accessibilityIdentifier("status.scenes")
            Text("\(model.characterCount) characters")
            Text("\(model.wordCount) words")
                .accessibilityIdentifier("status.words")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: Style.statusBarHeight)
        .background(Color(nsColor: Style.paneBackground))
    }
}
