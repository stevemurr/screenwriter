import Foundation

/// Everything a record remembers about the scene it was attached to.
///
/// This is the evidence the resolver reasons over after the script has been
/// edited underneath it. It is deliberately over-determined: four independent
/// signals, none of which is trusted alone, because the failure this whole
/// mechanism exists to prevent — metadata silently attaching to the *wrong*
/// scene — is only detectable by cross-checking one signal against another.
public struct SceneAnchor: Sendable, Hashable, Codable {
    /// The `#42#` suffix on the heading, hashes stripped. The strongest signal
    /// there is: `anal-informant.fountain` numbers all 95 of its scenes, and a
    /// number survives a reorder, a retitle, and a rewrite.
    public var sceneNumber: String?
    /// The heading as it read when the record was last saved, verbatim. Stored
    /// unnormalised so it can be shown to the user when a link breaks — "this
    /// used to be attached to EXT. MOUNTAIN – MORNING".
    public var heading: String
    /// Zero-based position among scenes whose *normalised* heading is identical.
    /// A script may legitimately hold the same heading many times.
    public var headingOccurrence: Int
    /// Zero-based document position when the record was last saved.
    public var orderIndex: Int
    /// Fingerprint of the scene's body, heading excluded. This is what tells two
    /// scenes with the same heading apart, and it is why swapping two identical
    /// sluglines does not shuffle their shooting days. Nil when the scene has no
    /// body to fingerprint.
    public var contentHash: String?
    public var unknownFields: [String: JSONValue]

    public init(
        sceneNumber: String? = nil,
        heading: String,
        headingOccurrence: Int = 0,
        orderIndex: Int = 0,
        contentHash: String? = nil,
        unknownFields: [String: JSONValue] = [:]
    ) {
        self.sceneNumber = sceneNumber
        self.heading = heading
        self.headingOccurrence = headingOccurrence
        self.orderIndex = orderIndex
        self.contentHash = contentHash
        self.unknownFields = unknownFields
    }

    /// The heading reduced to its comparable form.
    public var normalizedHeading: String { SceneIdentity.normalize(heading: heading) }

    /// The scene number reduced to its comparable form.
    public var normalizedNumber: String? { SceneIdentity.normalize(number: sceneNumber) }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case sceneNumber, heading, headingOccurrence, orderIndex, contentHash
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var consumed: Set<String> = []
        func take<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            let result = container.lenient(type, key)
            if result.consumed { consumed.insert(key.stringValue) }
            return result.value
        }
        sceneNumber = take(String.self, .sceneNumber)
        heading = take(String.self, .heading) ?? ""
        headingOccurrence = take(Int.self, .headingOccurrence) ?? 0
        orderIndex = take(Int.self, .orderIndex) ?? 0
        contentHash = take(String.self, .contentHash)
        unknownFields = try decoder.unknownFields(besides: consumed)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownFields: unknownFields)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(sceneNumber, forKey: .sceneNumber)
        try container.encode(heading, forKey: .heading)
        try container.encode(headingOccurrence, forKey: .headingOccurrence)
        try container.encode(orderIndex, forKey: .orderIndex)
        try container.encodeIfPresent(contentHash, forKey: .contentHash)
    }
}

/// Turning scenes into the comparable form the resolver works in.
public enum SceneIdentity {

    /// Reduces a heading to what two writers would agree it says.
    ///
    /// Case, whitespace and dash shape are all noise: `EXT. MOUNTAIN – MORNING`
    /// with an en dash is verbatim from the corpus and is the same heading as
    /// `EXT. MOUNTAIN - MORNING`. Curly apostrophes go the same way — the app
    /// disables macOS's substitutions (Rule 3), but text pasted in from Highland
    /// or Final Draft arrives with them already applied, and `INT. NEEL's WORK`
    /// must not stop matching itself because of one character.
    ///
    /// What is *not* normalised away: the words. `INT. KITCHEN - DAY` and
    /// `INT. KITCHEN - NIGHT` stay different headings, which is the entire
    /// reason this returns a string to compare rather than a similarity score.
    public static func normalize(heading: String) -> String {
        var result = String.UnicodeScalarView()
        result.reserveCapacity(heading.unicodeScalars.count)
        var pendingSpace = false
        var wroteAny = false

        for scalar in heading.unicodeScalars {
            let mapped = normalizeScalar(scalar)
            if mapped == " " {
                if wroteAny { pendingSpace = true }
                continue
            }
            if pendingSpace {
                result.append(" ")
                pendingSpace = false
            }
            result.append(mapped)
            wroteAny = true
        }
        return String(result)
    }

