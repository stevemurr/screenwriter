import Foundation

/// Reading and writing the metadata sidecar.
///
/// Two locations, one schema:
///
/// - beside a bare `.fountain`, as `<basename>.screenwriter.json`, so a plain
///   Fountain file keeps working in every other tool that opens it;
/// - inside a `.screenplay` package, as `screenwriter.json`, alongside the
///   `text.fountain` payload and `info.json`.
///
/// The `.screenplay` case could have gone into `info.json` under
/// `TextBundle.settingsNamespace`, and deliberately does not. Keeping it in its
/// own file means the two locations hold *byte-identical* JSON, so converting a
/// document between the two formats is a file move rather than a migration, and
/// a diff of a `.screenplay` shows production changes separately from bundle
/// bookkeeping.
public enum MetadataStore {

    /// The name inside a `.screenplay` package.
    public static let fileName = "screenwriter.json"
    /// The suffix beside a bare `.fountain`: `heat.fountain` gets
    /// `heat.screenwriter.json`.
    public static let sidecarSuffix = "screenwriter.json"
    /// The package extension whose sidecar lives inside it.
    public static let packageExtension = "screenplay"

    // MARK: - Locating

    /// Where the sidecar for a document lives.
    ///
    /// The package test is by extension first and by the filesystem second: on
    /// a Save As, the package may not exist yet, so asking the filesystem alone
    /// would put the sidecar in the wrong place for a document that is about to
    /// become a directory.
    public static func sidecarURL(for documentURL: URL) -> URL {
        if isPackage(documentURL) {
            return documentURL.appendingPathComponent(fileName)
        }
        return documentURL
            .deletingPathExtension()
            .appendingPathExtension(sidecarSuffix)
    }

    static func isPackage(_ url: URL) -> Bool {
        if url.pathExtension.caseInsensitiveCompare(packageExtension) == .orderedSame {
            return true
        }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    // MARK: - Reading

    /// Loads the sidecar for a document.
    ///
    /// A missing sidecar is not an error and never has been: most documents have
    /// no production data, a brand new one certainly does not, and throwing here
    /// would mean every caller writing the same `catch` to turn it back into an
    /// empty value.
    ///
    /// Unreadable JSON *is* an error, and a loud one. It is not repaired, not
    /// deleted, and not replaced with an empty value — a truncated sidecar may
    /// be the only copy of a shooting schedule, and the bytes that are left are
    /// worth more than a clean start. The file stays exactly where it is; see
    /// `save` for what happens next.
    public static func load(for documentURL: URL) throws -> ScreenplayMetadata {
        try load(contentsOf: sidecarURL(for: documentURL))
    }

    public static func load(contentsOf url: URL) throws -> ScreenplayMetadata {
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw MetadataStoreError.unreadable(url: url, underlying: error)
        }
        guard !data.isEmpty else { throw MetadataStoreError.corrupt(url: url, underlying: nil) }
        do {
            return try decoder.decode(ScreenplayMetadata.self, from: data)
        } catch {
            throw MetadataStoreError.corrupt(url: url, underlying: error)
        }
    }

    /// True when a sidecar exists on disk but cannot be parsed. Lets a caller
    /// warn *before* the user edits anything, rather than at save time.
    public static func isCorrupt(for documentURL: URL) -> Bool {
        let url = sidecarURL(for: documentURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        if case .some = try? load(contentsOf: url) { return false }
        return true
    }

    // MARK: - Writing

    public struct SaveOutcome: Sendable, Hashable {
        /// Where the metadata was written.
        public var url: URL
        /// Where an unreadable previous sidecar was moved to, if there was one.
        public var quarantinedURL: URL?
    }

    /// Writes the sidecar for a document, atomically.
    ///
    /// Two things this must never do, both learned from what the file is for:
    ///
    /// **It must not truncate.** `Data.write` with `.atomic` writes a temporary
    /// file in the same directory and renames it into place, and rename is
    /// atomic on every filesystem the app runs on. A crash — or a Syncthing
    /// pickup — mid-save sees either the old file or the new one, never half of
    /// either.
    ///
    /// **It must not overwrite something it could not read.** If the existing
    /// sidecar fails to parse, it is moved to a timestamped `.corrupt` sibling
    /// before the new one lands, so whatever was in it can still be recovered by
    /// hand. Overwriting it would be the one irreversible operation in this
    /// whole file.
    @discardableResult
    public static func save(
        _ metadata: ScreenplayMetadata,
        for documentURL: URL
    ) throws -> SaveOutcome {
        try save(metadata, to: sidecarURL(for: documentURL))
    }

    @discardableResult
    public static func save(_ metadata: ScreenplayMetadata, to url: URL) throws -> SaveOutcome {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        guard manager.fileExists(atPath: directory.path) else {
            throw MetadataStoreError.directoryMissing(url: directory)
        }

        var quarantined: URL?
        if manager.fileExists(atPath: url.path), (try? load(contentsOf: url)) == nil {
            quarantined = try quarantine(url)
        }

        let data = try encode(metadata)
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw MetadataStoreError.notWritable(url: url, underlying: error)
        }
        return SaveOutcome(url: url, quarantinedURL: quarantined)
    }

