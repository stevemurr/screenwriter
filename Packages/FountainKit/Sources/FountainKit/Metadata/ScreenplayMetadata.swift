import Foundation

/// Production data for one screenplay, held beside the script rather than in it.
///
/// Fountain has nowhere to record a shooting day, and inventing a syntax for one
/// would make the `.fountain` file unreadable to every other tool that opens it.
/// So this lives in a sidecar: `<basename>.screenwriter.json` next to a bare
/// `.fountain`, and `screenwriter.json` inside a `.screenplay` package. Same
/// schema, same type, two locations — see `MetadataStore`.
///
/// The file is written with sorted keys and pretty printing because git is
/// supposed to be able to read it. That is the whole argument for plain text in
/// this project, and a one-line JSON blob would forfeit it.
///
/// Nothing here is a timestamp of the last save. A field that changes on every
/// write makes the file diff even when nothing about the production changed,
/// which is the same problem from the other direction.
public struct ScreenplayMetadata: Sendable, Hashable, Codable {

    /// Bumped when a field changes meaning, never when one is added — adding is
    /// what the unknown-field preservation is for.
    public static let currentSchemaVersion = 1

    /// The schema this file declares. A file from a newer build keeps its own
    /// higher number when this build rewrites it: every field is preserved, so
    /// claiming the file had been downgraded would be a lie that could make the
    /// newer build discard data it could have kept.
    public var schemaVersion: Int
    /// The app build that last wrote the file, for diagnosing a bad sidecar.
    public var writerVersion: String?
    /// The revision colour the current pages are on.
    public var currentRevision: RevisionColor?
    /// Display order for act names, so the Beat Board's columns keep the order
    /// the writer put them in rather than the order they happen to be mentioned.
    public var actOrder: [String]
    /// Display order for sequence names — the Beat Board's columns.
    public var sequenceOrder: [String]
    /// One record per scene, in document order as of the last save. Orphans keep
    /// their place in this list; nothing is dropped without an explicit call to
    /// `removeOrphans`.
    public var scenes: [SceneMetadata]
    public var unknownFields: [String: JSONValue]

    public init(
        schemaVersion: Int = ScreenplayMetadata.currentSchemaVersion,
        writerVersion: String? = nil,
        currentRevision: RevisionColor? = nil,
        actOrder: [String] = [],
        sequenceOrder: [String] = [],
        scenes: [SceneMetadata] = [],
        unknownFields: [String: JSONValue] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.writerVersion = writerVersion
        self.currentRevision = currentRevision
        self.actOrder = actOrder
        self.sequenceOrder = sequenceOrder
        self.scenes = scenes
        self.unknownFields = unknownFields
    }

    /// What a document with no sidecar yet has. Not an error state.
    public static let empty = ScreenplayMetadata()

    /// True when there is nothing worth writing to disk.
    public var isEmpty: Bool {
        scenes.isEmpty && currentRevision == nil && actOrder.isEmpty
            && sequenceOrder.isEmpty && unknownFields.isEmpty
    }

    public func record(id: UUID) -> SceneMetadata? {
        scenes.first { $0.id == id }
    }

    /// Total estimated running time, for the status bar.
    public var estimatedSeconds: Int {
        scenes.reduce(0) { $0 + ($1.estimatedSeconds ?? 0) }
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, writerVersion, currentRevision, actOrder, sequenceOrder, scenes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var consumed: Set<String> = []
        func take<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            let result = container.lenient(type, key)
            if result.consumed { consumed.insert(key.stringValue) }
            return result.value
        }
        schemaVersion = take(Int.self, .schemaVersion) ?? ScreenplayMetadata.currentSchemaVersion
        writerVersion = take(String.self, .writerVersion)
        currentRevision = take(RevisionColor.self, .currentRevision)
        actOrder = take([String].self, .actOrder) ?? []
        sequenceOrder = take([String].self, .sequenceOrder) ?? []
        scenes = take([SceneMetadata].self, .scenes) ?? []
        unknownFields = try decoder.unknownFields(besides: consumed)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownFields: unknownFields)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(max(schemaVersion, Self.currentSchemaVersion), forKey: .schemaVersion)
        try container.encodeIfPresent(writerVersion, forKey: .writerVersion)
        try container.encodeIfPresent(currentRevision, forKey: .currentRevision)
        if !actOrder.isEmpty { try container.encode(actOrder, forKey: .actOrder) }
        if !sequenceOrder.isEmpty { try container.encode(sequenceOrder, forKey: .sequenceOrder) }
        if !scenes.isEmpty { try container.encode(scenes, forKey: .scenes) }
    }
}

