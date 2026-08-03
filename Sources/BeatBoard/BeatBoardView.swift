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
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(layout.columns.enumerated()), id: \.element.id) { offset, column in
                            if offset > 0 {
                                Divider()
                                    .padding(.vertical, 2)
                            }

                            BoardColumnView(
                                column: column,
                                model: model,
                                selection: $selection,
                                onDrop: { scene, position in
                                    move(scene: scene, into: column.id, at: position)
                                }
                            )
                            .padding(.horizontal, 14)
                            .frame(width: Style.boardColumnWidth)
                        }
                    }
                    .frame(minHeight: max(0, geometry.size.height - 36), alignment: .top)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 18)
                }
                .accessibilityIdentifier("board.columns")
                .background(Color(nsColor: Style.canvasBackground))
            }

            Divider()
            legend
        }
        .background(Color(nsColor: Style.canvasBackground))
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
        .background(Color(nsColor: Style.chromeBackground))
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
        VStack(alignment: .leading, spacing: 12) {
            columnHeader

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
            RoundedRectangle(cornerRadius: Style.cornerRadius)
                .fill(isTargeted ? selectionAccent.opacity(0.08) : .clear)
                .frame(height: column.sceneIndices.isEmpty ? 44 : 28)
                .overlay {
                    RoundedRectangle(cornerRadius: Style.cornerRadius)
                        .strokeBorder(
                            isTargeted
                                ? selectionAccent
                                : Color(nsColor: Style.separator).opacity(0.55),
                            style: StrokeStyle(
                                lineWidth: isTargeted ? 1.25 : 1,
                                dash: [3, 4]
                            )
                        )
                }
                .overlay {
                    if column.sceneIndices.isEmpty {
                        Text("Drop a scene here")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(
                                isTargeted
                                    ? selectionAccent
                                    : Color(nsColor: .tertiaryLabelColor)
                            )
                    }
                }
                .contentShape(Rectangle())
                .dropDestination(for: String.self) { items, _ in
                    guard let dropped = items.first.flatMap(Int.init) else { return false }
                    onDrop(dropped, column.sceneIndices.count)
                    return true
                } isTargeted: { isTargeted = $0 }
        }
        .accessibilityIdentifier("board.column.\(column.id)")
    }

    private var columnHeader: some View {
        VStack(spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(column.title.uppercased())
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.55)
                    .lineLimit(1)
                    .foregroundStyle(column.isUnsequenced ? .secondary : .primary)

                Spacer(minLength: 8)

                Text("\(column.sceneIndices.count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color(nsColor: Style.elevatedBackground).opacity(0.7), in: Capsule())
                    .overlay {
                        Capsule()
                            .strokeBorder(Color(nsColor: Style.separator), lineWidth: 1)
                    }
            }
            .padding(.horizontal, 2)

            Rectangle()
                .fill(Color(nsColor: Style.separator).opacity(0.9))
                .frame(height: 1)
        }
    }

    private var selectionAccent: Color {
        Color(nsColor: .systemBlue)
    }
}

private struct SceneCard: View {
    let scene: ScriptScene
    let status: SceneStatus?
    let length: String?
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SCENE \(scene.number ?? String(scene.index))")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.25)
                .foregroundStyle(Style.paperSecondaryInk.opacity(0.82))

            HStack(alignment: .top, spacing: 9) {
                DragAffordance()
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 6) {
                    Text(scene.heading)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Style.paperInk)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if let synopsis = scene.synopsis {
                        Text(synopsis)
                            .font(.system(size: 11))
                            .foregroundStyle(Style.paperSecondaryInk)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !scene.characters.isEmpty {
                        Text(scene.characters.prefix(4).joined(separator: "  "))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Style.paperSecondaryInk.opacity(0.9))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                if let length {
                    Text(length)
                        .font(.system(size: 10, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(Style.paperSecondaryInk)
                }
                Spacer()
                if let status {
                    Text(status.rawValue.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .foregroundStyle(Style.color(for: status))
                        .background(Style.color(for: status).opacity(0.055), in: Capsule())
                        .overlay {
                            Capsule()
                                .strokeBorder(Style.color(for: status), lineWidth: 1)
                        }
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Style.cornerRadius)
                .fill(Style.paper)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Style.cornerRadius)
                .strokeBorder(
                    isSelected ? selectionAccent : Color.black.opacity(0.14),
                    lineWidth: isSelected ? 2 : 1
                )
        }
        .shadow(
            color: isSelected ? selectionAccent.opacity(0.16) : Color.black.opacity(0.09),
            radius: isSelected ? 5 : 3,
            x: 0,
            y: 2
        )
        .contentShape(RoundedRectangle(cornerRadius: Style.cornerRadius))
        .accessibilityIdentifier("board.card.\(scene.index)")
    }

    private var selectionAccent: Color {
        Color(nsColor: .systemBlue)
    }
}

private struct DragAffordance: View {
    var body: some View {
        VStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 3) {
                    dot
                    dot
                }
            }
        }
        .frame(width: 9)
        .accessibilityHidden(true)
    }

    private var dot: some View {
        Circle()
            .fill(Style.paperSecondaryInk.opacity(0.55))
            .frame(width: 2.5, height: 2.5)
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