    /// Lowercases ASCII, folds every dash-like scalar onto `-`, folds curly
    /// quotes onto their straight forms, and treats every whitespace scalar as
    /// a plain space for the caller to collapse.
    private static func normalizeScalar(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        switch scalar.value {
        case 0x41...0x5A:                       // A-Z
            return Unicode.Scalar(scalar.value + 32)!
        case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0:
            return " "
        case 0x2010...0x2015,                   // hyphen, dashes, en dash, em dash
             0x2212,                            // minus sign
             0x2043,                            // hyphen bullet
             0xFE58, 0xFE63, 0xFF0D:            // small/full-width forms
            return "-"
        case 0x2018, 0x2019, 0x02BC:            // curly single quotes
            return "'"
        case 0x201C, 0x201D:                    // curly double quotes
            return "\""
        default:
            return scalar
        }
    }

    /// Scene numbers are matched case-insensitively and untrimmed of nothing
    /// else: `A12` and `a12` are the same scene, `12A` is not.
    public static func normalize(number: String?) -> String? {
        guard let number else { return nil }
        let trimmed = number.trimmingCharacters(in: .whitespaces).uppercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A fingerprint of a scene's body, heading excluded.
    ///
    /// Excluding the heading is deliberate: the hash's job is to say "this is
    /// the same scene even though you retitled it", and a hash that changed when
    /// the heading changed could not do that. Structural lines — sections,
    /// synopses, notes, boneyard — are excluded too, so filing a note against a
    /// scene does not break its own identity.
    ///
    /// Whitespace is collapsed across the whole body, so reflowing a paragraph
    /// is not a change. Nil for a scene with no body: hundreds of headings with
    /// nothing under them would all hash identically, which is worse than
    /// having no fingerprint at all.
    public static func contentHash(for scene: ScriptScene, in script: ParsedScript) -> String? {
        var hash: UInt64 = 0xcbf29ce484222325     // FNV-1a 64, offset basis
        var wroteAny = false
        var pendingSpace = false

        func feed(_ byte: UInt8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3          // FNV prime
        }

        let bounds = scene.elementRange.clamped(to: script.elements.indices)
        for element in script.elements[bounds] {
            switch element.kind {
            case .sceneHeading, .section, .synopsis, .note, .boneyard, .blank:
                continue
            case .action, .character, .parenthetical, .dialogue, .transition,
                 .centered, .lyrics, .pageBreak:
                break
            }
            if wroteAny { pendingSpace = true }
            for byte in element.text.utf8 {
                if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                    if wroteAny { pendingSpace = true }
                    continue
                }
                if pendingSpace {
                    feed(0x20)
                    pendingSpace = false
                }
                feed(byte)
                wroteAny = true
            }
        }
        guard wroteAny else { return nil }
        return String(hash, radix: 16)
    }

    /// Fresh anchors for every scene in a parse, in document order.
    ///
    /// This is what a save writes: whatever the resolver decided, the file that
    /// lands on disk describes the script as it is *now*, so the next open
    /// starts from exact matches rather than compounding a fuzzy one.
    public static func anchors(for script: ParsedScript) -> [SceneAnchor] {
        var occurrences: [String: Int] = [:]
        return script.scenes.enumerated().map { order, scene in
            let normalized = normalize(heading: scene.heading)
            let occurrence = occurrences[normalized, default: 0]
            occurrences[normalized] = occurrence + 1
            return SceneAnchor(
                sceneNumber: scene.number,
                heading: scene.heading,
                headingOccurrence: occurrence,
                orderIndex: order,
                contentHash: contentHash(for: scene, in: script)
            )
        }
    }
}