/// Production data for one scene.
///
/// `id` is a UUID rather than a scene number or a heading, because both of those
/// are things the writer edits. The UUID is what a UI selection, an undo entry,
/// and a re-link dialog can hold onto across any edit at all; `anchor` is the
/// separate, fallible business of finding which scene it currently belongs to.
public struct SceneMetadata: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    /// How this record finds its scene again. Rewritten on save.
    public var anchor: SceneAnchor
    public var status: SceneStatus?
    /// Which day of the shoot this scene is scheduled for.
    public var shootingDay: Int?
    /// Estimated running time in seconds — `105` reads as `01:45`. Seconds
    /// rather than a formatted string so a schedule can add them up.
    public var estimatedSeconds: Int?
    /// Who is in the scene, with optional billing order: `LENA #1`, `OWEN #2`.
    public var cast: [CastMember]
    public var location: SceneLocation?
    public var notes: [ProductionNote]
    /// Act assignment. Free text: the corpus writes `# Act One`, but a series
    /// might write `Teaser` or `Cold Open`.
    public var act: String?
    /// Sequence assignment — the Beat Board's columns.
    public var sequence: String?
    public var revisionColor: RevisionColor?
    public var unknownFields: [String: JSONValue]

    public init(
        id: UUID = UUID(),
        anchor: SceneAnchor,
        status: SceneStatus? = nil,
        shootingDay: Int? = nil,
        estimatedSeconds: Int? = nil,
        cast: [CastMember] = [],
        location: SceneLocation? = nil,
        notes: [ProductionNote] = [],
        act: String? = nil,
        sequence: String? = nil,
        revisionColor: RevisionColor? = nil,
        unknownFields: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.anchor = anchor
        self.status = status
        self.shootingDay = shootingDay
        self.estimatedSeconds = estimatedSeconds
        self.cast = cast
        self.location = location
        self.notes = notes
        self.act = act
        self.sequence = sequence
        self.revisionColor = revisionColor
        self.unknownFields = unknownFields
    }

    /// `01:45`, or `1:02:30` once a scene runs over an hour — which happens in
    /// a stage play import, not a feature.
    public var durationText: String? {
        guard let estimatedSeconds, estimatedSeconds >= 0 else { return nil }
        let hours = estimatedSeconds / 3600
        let minutes = (estimatedSeconds % 3600) / 60
        let seconds = estimatedSeconds % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// True when nothing has been filled in — used to decide whether losing the
    /// link to a scene is worth telling the user about.
    public var isBlank: Bool {
        status == nil && shootingDay == nil && estimatedSeconds == nil && cast.isEmpty
            && location == nil && notes.isEmpty && act == nil && sequence == nil
            && revisionColor == nil && unknownFields.isEmpty
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, anchor, status, shootingDay, estimatedSeconds, cast, location,
             notes, act, sequence, revisionColor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var consumed: Set<String> = []
        func take<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            let result = container.lenient(type, key)
            if result.consumed { consumed.insert(key.stringValue) }
            return result.value
        }
        id = take(UUID.self, .id) ?? UUID()
        anchor = take(SceneAnchor.self, .anchor) ?? SceneAnchor(heading: "")
        status = take(SceneStatus.self, .status)
        shootingDay = take(Int.self, .shootingDay)
        estimatedSeconds = take(Int.self, .estimatedSeconds)
        cast = take([CastMember].self, .cast) ?? []
        location = take(SceneLocation.self, .location)
        notes = take([ProductionNote].self, .notes) ?? []
        act = take(String.self, .act)
        sequence = take(String.self, .sequence)
        revisionColor = take(RevisionColor.self, .revisionColor)
        unknownFields = try decoder.unknownFields(besides: consumed)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownFields: unknownFields)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(anchor, forKey: .anchor)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(shootingDay, forKey: .shootingDay)
        try container.encodeIfPresent(estimatedSeconds, forKey: .estimatedSeconds)
        if !cast.isEmpty { try container.encode(cast, forKey: .cast) }
        try container.encodeIfPresent(location, forKey: .location)
        if !notes.isEmpty { try container.encode(notes, forKey: .notes) }
        try container.encodeIfPresent(act, forKey: .act)
        try container.encodeIfPresent(sequence, forKey: .sequence)
        try container.encodeIfPresent(revisionColor, forKey: .revisionColor)
    }
}

