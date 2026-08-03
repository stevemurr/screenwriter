import Foundation

/// Reads a `.highland` document — a zipped TextBundle — into our `TextBundle`.
///
/// **Rule 6: `.highland` is read-only, forever.** This type takes bytes and
/// returns a value. It has no writer, no file handle opened for writing, and no
/// path back to the original document. The 59 bundles in the reference library
/// are irreplaceable; migration copies out, it never edits in place.
///
/// Two generations of the format appear in that library and both are handled:
///
/// ```
/// legacy (has resources/)                current (flat sidecars)
///   Clean Break.textbundle/                Episode 1.textbundle/
///     text.md                                text.fountain
///     info.json                              info.json
///     navigatorFilters.json                  navigatorFilters.json
///     scratchpad.txt                         characters.json
///     resources/{settings,header,footer,     sprints.json
///       characters,sideboards,shelf,
///       outline,revisions,navigator-filters}.json
///     revisions/current.json
///     assets/  bin/
/// ```
///
/// They are not cleanly separated: a document edited across Highland versions
/// carries both shapes at once, and the payload filename is independent of
/// either (2 of the flat-sidecar bundles still hold `text.md`). So nothing here
/// branches on "generation" — it reads whatever is present.
public struct HighlandBundle {

    /// Highland's own layout hint, for reporting. A document that has been
    /// edited across versions can carry both shapes, in which case `resources/`
    /// wins, because that is the part that changes how settings are read.
    public enum Generation: String, Sendable {
        /// Sidecars under `resources/`, plus a `revisions/` folder.
        case legacy
        /// Sidecars at the bundle root: `characters.json`, `sprints.json`.
        case current
    }

    /// What an import kept, changed and left behind.
    public struct Import: Sendable {
        public var bundle: TextBundle
        public var generation: Generation
        /// Opaque Highland state deliberately not carried across, and its size.
        public var dropped: [String]
        public var droppedBytes: Int
        /// Sidecars whose bytes would not decode, with the reason. A damaged
        /// PNG asset is never a reason to fail an import of the screenplay.
        public var unreadable: [Unreadable]
    }

    public struct Unreadable: Sendable {
        public var path: String
        public var reason: String
    }

    /// Highland's revision history: `{"number":N,"content":"<base64 plist>"}`,
    /// where the payload is an `NSKeyedArchiver` archive of an attributed
    /// string — 213 KB of it in `Clean Break`.
    ///
    /// **Dropped by default**, deliberately. The whole point of `.screenplay`
    /// being an *uncompressed* TextBundle is that git, grep and Syncthing can
    /// read what is inside it; a base64 blob of another app's private object
    /// graph is the exact thing we are migrating away from, it is state we will
    /// never read or update, and carrying a stale copy forward would rot in
    /// place. Nothing is lost: Rule 6 means the `.highland` original survives
    /// untouched as the archive of record. Pass `keepingOpaqueState: true` to
    /// carry it anyway.
    ///
    /// Note that `resources/revisions.json` is *not* on this list — that one is
    /// plain JSON ranges, which diffs fine and stays.
    public static let opaqueStatePaths: Set<String> = ["revisions/current.json"]

    /// Highland's namespace inside `info.json`, mirroring ours.
    public static let highlandNamespace = "com.quoteunquoteapps.highland2"

    /// Print flags that mean the same thing in both apps, copied across by name.
    /// Highland records them in up to three places; see `settings(from:)`.
    static let mappedPrintSettings = [
        "printTitlePage",
        "printSections",
        "printSynopses",
        "printInlineNotes",
        "printGeneratedText",
        "printParagraphNumbers"
    ]

    public let archive: ZipReader
    /// The `*.textbundle/` directory the zip wraps everything in, including its
    /// trailing slash. Empty when the archive has no single root.
    public let rootPrefix: String

    public init(data: Data) throws {
        self.archive = try ZipReader(data: data)
        self.rootPrefix = HighlandBundle.rootPrefix(for: archive.entries)
    }

    /// Reads the file. `Data(contentsOf:)` and nothing else — Rule 6.
    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    // MARK: - Import

    public func textBundle() throws -> TextBundle {
        try imported().bundle
    }

    public func imported(keepingOpaqueState: Bool = false) throws -> Import {
        var payload: (name: String, data: Data)?
        var highlandInfo: [String: Any] = [:]
        var extras: [String: Data] = [:]
        var dropped: [String] = []
        var droppedBytes = 0
        var unreadable: [Unreadable] = []
        var isLegacy = false
        var settingsSources: [[String: Any]] = []

        for entry in archive.entries {
            guard !entry.isDirectory else { continue }
            let path = relativePath(of: entry)
            guard !path.isEmpty else { continue }

            if path.hasPrefix("resources/") { isLegacy = true }

            if !keepingOpaqueState, HighlandBundle.opaqueStatePaths.contains(path) {
                dropped.append(path)
                droppedBytes += entry.uncompressedSize
                continue
            }

            let data: Data
            do {
                data = try archive.data(for: entry)
            } catch {
                // The payload failing is fatal; a sidecar failing is a note.
                if TextBundle.isPayloadName(path) {
                    throw HighlandImportError.unreadablePayload(
                        path, error.localizedDescription
                    )
                }
                unreadable.append(Unreadable(path: path, reason: error.localizedDescription))
                continue
            }

            if path == TextBundle.infoFileName {
                highlandInfo = HighlandBundle.object(from: data)
                continue
            }
            if TextBundle.isPayloadName(path), HighlandBundle.prefers(path, over: payload?.name) {
                // A payload that loses the tie-break is still a file the bundle
                // carried, so it is kept as a sidecar rather than dropped.
                if let previous = payload { extras[previous.name] = previous.data }
                payload = (path, data)
                continue
            }
            if path == "resources/settings.json" {
                settingsSources.append(HighlandBundle.object(from: data))
            }
            extras[path] = data
        }

        guard let payload else { throw HighlandImportError.missingPayload }

        let info = HighlandBundle.info(
            merging: highlandInfo,
            settings: HighlandBundle.settings(from: highlandInfo, resources: settingsSources)
        )

        return Import(
            bundle: TextBundle(
                text: TextBundle.decode(payload.data),
                textFileName: payload.name,
                infoData: info,
                extras: extras
            ),
            generation: isLegacy ? .legacy : .current,
            dropped: dropped,
            droppedBytes: droppedBytes,
            unreadable: unreadable
        )
    }

