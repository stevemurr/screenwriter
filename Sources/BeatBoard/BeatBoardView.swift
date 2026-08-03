import FountainKit
import SwiftUI
import UniformTypeIdentifiers

/// The beat board: sequence columns of draggable scene cards.
///
/// A drop rewrites the Fountain source. The document is the model, not a
/// projection of one, so there is no board state to keep in sync — the board is
/// a view of the script, and moving a card moves text.
struct BeatBoardView: View {
    @Bindable var model: ScreenplayModel
    let undoManager: UndoManager?
    @Binding var selection: OutlineSelection?

    private var layout: BoardLayout { BoardLayout(script: model.script) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(layout.columns) { column in
                        BoardColumnView(
                            column: column,
                            model: model,
                            selection: $selection,
                            onDrop: { scene, position in
                                move(scene: scene, into: column.id, at: position)
                            }
                        )
                        .frame(width: 260)
                    }
                }
                .padding(16)
            }
            .accessibilityIdentifier("board.columns")

            Divider()
            legend
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach(SceneStatus.allCases, id: \.self) { status in
                HStack(spacing: 5) {
                    Circle().fill(Style.color(for: status)).frame(width: 7, height: 7)
                    Text(status.rawValue.uppercased())
                }
            }
            Spacer()
            Text("\(model.script.scenes.count) scenes")
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: Style.statusBarHeight)
        .background(Color(nsColor: Style.paneBackground))
    }

    private func move(scene: Int, into columnID: Int, at position: Int) {
        let layout = self.layout
        // A card dropped back where it already is must not dirty the document.
        if let current = layout.position(of: scene),
           current.columnID == columnID,
           current.position == position || current.position == position - 1 {
            return
        }
        let target = layout.destination(dropInto: columnID, at: position)
        guard target != scene,
              let edit = SceneReorder.move(sceneAt: scene, before: target, in: model.script)
        else { return }

        model.apply(edit, undoManager: undoManager)
        selection = .scene(model.script.scene(at: edit.resultingOffset)?.index ?? scene)
    }
}

private struct BoardColumnView: View {
    let column: BoardLayout.Column
    @Bindable var model: ScreenplayModel
    @Binding var selection: OutlineSelection?
    let onDrop: (Int, Int) -> Void

    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(column.title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.5)
                    .lineLimit(1)
                Spacer()
                Text("\(column.sceneIndices.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(column.isUnsequenced ? .secondary : .primary)

            ForEach(Array(column.sceneIndices.enumerated()), id: \.element) { position, index in
                if let scene = model.script.scenes.first(where: { $0.index == index }) {
                    SceneCard(
                        scene: scene,
                        status: model.sceneMetadata(forSceneAt: index)?.status,
                        length: model.metric(forSceneAt: index)?.lengthDescription,
                        isSelected: selection == .scene(index)
                    )
                    .onTapGesture { selection = .scene(index) }
                    .draggable(String(index))
                    .dropDestination(for: String.self) { items, _ in
                        guard let dropped = items.first.flatMap(Int.init) else { return false }
                        onDrop(dropped, position)
                        return true
                    }
                }
            }

            // The tail of the column accepts a drop meaning "after everything
            // here", which is what makes an empty column reachable at all.
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color(nsColor: Style.separator),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
                .frame(height: 40)
                .overlay {
                    Text(column.sceneIndices.isEmpty ? "Drop a scene here" : "")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .dropDestination(for: String.self) { items, _ in
                    guard let dropped = items.first.flatMap(Int.init) else { return false }
                    onDrop(dropped, column.sceneIndices.count)
                    return true
                } isTargeted: { isTargeted = $0 }
        }
        .accessibilityIdentifier("board.column.\(column.id)")
    }
}

private struct SceneCard: View {
    let scene: ScriptScene
    let status: SceneStatus?
    let length: String?
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SCENE \(scene.number ?? String(scene.index))")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)

            Text(scene.heading)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if let synopsis = scene.synopsis {
                Text(synopsis)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !scene.characters.isEmpty {
                Text(scene.characters.prefix(4).joined(separator: "  "))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            HStack {
                if let length {
                    Text(length)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let status {
                    Text(status.rawValue.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Style.color(for: status).opacity(0.18))
                        .foregroundStyle(Style.color(for: status))
                        .clipShape(Capsule())
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    isSelected ? Color.accentColor : Color(nsColor: Style.separator),
                    lineWidth: isSelected ? 2 : 1
                )
        }
        .accessibilityIdentifier("board.card.\(scene.index)")
    }
}

extension Style {
    /// Status colours, matching the legend in the mockup.
    static func color(for status: SceneStatus) -> Color {
        switch status {
        case .draft: return .orange
        case .revised: return .blue
        case .outline: return .purple
        case .locked: return .green
        default: return .secondary
        }
    }
}
