import Foundation

// The small value types a scene record is made of. Every closed vocabulary here
// carries an `other(String)` case: a newer build of the app may write a status
// or a revision colour this one has never heard of, and a raw-value enum would
// throw on it and take the whole file down with it. `other` round-trips the
// unrecognised value untouched.

/// Where a scene stands. Drives the coloured pill on a scene card.
public enum SceneStatus: Sendable, Hashable, CaseIterable {
    case outline
    case draft
    case revised
    case locked
    /// A status written by a version that knew more than this one.
    case other(String)

    /// The four this version understands, in workflow order.
    public static var allCases: [SceneStatus] { [.outline, .draft, .revised, .locked] }

    public init(rawValue: String) {
        switch rawValue {
        case "outline": self = .outline
        case "draft": self = .draft
        case "revised": self = .revised
        case "locked": self = .locked
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .outline: return "outline"
        case .draft: return "draft"
        case .revised: return "revised"
        case .locked: return "locked"
        case .other(let value): return value
        }
    }

    /// A locked scene keeps its number when pages are re-numbered, and the UI
    /// warns before editing one.
    public var isLocked: Bool {
        if case .locked = self { return true }
        return false
    }
}

/// The industry revision sequence. Production pages cycle through these colours
/// in this order, and the order is the point — "we're on pink" means the third
/// revision.
public enum RevisionColor: Sendable, Hashable, CaseIterable {
    case white
    case blue
    case pink
    case yellow
    case green
    case goldenrod
    case buff
    case salmon
    case cherry
    /// A colour from a longer sequence than this version knows.
    case other(String)

    public static var allCases: [RevisionColor] {
        [.white, .blue, .pink, .yellow, .green, .goldenrod, .buff, .salmon, .cherry]
    }

    public init(rawValue: String) {
        if let known = Self.allCases.first(where: { $0.rawValue == rawValue }) {
            self = known
        } else {
            self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .white: return "white"
        case .blue: return "blue"
        case .pink: return "pink"
        case .yellow: return "yellow"
        case .green: return "green"
        case .goldenrod: return "goldenrod"
        case .buff: return "buff"
        case .salmon: return "salmon"
        case .cherry: return "cherry"
        case .other(let value): return value
        }
    }

    /// Zero-based position in the standard sequence; nil for a colour this
    /// version does not know, which must not be given a position it might not
    /// hold in the sequence the writer was using.
    public var revisionNumber: Int? {
        Self.allCases.firstIndex(of: self)
    }

    /// The next colour up. After cherry the sequence traditionally restarts at
    /// "double white", which this version does not model — it returns nil rather
    /// than silently wrapping to white and losing a revision.
    public var next: RevisionColor? {
        guard let index = revisionNumber, index + 1 < Self.allCases.count else { return nil }
        return Self.allCases[index + 1]
    }
}

/// Interior, exterior, or both — the `INT`/`EXT` of a heading, recorded
/// separately so a scene can be scheduled by it without re-parsing the slugline.
public enum InteriorExterior: Sendable, Hashable, CaseIterable {
    case interior
    case exterior
    case both
    case other(String)

    public static var allCases: [InteriorExterior] { [.interior, .exterior, .both] }

    public init(rawValue: String) {
        switch rawValue {
        case "interior": self = .interior
        case "exterior": self = .exterior
        case "both": self = .both
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .interior: return "interior"
        case .exterior: return "exterior"
        case .both: return "both"
        case .other(let value): return value
        }
    }

    /// Reads `INT`/`EXT`/`INT./EXT.` off a scene heading, for seeding a record
    /// from the script rather than making the user retype it.
    public init?(heading: String) {
        let upper = heading.uppercased()
        if upper.hasPrefix("INT./EXT") || upper.hasPrefix("INT/EXT") || upper.hasPrefix("I/E") {
            self = .both
        } else if upper.hasPrefix("INT") {
            self = .interior
        } else if upper.hasPrefix("EXT") || upper.hasPrefix("EST") {
            self = .exterior
        } else {
            return nil
        }
    }
}

