import Foundation

/// What a script has already said: its cast, its locations, and the times of day
/// it shoots at.
///
/// The document is the memory. A screenplay names the same dozen people and the
/// same handful of rooms for a hundred pages, and every one of those names has
/// to be spelled identically or the cast list splits in two and the sidebar
/// grows a `MARLA` and a `MARIA`. The parser already knows all of it — this is
/// only the part that puts it in the order a completion list wants: what you use
/// most, first.
public struct ScriptVocabulary: Sendable, Equatable {
    /// Cast, most-used first, ties broken by first appearance.
    public let characters: [String]
    /// The location half of a scene heading: `INT. DINER - NIGHT` gives `DINER`.
    public let locations: [String]
    /// The time half, script-used first and the conventional ones after.
    public let timesOfDay: [String]

    public init(characters: [String] = [], locations: [String] = [], timesOfDay: [String] = []) {
        self.characters = characters
        self.locations = locations
        self.timesOfDay = timesOfDay
    }

    /// The times of day every screenplay uses, offered even in a script that has
    /// not used them yet — a blank document should still complete `- N` to
    /// `NIGHT`. Anything the script actually uses outranks all of them.
    public static let conventionalTimesOfDay = [
        "DAY", "NIGHT", "CONTINUOUS", "LATER", "MOMENTS LATER",
        "MORNING", "AFTERNOON", "EVENING", "DAWN", "DUSK", "SAME"
    ]

    public init(script: ParsedScript) {
        var characterCounts: [String: (count: Int, first: Int)] = [:]
        var locationCounts: [String: (count: Int, first: Int)] = [:]
        var timeCounts: [String: (count: Int, first: Int)] = [:]

        func note(_ value: String, into table: inout [String: (count: Int, first: Int)], at order: Int) {
            let key = value.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { return }
            if var existing = table[key] {
                existing.count += 1
                table[key] = existing
            } else {
                table[key] = (1, order)
            }
        }

        for (order, element) in script.elements.enumerated() {
            switch element.kind {
            case .character:
                note(ScriptParser.characterName(from: element.text), into: &characterCounts, at: order)
            case .sceneHeading:
                let parts = SceneHeading.split(element.text)
                if let location = parts.location, SceneHeading.isPlausibleLocation(location) {
                    note(location, into: &locationCounts, at: order)
                }
                if let time = parts.timeOfDay {
                    note(time, into: &timeCounts, at: order)
                }
            default:
                break
            }
        }

        func ranked(_ table: [String: (count: Int, first: Int)]) -> [String] {
            table
                .sorted {
                    $0.value.count == $1.value.count
                        ? $0.value.first < $1.value.first
                        : $0.value.count > $1.value.count
                }
                .map(\.key)
        }

        characters = ranked(characterCounts)
        locations = ranked(locationCounts)

        let used = ranked(timeCounts)
        let usedSet = Set(used)
        timesOfDay = used + Self.conventionalTimesOfDay.filter { !usedSet.contains($0) }
    }
}

/// Taking a scene heading apart, and putting one back together.
public enum SceneHeading {
    /// The prefixes that open a heading, longest first so `INT./EXT.` is not
    /// mistaken for `INT.`.
    public static let prefixes = [
        "INT./EXT.", "INT/EXT.", "INT./EXT", "INT/EXT", "I/E.", "I/E",
        "INT.", "INT ", "EXT.", "EXT ", "EST.", "EST "
    ]

    /// `INT. DINER - NIGHT` → prefix `INT.`, location `DINER`, time `NIGHT`.
    ///
    /// The separator is matched as hyphen *or* en dash: the corpus contains
    /// `EXT. MOUNTAIN – MORNING`, and a vocabulary that missed those would offer
    /// `MOUNTAIN – MORNING` as a location.
    public static func split(_ heading: String) -> (prefix: String?, location: String?, timeOfDay: String?) {
        let trimmed = heading.trimmingCharacters(in: .whitespaces)
        var rest = Substring(trimmed)
        var prefix: String?
        for candidate in prefixes where ScriptParser.hasUppercasedPrefix(String(rest), candidate) {
            prefix = candidate
            rest = rest.dropFirst(candidate.count)
            break
        }
        rest = Substring(rest.trimmingCharacters(in: .whitespaces))
        guard !rest.isEmpty else { return (prefix, nil, nil) }

        guard let separator = lastSeparator(in: String(rest)) else {
            return (prefix, String(rest), nil)
        }
        let location = String(rest[rest.startIndex..<separator.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        let time = String(rest[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
        return (prefix, location.isEmpty ? nil : location, time.isEmpty ? nil : time)
    }

    /// Whether a parsed location is worth offering as a completion.
    ///
    /// The parser is lenient by policy (Rule 13) and `.` forces a scene heading,
    /// so a document that uses `.` as a general beat prefix produces "headings"
    /// like `.- stair case problem`. `Ergosphere` in the corpus does exactly
    /// that, and without this the location list offers a sentence of somebody's
    /// notes. The linter already flags those lines as `ambiguous-forced-mark`;
    /// this only keeps them out of a menu.
    ///
    /// Two rules, both about shape rather than content: a location does not open
    /// with a separator, and it is a name rather than a sentence — the same
    /// 60-byte bound `ScriptParser.isCharacterCue` uses for the same reason.
    public static func isPlausibleLocation(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first else { return false }
        guard !["-", "–", "—"].contains(String(first)) else { return false }
        return text.utf8.count <= 60
    }

    /// The last ` - ` or ` – ` in the string, which is what divides location
    /// from time — a location may itself contain a dash (`INT. WELL-HOUSE`).
    private static func lastSeparator(in text: String) -> Range<String.Index>? {
        var found: Range<String.Index>?
        for marker in [" - ", " – ", " — "] {
            var search = text.startIndex..<text.endIndex
            while let range = text.range(of: marker, range: search) {
                if found == nil || range.lowerBound > found!.lowerBound { found = range }
                guard range.upperBound < text.endIndex else { break }
                search = range.upperBound..<text.endIndex
            }
        }
        return found
    }
}
