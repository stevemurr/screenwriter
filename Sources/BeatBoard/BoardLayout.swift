import FountainKit

/// Arranges a script's scenes into the board's columns, and works out what a
/// drop means.
///
/// Kept apart from the view so the part that can be wrong — where a dropped card
/// actually lands in the source — is unit-testable without a drag.
struct BoardLayout {
    struct Column: Identifiable, Hashable {
        /// The section's element index, or -1 for scenes under no section.
        var id: Int
        var title: String
        var sceneIndices: [Int]
        var isUnsequenced: Bool { id == -1 }
    }

    let columns: [Column]

    /// Columns come from the deepest section level that actually holds scenes.
    ///
    /// Fountain's `##` subsections *are* the sequences the mockup draws as
    /// columns — the reference corpus writes `# Act One` over `## Beat 1: …`.
    /// A script with only `#` sections uses those; a script with none gets a
    /// single column, because a board with no columns would be useless and the
    /// library contains scripts of every shape.
    init(script: ParsedScript) {
        var flat: [SectionNode] = []
        func walk(_ nodes: [SectionNode]) {
            for node in nodes {
                flat.append(node)
                walk(node.children)
            }
        }
        walk(script.sections)

        let deepest = flat.filter { !$0.sceneIndices.isEmpty }
        let byDepth = Dictionary(grouping: deepest, by: \.depth)
        let level = byDepth.keys.max().map { byDepth[$0] ?? [] } ?? []

        var columns = level
            .sorted { $0.elementIndex < $1.elementIndex }
            .map { Column(id: $0.elementIndex, title: $0.title, sceneIndices: $0.sceneIndices) }

        // Anything the sections do not account for still has to be reachable.
        let claimed = Set(columns.flatMap(\.sceneIndices))
        let loose = script.scenes.map(\.index).filter { !claimed.contains($0) }
        if !loose.isEmpty || columns.isEmpty {
            columns.insert(
                Column(id: -1, title: columns.isEmpty ? "All Scenes" : "Unsequenced",
                       sceneIndices: loose),
                at: 0
            )
        }
        self.columns = columns
    }

    /// The scene a dropped card should be inserted *before*, or nil to place it
    /// at the end of the script.
    ///
    /// Dropping past the last card in a column means "after everything in this
    /// column", which in document order is immediately before the first scene of
    /// the next column that has any — not the end of the document, unless this
    /// is the last populated column.
    func destination(dropInto columnID: Int, at position: Int) -> Int? {
        guard let columnIndex = columns.firstIndex(where: { $0.id == columnID }) else { return nil }
        let column = columns[columnIndex]

        if position < column.sceneIndices.count {
            return column.sceneIndices[position]
        }
        for next in columns[(columnIndex + 1)...] where !next.sceneIndices.isEmpty {
            return next.sceneIndices[0]
        }
        return nil
    }

    /// Where a card sits now, so a drop onto its own position can be ignored.
    func position(of sceneIndex: Int) -> (columnID: Int, position: Int)? {
        for column in columns {
            if let position = column.sceneIndices.firstIndex(of: sceneIndex) {
                return (column.id, position)
            }
        }
        return nil
    }
}