// MARK: - Reconciling with a parse

extension ScreenplayMetadata {

    /// Points every matched record at the scene it now belongs to, and rewrites
    /// its anchor to describe the script as it is.
    ///
    /// Orphans are left exactly as they were. Their old anchor is the only
    /// evidence of where they came from, and it is what a re-link dialog shows.
    ///
    /// Records are re-sorted into document order afterwards so the JSON diffs
    /// alongside the script rather than in some historical order nobody can see.
    public mutating func reanchor(to script: ParsedScript, using resolution: MetadataResolution) {
        let anchors = SceneIdentity.anchors(for: script)
        for index in scenes.indices {
            guard let sceneIndex = resolution.sceneIndex(for: scenes[index].id),
                  sceneIndex >= 1, sceneIndex <= anchors.count else { continue }
            var updated = anchors[sceneIndex - 1]
            // Whatever a newer build hung off this anchor stays hung off it.
            updated.unknownFields = scenes[index].anchor.unknownFields
            scenes[index].anchor = updated
        }
        scenes = scenes.enumerated()
            .sorted { ($0.element.anchor.orderIndex, $0.offset) < ($1.element.anchor.orderIndex, $1.offset) }
            .map(\.element)
    }

    /// Adds a blank record for every scene that no record claimed, so a UI can
    /// edit any scene in the document.
    ///
    /// Separate from `reanchor` because creating records is a choice: an app
    /// that only writes a sidecar when the user actually enters something keeps
    /// the file small and keeps a fresh document from acquiring one at all.
    @discardableResult
    public mutating func addRecordsForUnmatchedScenes(
        in script: ParsedScript,
        using resolution: MetadataResolution
    ) -> [UUID] {
        let anchors = SceneIdentity.anchors(for: script)
        var created: [UUID] = []
        for sceneIndex in resolution.unmatchedSceneIndices
        where sceneIndex >= 1 && sceneIndex <= anchors.count {
            let record = SceneMetadata(anchor: anchors[sceneIndex - 1])
            scenes.append(record)
            created.append(record.id)
        }
        scenes = scenes.enumerated()
            .sorted { ($0.element.anchor.orderIndex, $0.offset) < ($1.element.anchor.orderIndex, $1.offset) }
            .map(\.element)
        return created
    }

    /// Drops records that no longer resolve to a scene, returning what was
    /// dropped so the caller can offer an undo.
    ///
    /// **Only ever call this because the user asked.** Collecting orphans on
    /// load would mean a script opened while its `.fountain` was half-synced —
    /// or opened by accident from a stale copy — silently destroying a shooting
    /// schedule. Losing the link is recoverable; losing the record is not.
    @discardableResult
    public mutating func removeOrphans(_ resolution: MetadataResolution) -> [SceneMetadata] {
        let orphaned = Set(resolution.orphanedRecordIDs)
        guard !orphaned.isEmpty else { return [] }
        let removed = scenes.filter { orphaned.contains($0.id) }
        scenes.removeAll { orphaned.contains($0.id) }
        return removed
    }
}
