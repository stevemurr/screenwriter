import FountainKit
import SwiftUI

/// The Production column: metadata, cast, location, and notes for the selected
/// scene.
///
/// None of this is expressible in Fountain, so it lives in a sidecar JSON file
/// beside the script and is re-attached to scenes on every parse. Scenes move,
/// so a record's link to one is a *match*, not a fact — an inexact match is
/// labelled rather than presented as certain.
struct SceneInspector: View {
    @Bindable var model: ScreenplayModel
    let sceneIndex: Int?

    private var scene: ScriptScene? {
        sceneIndex.flatMap { index in model.script.scenes.first { $0.index == index } }
    }

    private var record: SceneMetadata? {
        sceneIndex.flatMap { model.sceneMetadata(forSceneAt: $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "SCENE INSPECTOR") { EmptyView() }

            if let scene {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header(scene)
                        metadataSection(scene)
                        castSection(scene)
                        locationSection
                        notesSection
                    }
                    .padding(14)
                }
            } else {
                ContentUnavailableView(
                    "No scene selected",
                    systemImage: "sidebar.right",
                    description: Text("Pick a scene to record production details.")
                )
                .controlSize(.small)
            }
        }
        .background(Color(nsColor: Style.paneBackground))
        .accessibilityIdentifier("inspector.root")
    }

    // MARK: - Sections

    private func header(_ scene: ScriptScene) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(scene.heading)
                .font(.system(size: 13, weight: .semibold))
                .textCase(.uppercase)
            if let tier = sceneIndex.flatMap({ model.matchTier(forSceneAt: $0) }), !tier.isConfident {
                // Say so rather than presenting a guess as fact.
                Label(
                    tier == .fuzzy
                        ? "Matched by similar heading — check this is the right scene."
                        : "This scene has no saved record.",
                    systemImage: "questionmark.circle"
                )
                .font(.system(size: 10))
                .foregroundStyle(.orange)
            }
        }
    }

    private func metadataSection(_ scene: ScriptScene) -> some View {
        section("METADATA") {
            LabeledContent("Scene number", value: scene.number ?? "—")

            Picker("Status", selection: statusBinding) {
                Text("—").tag(SceneStatus?.none)
                ForEach(SceneStatus.allCases, id: \.self) { status in
                    Text(status.rawValue.capitalized).tag(SceneStatus?.some(status))
                }
            }
            .accessibilityIdentifier("inspector.status")

            LabeledContent("Shooting day") {
                TextField("—", value: shootingDayBinding, format: .number)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
            }

            LabeledContent("Duration") {
                TextField("0:00", text: durationBinding)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                    .accessibilityIdentifier("inspector.duration")
            }
        }
    }

    private func castSection(_ scene: ScriptScene) -> some View {
        section("CAST") {
            if scene.characters.isEmpty {
                Text("Nobody speaks in this scene.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                // Read from the script, not stored: who speaks in a scene is a
                // fact about the text, and duplicating it would let the two
                // disagree.
                ForEach(scene.characters, id: \.self) { name in
                    HStack(spacing: 8) {
                        Image(systemName: "person.circle.fill")
                            .foregroundStyle(.tint)
                        Text(name)
                            .font(.system(size: 12))
                        Spacer()
                        if let order = billingOrder(for: name) {
                            Text("#\(order)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    private var locationSection: some View {
        section("LOCATION") {
            TextField("Location name", text: locationNameBinding)
            Picker("Interior / exterior", selection: interiorExteriorBinding) {
                Text("—").tag(InteriorExterior?.none)
                ForEach(InteriorExterior.allCases, id: \.self) { value in
                    Text(value.rawValue.uppercased()).tag(InteriorExterior?.some(value))
                }
            }
        }
    }

    private var notesSection: some View {
        section("PRODUCTION NOTES") {
            ForEach(record?.notes ?? [], id: \.self) { note in
                Text(note.text)
                    .font(.system(size: 11))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            Button("Add Note") { addNote() }
                .controlSize(.small)
                .accessibilityIdentifier("inspector.addNote")
        }
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)
            content()
        }
    }

    // MARK: - Bindings

    private func edit(_ mutate: @escaping (inout SceneMetadata) -> Void) {
        guard let sceneIndex else { return }
        model.updateSceneMetadata(forSceneAt: sceneIndex, mutate)
    }

    private var statusBinding: Binding<SceneStatus?> {
        Binding(get: { record?.status }, set: { value in edit { $0.status = value } })
    }

    private var shootingDayBinding: Binding<Int?> {
        Binding(get: { record?.shootingDay }, set: { value in edit { $0.shootingDay = value } })
    }

    /// Stored as seconds, shown as `1:45`.
    private var durationBinding: Binding<String> {
        Binding(
            get: {
                guard let seconds = record?.estimatedSeconds else { return "" }
                return String(format: "%d:%02d", seconds / 60, seconds % 60)
            },
            set: { text in
                let parts = text.split(separator: ":").compactMap { Int($0) }
                let seconds: Int?
                switch parts.count {
                case 2: seconds = parts[0] * 60 + parts[1]
                case 1: seconds = parts[0]
                default: seconds = nil
                }
                edit { $0.estimatedSeconds = seconds }
            }
        )
    }

    private var locationNameBinding: Binding<String> {
        Binding(
            get: { record?.location?.name ?? "" },
            set: { name in
                edit { record in
                    if name.isEmpty {
                        record.location = nil
                    } else {
                        var location = record.location ?? SceneLocation(name: name)
                        location.name = name
                        record.location = location
                    }
                }
            }
        )
    }

    private var interiorExteriorBinding: Binding<InteriorExterior?> {
        Binding(
            get: { record?.location?.interiorExterior },
            set: { value in
                edit { record in
                    var location = record.location ?? SceneLocation(name: "")
                    location.interiorExterior = value
                    record.location = location
                }
            }
        )
    }

    private func billingOrder(for name: String) -> Int? {
        record?.cast.first { $0.name == name }?.billingOrder
    }

    private func addNote() {
        edit { $0.notes.append(ProductionNote(text: "New note")) }
    }
}