// MARK: - Coding

// Hand-written rather than `RawRepresentable` synthesis: the point of `other` is
// that decoding never fails, and a synthesised `init(from:)` for a raw-value
// enum throws on an unrecognised value.

extension SceneStatus: Codable {
    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension RevisionColor: Codable {
    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension InteriorExterior: Codable {
    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Cast

/// A character in a scene, with the billing order the mockups render as
/// `LENA #1`. The order is optional because it is a late-stage decision — most
/// scenes are cast long before anyone argues about billing.
public struct CastMember: Sendable, Hashable, Codable {
    /// The character cue as it reads in the script, extension stripped: `LENA`.
    public var name: String
    /// One-based billing position, or nil if unassigned.
    public var billingOrder: Int?
    public var unknownFields: [String: JSONValue]

    public init(name: String, billingOrder: Int? = nil, unknownFields: [String: JSONValue] = [:]) {
        self.name = name
        self.billingOrder = billingOrder
        self.unknownFields = unknownFields
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case name, billingOrder
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var consumed: Set<String> = []
        func take<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            let result = container.lenient(type, key)
            if result.consumed { consumed.insert(key.stringValue) }
            return result.value
        }
        name = take(String.self, .name) ?? ""
        billingOrder = take(Int.self, .billingOrder)
        unknownFields = try decoder.unknownFields(besides: consumed)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownFields: unknownFields)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(billingOrder, forKey: .billingOrder)
    }
}

// MARK: - Location

/// Where a scene shoots. Distinct from the heading: `EXT. MOUNTAIN – MORNING`
/// is what the script says, "Mount Tamalpais, Pantoll trailhead" is where the
/// unit goes, and a schedule groups by the latter.
public struct SceneLocation: Sendable, Hashable, Codable {
    /// What the location is called on the schedule.
    public var name: String
    /// The set, when a location holds several: "Lena's kitchen".
    public var setName: String?
    public var interiorExterior: InteriorExterior?
    public var unknownFields: [String: JSONValue]

    public init(
        name: String,
        setName: String? = nil,
        interiorExterior: InteriorExterior? = nil,
        unknownFields: [String: JSONValue] = [:]
    ) {
        self.name = name
        self.setName = setName
        self.interiorExterior = interiorExterior
        self.unknownFields = unknownFields
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case name, setName, interiorExterior
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var consumed: Set<String> = []
        func take<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            let result = container.lenient(type, key)
            if result.consumed { consumed.insert(key.stringValue) }
            return result.value
        }
        name = take(String.self, .name) ?? ""
        setName = take(String.self, .setName)
        interiorExterior = take(InteriorExterior.self, .interiorExterior)
        unknownFields = try decoder.unknownFields(besides: consumed)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownFields: unknownFields)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(setName, forKey: .setName)
        try container.encodeIfPresent(interiorExterior, forKey: .interiorExterior)
    }
}

// MARK: - Notes

/// A production note against a scene.
///
/// `createdAt` is optional because it is the one field a foreign writer is
/// likely to format differently. An unreadable timestamp leaves the note
/// readable and its raw value preserved, rather than failing the document.
public struct ProductionNote: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var text: String
    /// Who wrote it, when the app knows — a shared sidecar has several authors.
    public var author: String?
    public var createdAt: Date?
    public var unknownFields: [String: JSONValue]

    public init(
        id: UUID = UUID(),
        text: String,
        author: String? = nil,
        createdAt: Date? = Date(),
        unknownFields: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.text = text
        self.author = author
        self.createdAt = createdAt
        self.unknownFields = unknownFields
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, text, author, createdAt
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
        text = take(String.self, .text) ?? ""
        author = take(String.self, .author)
        createdAt = take(Date.self, .createdAt)
        unknownFields = try decoder.unknownFields(besides: consumed)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownFields: unknownFields)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(author, forKey: .author)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
    }
}
