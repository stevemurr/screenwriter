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

/// The navigator: a merged act, sequence, and scene hierarchy plus cast.
/// Fountain `#` and `##` sections form the outline; each scene is placed under
/// the deepest section that contains it so sequence membership reads directly.
///
/// Scripts without sections still render as a flat scene list, while outline-
/// only documents retain their section structure.
struct OutlineSidebar: View {
    let script: ParsedScript
    /// Scene lengths in eighths of a page, when pagination has caught up.
    let metrics: [Int: SceneMetric]
    let pageCount: Int
    @Binding var selection: OutlineSelection?
    @State private var filter = ""
    @State private var collapsedSections: Set<Int> = []

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

    /// Everything one body evaluation needs, off a single tree build.
    ///
    /// These were five separate computed properties, and `body` read four of
    /// them — `isEmpty`, `visibleOutlineRows` (twice), and `sectionIDs` for the
    /// `onChange`. Each rebuilt the whole outline from scratch, so every body
    /// evaluation ran `OutlineTree.make` four times and `flatten` twice over all
    /// 95 scenes. Nothing was wrong on screen; it simply did the same work four
    /// times and threw three of the answers away.
    private struct Derived {
        var rows: [OutlineTreeRow] = []
        var sectionIDs: Set<Int> = []
        var characters: [String] = []
        var isEmpty: Bool { rows.isEmpty && characters.isEmpty }
    }

    private func derive() -> Derived {
        let full = OutlineTree.make(from: script)
        let tree = filter.isEmpty
            ? full
            : OutlineTree.filter(full, matchingSceneIndices: Set(filteredScenes.map(\.index)))
        return Derived(
            rows: OutlineTree.flatten(
                tree,
                collapsedSections: filter.isEmpty ? collapsedSections : []
            ),
            sectionIDs: Set(OutlineTree.sectionIDs(in: full)),
            characters: filteredCharacters
        )
    }

