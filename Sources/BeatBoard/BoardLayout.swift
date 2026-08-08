import FountainKit
import Foundation

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
        /// Source offset meaning "after everything in this column".
        ///
        /// The section's own end, which is where the next section's heading
        /// begins — *not* the first scene of the next column. Those are one
        /// heading apart and the difference is the whole bug: inserting before
        /// the next column's first scene puts the card after that column's
        /// heading, so dropping at the bottom of Arrival filed the scene under
        /// The Test.
        var endOffset: Int
        var isUnsequenced: Bool { id == -1 }
    }

    /// Where a drop resolves to in the source.
    enum Drop: Equatable {
        /// Insert immediately before this scene.
        case before(scene: Int)
        /// Insert at this source offset — the end of a column.
        case offset(Int)
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
        #if DEBUG
        RenderCounters.boardLayoutBuilds += 1
        #endif
        var flat: [SectionNode] = []
        func walk(_ nodes: [SectionNode]) {
            for node in nodes {
                flat.append(node)
                walk(node.children)
            }
        }
        walk(script.sections)

        // Which level to draw is decided by the sections that hold scenes; which
        // sections to draw at that level is *all* of them. An empty sequence is
        // a column you are about to fill — that is what a beat board is for —
        // and it used to be dropped from the layout entirely, so the board could
        // never be planned on, only rearranged. The "Drop a scene here"
        // placeholder was unreachable.
        let populated = flat.filter { !$0.sceneIndices.isEmpty }
        let depth = Dictionary(grouping: populated, by: \.depth).keys.max()
        let level = depth.map { level in flat.filter { $0.depth == level } } ?? []

        var columns = level
            .sorted { $0.elementIndex < $1.elementIndex }
            .map {
                Column(
                    id: $0.elementIndex,
                    title: $0.title,
                    sceneIndices: $0.sceneIndices,
                    endOffset: NSMaxRange($0.range)
                )
            }

        // Anything the sections do not account for still has to be reachable.
        let claimed = Set(columns.flatMap(\.sceneIndices))
        let loose = script.scenes.map(\.index).filter { !claimed.contains($0) }
        if !loose.isEmpty || columns.isEmpty {
            // Unsequenced scenes are the ones before the first section — a cold
            // open above `# Act One` — so "after everything here" is the moment
            // before that first heading. With no sections at all, it is the end
            // of the document.
            let end = script.sections.first?.range.location
                ?? (script.source as NSString).length
            columns.insert(
                Column(
                    id: -1,
                    title: columns.isEmpty ? "All Scenes" : "Unsequenced",
                    sceneIndices: loose,
                    endOffset: end
                ),
                at: 0
            )
        }
        self.columns = columns
    }

    /// Where a card dropped on `position` in `columnID` should land.
    ///
    /// `position` is the index of the card it was dropped *on*, or the column's
    /// card count for the strip beneath them all.
    ///
    /// ## Dragging downward inserts *after* the card you dropped on
    /// Everywhere else, a drop means "put it before this one". Within one
    /// column that reads wrong in one direction: dragging the first card onto
    /// the second and inserting it before the second leaves it exactly where it
    /// started, so the card springs back and the board looks broken. Pulling a
    /// card *down* onto another means past it; pushing one *up* means before it.
    /// That is what every list with drag reordering does, and the asymmetry is
    /// only visible from the direction of travel — which is why it lives here,
    /// where a test can see it, rather than in a gesture handler.
    func drop(scene: Int, into columnID: Int, at position: Int) -> Drop? {
        guard let column = columns.first(where: { $0.id == columnID }) else { return nil }

        var target = position
        if let current = self.position(of: scene),
           current.columnID == columnID,
           current.position < position {
            target = position + 1
        }

        guard target < column.sceneIndices.count else { return .offset(column.endOffset) }
        let before = column.sceneIndices[target]
        // Dropping a card onto itself.
        guard before != scene else { return nil }
        return .before(scene: before)
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
