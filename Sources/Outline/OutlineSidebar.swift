import FountainKit
import SwiftUI

/// What the sidebar can select. Everything resolves to a source offset, which
/// is what actually moves the caret.
enum OutlineSelection: Hashable {
    case scene(Int)
    /// Identified by element index, which is stable within one parse.
    case section(Int)
    case character(String)

    /// Where the caret should land for this selection.
    ///
    /// Returns nil when the selection refers to something the current parse no
    /// longer contains — the sidebar can briefly hold a stale selection while a
    /// debounced reparse is in flight.
    func sourceOffset(in script: ParsedScript) -> Int? {
        switch self {
        case .scene(let index):
            return script.scenes.first { $0.index == index }?.range.location
        case .section(let elementIndex):
            guard script.elements.indices.contains(elementIndex),
                  script.elements[elementIndex].kind == .section
            else { return nil }
            return script.elements[elementIndex].range.location
        case .character(let name):
            // Jump to where the character first speaks.
            return script.elements.first {
                $0.kind == .character && ScriptParser.characterName(from: $0.text) == name
            }?.range.location
        }
    }
}

/// The navigator: outline hierarchy, scenes, and cast.
///
/// The mockups show two different sidebars — a flat scene list, and a tree of
/// Acts over Sequences. They are the same data: Fountain `#` and `##` sections
/// *are* the act/sequence structure, and the reference corpus already uses them
/// that way (`# Act One` over `## Beat 1: Mountain Valley Establishing Shots`).
/// So both appear here, in one list.
///
/// Some scripts in the library are *entirely* sections with no scene headings,
/// and others are entirely scenes with no sections. Each section of this list
/// hides itself when empty rather than showing a blank header.
struct OutlineSidebar: View {
    let script: ParsedScript
    @Binding var selection: OutlineSelection?
    @State private var filter = ""

    private var filteredScenes: [ScriptScene] {
        guard !filter.isEmpty else { return script.scenes }
        return script.scenes.filter {
            $0.heading.localizedCaseInsensitiveContains(filter)
                || ($0.synopsis?.localizedCaseInsensitiveContains(filter) ?? false)
        }
    }

    private var filteredCharacters: [String] {
        guard !filter.isEmpty else { return script.characters }
        return script.characters.filter { $0.localizedCaseInsensitiveContains(filter) }
    }

    private var isEmpty: Bool {
        filteredScenes.isEmpty && filteredCharacters.isEmpty
            && (script.sections.isEmpty || !filter.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "SCENES") { EmptyView() }

            TextField("Filter scenes", text: $filter)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .accessibilityIdentifier("scenes.filter")

            if isEmpty {
                emptyState
            } else {
                List(selection: $selection) {
                    // Filtering is a scene-and-cast search; showing a pruned
                    // tree alongside it would misrepresent the structure.
                    if !script.sections.isEmpty, filter.isEmpty {
                        Section("OUTLINE") {
                            OutlineGroup(script.sections, children: \.branch) { node in
                                SectionRow(node: node)
                                    .tag(OutlineSelection.section(node.elementIndex))
                            }
                        }
                    }

                    if !filteredScenes.isEmpty {
                        Section("SCENES") {
                            ForEach(filteredScenes) { scene in
                                SceneRow(scene: scene)
                                    .tag(OutlineSelection.scene(scene.index))
                            }
                        }
                    }

                    if !filteredCharacters.isEmpty {
                        Section("CHARACTERS") {
                            ForEach(filteredCharacters, id: \.self) { name in
                                Label(name, systemImage: "person")
                                    .font(.system(size: 12))
                                    .tag(OutlineSelection.character(name))
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .accessibilityIdentifier("scenes.list")
            }

            Divider()
            HStack {
                Text("\(script.scenes.count) scenes")
                Spacer()
                Text("\(script.characters.count) characters")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: Style.statusBarHeight)
        }
        .background(Color(nsColor: Style.paneBackground))
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(
                script.scenes.isEmpty && filter.isEmpty ? "No scenes yet" : "No matches",
                systemImage: "film"
            )
        } description: {
            Text(
                script.scenes.isEmpty && filter.isEmpty
                    ? "Type a slugline like INT. KITCHEN - DAY to start one."
                    : "Nothing matches “\(filter)”."
            )
        }
        .controlSize(.small)
        .frame(maxHeight: .infinity)
    }
}

private extension SectionNode {
    /// `OutlineGroup` uses a nil children collection to mean "leaf", so an empty
    /// array would render a pointless disclosure triangle on every bottom-level
    /// section.
    var branch: [SectionNode]? { children.isEmpty ? nil : children }
}

private struct SectionRow: View {
    let node: SectionNode

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: node.depth == 1 ? "square.stack" : "square.grid.2x2")
                .foregroundStyle(.tertiary)
                .font(.system(size: 10))
            Text(node.title)
                .font(.system(size: 12, weight: node.depth == 1 ? .semibold : .regular))
                .lineLimit(1)
            Spacer(minLength: 4)
            if !node.sceneIndices.isEmpty {
                Text("\(node.sceneIndices.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 1)
    }
}

private struct SceneRow: View {
    let scene: ScriptScene

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(scene.number ?? "\(scene.index)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(minWidth: 20, alignment: .trailing)

            VStack(alignment: .leading, spacing: 3) {
                Text(scene.heading)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                if let synopsis = scene.synopsis {
                    Text(synopsis)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 3)
    }
}
