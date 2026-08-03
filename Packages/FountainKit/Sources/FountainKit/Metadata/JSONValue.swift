import Foundation

/// A JSON value held verbatim.
///
/// The sidecar is the one file in this project that two *different versions* of
/// the app write to. It syncs between machines with Syncthing, so a file written
/// by a newer build is routinely opened, edited, and saved by an older one.
/// Swift's synthesised `Codable` silently discards every key it does not know
/// about, which would make that older build quietly destroy the newer build's
/// production data on its next save — the same class of failure as attaching
/// metadata to the wrong scene, and just as invisible.
///
/// So every type in the sidecar keeps the keys it did not understand in a
/// `[String: JSONValue]` and writes them back out untouched. `Int` and `Double`
/// are separate cases rather than one `Double` so a large integer survives the
/// round trip bit-for-bit.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Order matters: `true` is not an `Int`, and `1` is not a `Bool`, but
        // an integer *is* representable as a `Double`, so `Int` is tried first
        // to keep exact values exact.
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Int.self) { self = .int(value); return }
        if let value = try? container.decode(Double.self) { self = .double(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([JSONValue].self) { self = .array(value); return }
        if let value = try? container.decode([String: JSONValue].self) { self = .object(value); return }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Not a JSON value."
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// A coding key built at runtime, for sweeping up keys no type declared.
struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init(_ stringValue: String) { self.stringValue = stringValue }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

extension Decoder {
    /// Every key in this object that the caller did not consume, decoded whole.
    ///
    /// `consumed` is the set of keys that were *successfully* read, not the set
    /// the type declares. A key whose value has an unexpected type — a newer
    /// build changing `shootingDay` from a number to a string, say — is left
    /// unconsumed on purpose, so it lands here and survives instead of failing
    /// the whole document.
    func unknownFields(besides consumed: Set<String>) throws -> [String: JSONValue] {
        guard let container = try? container(keyedBy: DynamicKey.self) else { return [:] }
        var extras: [String: JSONValue] = [:]
        for key in container.allKeys where !consumed.contains(key.stringValue) {
            extras[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        return extras
    }
}

extension Encoder {
    /// Writes preserved keys into the JSON object a type is about to fill in.
    ///
    /// Asking an encoder for a second keyed container of a different key type
    /// appends to the same underlying dictionary rather than starting a new one,
    /// which is what lets a type emit its passengers and then its own fields.
    ///
    /// **Call this first, before the type encodes anything.** The ordering is
    /// the collision rule. A later write to the same key replaces an earlier
    /// one, so a field this version understands and has a value for overwrites
    /// any stale preserved copy — but a field it could only read as an unknown,
    /// because a newer version changed its type, is still there when the typed
    /// encode declines to write it. Filtering owned keys out up front would drop
    /// exactly that case, which is the one the preservation exists for.
    func encode(unknownFields fields: [String: JSONValue]) throws {
        guard !fields.isEmpty else { return }
        var container = self.container(keyedBy: DynamicKey.self)
        for key in fields.keys.sorted() {
            try container.encode(fields[key], forKey: DynamicKey(key))
        }
    }
}

extension KeyedDecodingContainer {
    /// Decodes a key if it is present *and* readable, reporting whether it was
    /// consumed. An unreadable value is reported as not consumed so the caller
    /// can preserve it verbatim rather than throwing.
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> (value: T?, consumed: Bool) {
        guard let value = try? decodeIfPresent(type, forKey: key) else { return (nil, false) }
        return (value, true)
    }
}
