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
                    VStack(alignment: .leading, spacing: 12) {
                        header(scene)
                        metadataSection(scene)
                        castSection(scene)
                        locationSection
                        notesSection
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
        .background(Color(nsColor: Style.inspectorBackground))
        .accessibilityIdentifier("inspector.root")
    }

    // MARK: - Sections

    private func header(_ scene: ScriptScene) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Text("SCENE \(scene.number ?? String(scene.index))")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .tracking(0.7)

                Spacer(minLength: 8)
                statusBadge(record?.status)
            }

            Text(scene.heading)
                .font(.system(size: 14, weight: .semibold))
                .textCase(.uppercase)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

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
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: Style.elevatedBackground))
        .clipShape(RoundedRectangle(cornerRadius: Style.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Style.cornerRadius)
                .strokeBorder(Color(nsColor: Style.separator).opacity(0.75))
        }
    }

    private func metadataSection(_ scene: ScriptScene) -> some View {
        section("METADATA") {
            metadataRow("Scene number") {
                Text(scene.number ?? String(scene.index))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }

            rowDivider

            metadataRow("Status") {
                Picker("Status", selection: statusBinding) {
                    Text("—").tag(SceneStatus?.none)
                    ForEach(SceneStatus.allCases, id: \.self) { status in
                        Text(status.rawValue.capitalized).tag(SceneStatus?.some(status))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
                .accessibilityIdentifier("inspector.status")
            }

            rowDivider

            metadataRow("Shooting day") {
                TextField("—", value: shootingDayBinding, format: .number)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(width: 76)
            }

            rowDivider

            metadataRow("Duration") {
                TextField("0:00", text: durationBinding)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(width: 76)
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
                    .padding(.horizontal, 12)
                    .frame(minHeight: 42)
            } else {
                // Read from the script, not stored: who speaks in a scene is a
                // fact about the text, and duplicating it would let the two
                // disagree.
                ForEach(Array(scene.characters.enumerated()), id: \.element) { offset, name in
                    HStack(spacing: 10) {
                        castAvatar(for: name)

                        Text(name)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                        Spacer()
                        if let order = billingOrder(for: name) {
                            Text("#\(order)")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 43)

                    if offset < scene.characters.count - 1 {
                        rowDivider
                            .padding(.leading, 48)
                    }
                }
            }
        }
    }

    private var locationSection: some View {
        section("LOCATION") {
            metadataRow("Location") {
                TextField("Location name", text: locationNameBinding)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(maxWidth: 156)
            }

            rowDivider

            metadataRow("Set name") {
                TextField("Optional", text: locationSetNameBinding)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(maxWidth: 156)
                    .accessibilityIdentifier("inspector.location.setName")
            }

            rowDivider

            metadataRow("Interior / exterior") {
                Picker("Interior / exterior", selection: interiorExteriorBinding) {
                    Text("—").tag(InteriorExterior?.none)
                    ForEach(InteriorExterior.allCases, id: \.self) { value in
                        Text(value.rawValue.uppercased()).tag(InteriorExterior?.some(value))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
            }
        }
    }

    private var notesSection: some View {
        section("PRODUCTION NOTES") {
            let notes = record?.notes ?? []

            if notes.isEmpty {
                Text("No production notes yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 42, alignment: .leading)
            } else {
                ForEach(Array(notes.enumerated()), id: \.element.id) { offset, note in
                    Text(note.text)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if offset < notes.count - 1 {
                        rowDivider
                    }
                }
            }

            rowDivider

            Button { addNote() } label: {
                Label("Add Note", systemImage: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 11)
                    .frame(height: 26)
                    .contentShape(RoundedRectangle(cornerRadius: 5))
            }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .background {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.accentColor.opacity(0.8))
                }
                .padding(12)
                .accessibilityIdentifier("inspector.addNote")
        }
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.7)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 31)

            rowDivider
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: Style.elevatedBackground))
        .clipShape(RoundedRectangle(cornerRadius: Style.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Style.cornerRadius)
                .strokeBorder(Color(nsColor: Style.separator).opacity(0.75))
        }
    }

    private func metadataRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        LabeledContent {
            content()
        } label: {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Color(nsColor: Style.separator).opacity(0.65))
            .frame(height: 1)
    }

    @ViewBuilder
    private func statusBadge(_ status: SceneStatus?) -> some View {
        if let status {
            Text(status.rawValue.uppercased())
                .font(.system(size: 8, weight: .bold))
                .tracking(0.5)
                .padding(.horizontal, 7)
                .frame(height: 19)
                .background(Style.color(for: status).opacity(0.16))
                .foregroundStyle(Style.color(for: status))
                .clipShape(Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(Style.color(for: status).opacity(0.3))
                }
        } else {
            Text("NO STATUS")
                .font(.system(size: 8, weight: .semibold))
                .tracking(0.4)
                .padding(.horizontal, 7)
                .frame(height: 19)
                .foregroundStyle(.tertiary)
                .background(Color(nsColor: Style.paneBackground))
                .clipShape(Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(Color(nsColor: Style.separator).opacity(0.75))
                }
        }
    }

    private func castAvatar(for name: String) -> some View {
        let color = avatarColor(for: name)
        return Circle()
            .fill(
                LinearGradient(
                    colors: [color, color.opacity(0.65)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 27, height: 27)
            .overlay {
                Text(avatarInitials(for: name))
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .overlay {
                Circle()
                    .strokeBorder(.white.opacity(0.22), lineWidth: 1)
            }
            .shadow(color: color.opacity(0.2), radius: 2, y: 1)
            .accessibilityHidden(true)
    }

    private func avatarColor(for name: String) -> Color {
        let colors: [Color] = [.teal, .orange, .indigo, .pink, .green, .blue, .purple]
        let index = name.utf8.reduce(0) { partial, byte in
            (partial * 31 + Int(byte)) % colors.count
        }
        return colors[index]
    }

    private func avatarInitials(for name: String) -> String {
        let words = name.split { !$0.isLetter && !$0.isNumber }
        guard let first = words.first else { return "?" }
        if words.count > 1, let last = words.last {
            return String(first.prefix(1) + last.prefix(1)).uppercased()
        }
        return String(first.prefix(2)).uppercased()
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
                    var location = record.location ?? SceneLocation(name: "")
                    location.name = name
                    record.location = locationIsBlank(location) ? nil : location
                }
            }
        )
    }

    private var locationSetNameBinding: Binding<String> {
        Binding(
            get: { record?.location?.setName ?? "" },
            set: { setName in
                edit { record in
                    var location = record.location ?? SceneLocation(name: "")
                    location.setName = setName.isEmpty ? nil : setName
                    record.location = locationIsBlank(location) ? nil : location
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
                    record.location = locationIsBlank(location) ? nil : location
                }
            }
        )
    }

    private func locationIsBlank(_ location: SceneLocation) -> Bool {
        location.name.isEmpty
            && (location.setName?.isEmpty ?? true)
            && location.interiorExterior == nil
            && location.unknownFields.isEmpty
    }

    private func billingOrder(for name: String) -> Int? {
        record?.cast.first { $0.name == name }?.billingOrder
    }

    private func addNote() {
        edit { $0.notes.append(ProductionNote(text: "New note")) }
    }
}
