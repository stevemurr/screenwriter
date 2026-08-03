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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if model.showsOutline {
                    OutlineSidebar(script: model.script, selection: $selection)
                        .frame(width: 260)
                    Divider()
                }

                editorPane
                    .frame(minWidth: 380)

                if model.showsPreview {
                    Divider()
                    ContinuousPreview(script: model.script)
                        .frame(minWidth: 320)
                }
            }
            Divider()
            StatusBar(model: model, session: session)
        }
        .background(Color(nsColor: Style.editorBackground))
        .toolbar { toolbarContent }
        .onChange(of: model.text) { _, _ in
            document.noteTextEdited()
        }
        .onChange(of: selection) { _, target in
            // Selecting in the sidebar moves the caret, which is what makes the
            // list a navigator rather than a read-only outline.
            guard let offset = target?.sourceOffset(in: model.script) else { return }
            session.jump(to: offset)
        }
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
                mode: model.mode,
                revision: model.revision,
                replacementToken: model.replacementToken,
                session: session
            )
            .accessibilityIdentifier("editor.surface")
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
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
    }
}

/// The counts along the bottom edge, matching the mockups.
private struct StatusBar: View {
    let model: ScreenplayModel
    let session: FountainEditorSession

    var body: some View {
        HStack(spacing: 16) {
            Text("Line \(session.state.caretLine), Column \(session.state.caretColumn)")
                .accessibilityIdentifier("status.caret")
            Spacer()
            Text("\(model.sceneCount) scenes")
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
