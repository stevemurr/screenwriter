import FountainKit
import SwiftUI

/// The scenes list from the mockups: number, heading, and the `= ` synopsis as
/// a subtitle.
///
/// Some scripts in the reference library are *entirely* `#` sections with no
/// scene headings at all, so an empty list is a normal state and says so rather
/// than looking broken.
struct ScenesSidebar: View {
    let script: ParsedScript
    @Binding var selection: Int?
    @State private var filter = ""

    private var scenes: [ScriptScene] {
        guard !filter.isEmpty else { return script.scenes }
        return script.scenes.filter {
            $0.heading.localizedCaseInsensitiveContains(filter)
                || ($0.synopsis?.localizedCaseInsensitiveContains(filter) ?? false)
        }
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

            if scenes.isEmpty {
                ContentUnavailableView {
                    Label(
                        script.scenes.isEmpty ? "No scenes yet" : "No matches",
                        systemImage: "film"
                    )
                } description: {
                    Text(
                        script.scenes.isEmpty
                            ? "Type a slugline like INT. KITCHEN - DAY to start one."
                            : "No scene matches “\(filter)”."
                    )
                }
                .controlSize(.small)
            } else {
                List(scenes, selection: $selection) { scene in
                    SceneRow(scene: scene).tag(scene.index)
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