    /// Moves an unreadable sidecar aside, without ever colliding with an earlier
    /// rescue of the same file.
    static func quarantine(_ url: URL) throws -> URL {
        let stamp = ISO8601DateFormatter.filenameSafe.string(from: Date())
        var candidate = url.appendingPathExtension("corrupt-\(stamp)")
        var attempt = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.appendingPathExtension("corrupt-\(stamp)-\(attempt)")
            attempt += 1
        }
        do {
            try FileManager.default.moveItem(at: url, to: candidate)
        } catch {
            throw MetadataStoreError.notWritable(url: candidate, underlying: error)
        }
        return candidate
    }

    /// Deletes the sidecar, if there is one. For a document that has had all its
    /// production data cleared — leaving an empty JSON file next to every script
    /// the user ever opened would be litter.
    public static func removeSidecar(for documentURL: URL) throws {
        let url = sidecarURL(for: documentURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - Coding

    /// Sorted keys and pretty printing, because git is supposed to be able to
    /// read this. A one-line blob would make every change to any scene look like
    /// a change to the whole file, which is the entire property the plain-text
    /// formats in this project exist to keep. Slashes go unescaped so
    /// `INT./EXT. CAR` reads as itself.
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // ISO 8601, with sub-second precision written only when the date
        // actually has any. This app stamps notes on the second, and
        // `2026-08-02T12:00:00.000Z` in every one of them is noise in a file
        // meant to be read. But a date that arrived from a more precise writer
        // keeps its milliseconds rather than being silently rounded — the same
        // rule as every other field here.
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let seconds = date.timeIntervalSince1970
            let formatter = seconds == seconds.rounded()
                ? ISO8601DateFormatter.standard
                : ISO8601DateFormatter.fractional
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }

    /// Dates are read leniently — with or without fractional seconds — because a
    /// newer build adding milliseconds to a note's timestamp must not make the
    /// file unreadable to this one.
    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = ISO8601DateFormatter.standard.date(from: text) { return date }
            if let date = ISO8601DateFormatter.fractional.date(from: text) { return date }
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Not an ISO 8601 date: \(text)"
                )
            )
        }
        return decoder
    }

    public static func encode(_ metadata: ScreenplayMetadata) throws -> Data {
        var data = try encoder.encode(metadata)
        // A trailing newline: every other text file in the project has one, and
        // its absence is what makes git print "\ No newline at end of file" on
        // an otherwise clean diff.
        if data.last != 0x0A { data.append(0x0A) }
        return data
    }

    public static func decode(_ data: Data) throws -> ScreenplayMetadata {
        try decoder.decode(ScreenplayMetadata.self, from: data)
    }
}

public enum MetadataStoreError: LocalizedError {
    case corrupt(url: URL, underlying: Error?)
    case unreadable(url: URL, underlying: Error)
    case notWritable(url: URL, underlying: Error)
    case directoryMissing(url: URL)

    public var errorDescription: String? {
        switch self {
        case .corrupt(let url, _):
            return "The production data in “\(url.lastPathComponent)” couldn’t be read."
        case .unreadable(let url, _):
            return "“\(url.lastPathComponent)” couldn’t be opened."
        case .notWritable(let url, _):
            return "The production data couldn’t be saved to “\(url.lastPathComponent)”."
        case .directoryMissing(let url):
            return "The folder “\(url.lastPathComponent)” doesn’t exist."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .corrupt:
            return "The file has been left exactly as it is. The screenplay itself is "
                + "unaffected, and the scenes will open without their production data."
        case .unreadable, .notWritable, .directoryMissing:
            return nil
        }
    }
}

extension ISO8601DateFormatter {
    static let standard: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// `20260802T143107Z` — no colons. They are legal in a macOS filename but
    /// the Finder renders them as slashes, which makes a rescued file look like
    /// a path.
    static let filenameSafe: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]
        return formatter
    }()
}