    var body: some View {
        #if DEBUG
        RenderCounters.outlineBodies += 1
        #endif
        let derived = derive()
        return VStack(spacing: 0) {
            PaneHeader(title: "SCENES") { EmptyView() }

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                TextField("Filter scenes", text: $filter)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("scenes.filter")
                if !filter.isEmpty {
                    Button {
                        filter = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear the scene filter")
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(Color(nsColor: Style.elevatedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(nsColor: Style.separator).opacity(0.75))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            if derived.isEmpty {
                emptyState
            } else {
                List(selection: $selection) {
                    if !derived.rows.isEmpty, !script.sections.isEmpty {
                        Section("OUTLINE") {
                            outlineRows(derived.rows)
                        }
                    } else if !derived.rows.isEmpty {
                        Section {
                            outlineRows(derived.rows)
                        }
                    }

                    if !derived.characters.isEmpty {
                        Section("CHARACTERS") {
                            ForEach(derived.characters, id: \.self) { name in
                                Label(name, systemImage: "person")
                                    .font(.system(size: 12))
                                    .tag(OutlineSelection.character(name))
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .accessibilityIdentifier("scenes.list")
            }

            Divider()
            HStack {
                Text("\(pageCount) pages")
                Spacer()
                Text("\(script.scenes.count) scenes")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: Style.statusBarHeight)
            .background(Color(nsColor: Style.chromeBackground))
        }
        .background(Color(nsColor: Style.sidebarBackground))
        .onChange(of: derived.sectionIDs) { _, currentIDs in
            collapsedSections.formIntersection(currentIDs)
        }
    }

    @ViewBuilder
    private func outlineRows(_ rows: [OutlineTreeRow]) -> some View {
        ForEach(rows) { row in
            switch row.item.content {
            case .section(let node):
                let isExpanded = !collapsedSections.contains(node.elementIndex)
                    || !filter.isEmpty
                SectionRow(
                    node: node,
                    sceneCount: row.item.sceneCount,
                    hasChildren: filter.isEmpty && !row.item.children.isEmpty,
                    isExpanded: isExpanded,
                    onToggle: { toggle(node.elementIndex) }
                )
                .tag(OutlineSelection.section(node.elementIndex))
                .listRowInsets(rowInsets(depth: row.depth))
                .listRowSeparator(.hidden)

            case .scene(let scene):
                SceneRow(scene: scene, metric: metrics[scene.index])
                    .tag(OutlineSelection.scene(scene.index))
                    .listRowInsets(rowInsets(depth: row.depth))
                    .listRowSeparator(.hidden)
            }
        }
    }

    private func rowInsets(depth: Int) -> EdgeInsets {
        EdgeInsets(
            top: 2,
            leading: 8 + CGFloat(depth) * 14,
            bottom: 2,
            trailing: 8
        )
    }

    private func toggle(_ elementIndex: Int) {
        withAnimation(.easeOut(duration: 0.16)) {
            if collapsedSections.contains(elementIndex) {
                collapsedSections.remove(elementIndex)
            } else {
                collapsedSections.insert(elementIndex)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(
                script.scenes.isEmpty && filter.isEmpty ? "No scenes yet" : "No matches",
                systemImage: "doc.text.magnifyingglass"
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

/// A UI-only tree that merges Fountain sections and their scenes in source
/// order. The parser remains the source of truth; this adapter only decides how
/// that structure reads in the navigator.
struct OutlineTreeItem: Identifiable, Hashable {
    enum ID: Hashable {
        case section(Int)
        case scene(Int)
    }

    enum Content: Hashable {
        case section(SectionNode)
        case scene(ScriptScene)
    }

    let content: Content
    let children: [OutlineTreeItem]
    let sourceOffset: Int

    var id: ID {
        switch content {
        case .section(let node): .section(node.elementIndex)
        case .scene(let scene): .scene(scene.index)
        }
    }

    var sceneCount: Int {
        switch content {
        case .scene: 1
        case .section: children.reduce(0) { $0 + $1.sceneCount }
        }
    }
}

struct OutlineTreeRow: Identifiable, Hashable {
    let item: OutlineTreeItem
    let depth: Int

    var id: OutlineTreeItem.ID { item.id }
}

enum OutlineTree {
    static func make(from script: ParsedScript) -> [OutlineTreeItem] {
        #if DEBUG
        RenderCounters.outlineTreeBuilds += 1
        #endif
        var scenesByOwner: [Int: [ScriptScene]] = [:]
        var unownedScenes: [ScriptScene] = []

        for scene in script.scenes {
            if let owner = deepestSection(containing: scene.range.location, in: script.sections) {
                scenesByOwner[owner.elementIndex, default: []].append(scene)
            } else {
                unownedScenes.append(scene)
            }
        }

        func makeSection(_ node: SectionNode) -> OutlineTreeItem {
            let childSections = node.children.map(makeSection)
            let childScenes = scenesByOwner[node.elementIndex, default: []].map {
                OutlineTreeItem(
                    content: .scene($0),
                    children: [],
                    sourceOffset: $0.range.location
                )
            }
            return OutlineTreeItem(
                content: .section(node),
                children: (childSections + childScenes).sorted { $0.sourceOffset < $1.sourceOffset },
                sourceOffset: node.range.location
            )
        }

        let sections = script.sections.map(makeSection)
        let scenes = unownedScenes.map {
            OutlineTreeItem(
                content: .scene($0),
                children: [],
                sourceOffset: $0.range.location
            )
        }
        return (sections + scenes).sorted { $0.sourceOffset < $1.sourceOffset }
    }

    static func filter(
        _ items: [OutlineTreeItem],
        matchingSceneIndices: Set<Int>
    ) -> [OutlineTreeItem] {
        items.compactMap { item in
            switch item.content {
            case .scene(let scene):
                return matchingSceneIndices.contains(scene.index) ? item : nil
            case .section(let node):
                let children = filter(item.children, matchingSceneIndices: matchingSceneIndices)
                guard !children.isEmpty else { return nil }
                return OutlineTreeItem(
                    content: .section(node),
                    children: children,
                    sourceOffset: item.sourceOffset
                )
            }
        }
    }

    static func flatten(
        _ items: [OutlineTreeItem],
        collapsedSections: Set<Int>,
        depth: Int = 0
    ) -> [OutlineTreeRow] {
        items.flatMap { item in
            var rows = [OutlineTreeRow(item: item, depth: depth)]
            if case .section(let node) = item.content,
               !collapsedSections.contains(node.elementIndex) {
                rows += flatten(
                    item.children,
                    collapsedSections: collapsedSections,
                    depth: depth + 1
                )
            }
            return rows
        }
    }

    static func sectionIDs(in items: [OutlineTreeItem]) -> [Int] {
        items.flatMap { item -> [Int] in
            switch item.content {
            case .scene:
                return []
            case .section(let node):
                return [node.elementIndex] + sectionIDs(in: item.children)
            }
        }
    }

    private static func deepestSection(
        containing sourceOffset: Int,
        in nodes: [SectionNode]
    ) -> SectionNode? {
        for node in nodes where NSLocationInRange(sourceOffset, node.range) {
            return deepestSection(containing: sourceOffset, in: node.children) ?? node
        }
        return nil
    }
}

private struct SectionRow: View {
    let node: SectionNode
    let sceneCount: Int
    let hasChildren: Bool
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if hasChildren {
                Button(action: onToggle) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .frame(width: 10, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .accessibilityLabel(isExpanded ? "Collapse \(node.title)" : "Expand \(node.title)")
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                .accessibilityIdentifier("outline.toggle.\(node.elementIndex)")
            } else {
                Color.clear
                    .frame(width: 10, height: 14)
                    .accessibilityHidden(true)
            }

            Image(systemName: node.depth == 1 ? "square.stack" : "square.grid.2x2")
                .foregroundStyle(.tertiary)
                .font(.system(size: 10))
            Text(node.title)
                .font(.system(size: 12, weight: node.depth == 1 ? .semibold : .regular))
                .lineLimit(1)
            Spacer(minLength: 4)
            if sceneCount > 0 {
                Text("\(sceneCount)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 1)
    }
}

private struct SceneRow: View {
    let scene: ScriptScene
    let metric: SceneMetric?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(scene.number ?? "\(scene.index)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(minWidth: 18, alignment: .trailing)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(scene.heading)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .lineLimit(2)
                if let synopsis = scene.synopsis {
                    Text(synopsis)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let metric {
                    // Eighths of a page — how a schedule measures a scene.
                    Text(metric.lengthDescription)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}