    /// Strips the wrapping `*.textbundle/` so paths in `TextBundle.extras` are
    /// bundle-relative and rebuild into the same shape on the way out.
    func relativePath(of entry: ZipReader.Entry) -> String {
        guard !rootPrefix.isEmpty, entry.name.hasPrefix(rootPrefix) else { return entry.name }
        return String(entry.name.dropFirst(rootPrefix.count))
    }

    /// The single directory every member lives under, or `""` when there isn't
    /// one. The root name does not have to match the filename — `Anal Informant
    /// - 3.25.highland` wraps `Anal Informant - 3.textbundle/`, Highland having
    /// truncated at the last dot — so it is derived, never assumed.
    static func rootPrefix(for entries: [ZipReader.Entry]) -> String {
        var root: String?
        for entry in entries {
            guard let slash = entry.name.firstIndex(of: "/") else { return "" }
            let head = String(entry.name[...slash])
            if let root, root != head { return "" }
            root = head
        }
        return root ?? ""
    }

    /// `text.fountain` wins over `text.md` when a bundle somehow holds both.
    private static func prefers(_ candidate: String, over current: String?) -> Bool {
        guard let current else { return true }
        let order = ["text.fountain", "text.md", "text.markdown", "text.txt"]
        let new = order.firstIndex(of: candidate) ?? order.count
        let old = order.firstIndex(of: current) ?? order.count
        return new < old
    }

    // MARK: - info.json

    private static func object(from data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// Keeps Highland's `info.json` intact — including the whole
    /// `com.quoteunquoteapps.highland2` payload, unread and unmodified — and
    /// adds our namespace beside it. Anything we do not understand survives a
    /// round trip through this app, which is the same courtesy we want from the
    /// next tool to touch the file.
    static func info(merging highland: [String: Any], settings: [String: Any]) -> Data {
        var info = highland
        info["version"] = info["version"] ?? 2
        info["type"] = TextBundle.uti
        info["transient"] = info["transient"] ?? false
        info[TextBundle.settingsNamespace] = settings
        return (try? JSONSerialization.data(
            withJSONObject: info,
            options: [.prettyPrinted, .sortedKeys]
        )) ?? TextBundle.defaultInfoData()
    }

    /// Highland records the same print flags in up to three places, added in
    /// successive versions of the app. Read all of them, lowest confidence
    /// first, so the most recent wins:
    ///
    /// 1. `info.json` → `com.quoteunquoteapps.highland2`, loose at the top.
    /// 2. `info.json` → …`.printOptions` (37 bundles have only this).
    /// 3. `resources/settings.json` → `printSettings` (21 bundles have this).
    ///
    /// Only flags actually found are written. A missing flag means "our
    /// default", never an invented one — notably `printSections`, which is off
    /// in Highland by default and is why the six Trophy Boyz episodes' sections
    /// vanish from Highland's own PDFs.
    static func settings(from info: [String: Any], resources: [[String: Any]]) -> [String: Any] {
        var settings: [String: Any] = [
            "version": 1,
            "importedFrom": highlandNamespace
        ]
        // `type` is rewritten to ours on the way out; note what it was. Two
        // bundles in the library declare `net.daringfireball.markdown` rather
        // than `com.quoteunquoteapps.fountain`.
        if let type = info["type"] as? String { settings["importedType"] = type }
        let highland = info[highlandNamespace] as? [String: Any] ?? [:]

        var layers: [[String: Any]] = [highland]
        if let options = highland["printOptions"] as? [String: Any] { layers.append(options) }
        for resource in resources {
            if let print = resource["printSettings"] as? [String: Any] { layers.append(print) }
        }

        for layer in layers {
            for key in mappedPrintSettings where layer[key] is Bool {
                settings[key] = layer[key]
            }
        }

        // `templateName` means two different things under the same name. In
        // `info.json` it is the document template — Screenplay (49 bundles),
        // Graphic Novel (7), Treatment, Novel. In `printSettings` it is the
        // *print* template, and is "Default" or absent in every bundle in the
        // library. Only the first is worth carrying.
        if let template = highland["templateName"] as? String, !template.isEmpty {
            settings["template"] = template
        }
        return settings
    }
}

public enum HighlandImportError: LocalizedError, Equatable {
    case missingPayload
    case unreadablePayload(String, String)

    public var errorDescription: String? {
        switch self {
        case .missingPayload:
            return "That Highland document has no text.fountain or text.md inside it."
        case .unreadablePayload(let name, let reason):
            return "That Highland document’s “\(name)” couldn’t be read: \(reason)"
        }
    }
}
