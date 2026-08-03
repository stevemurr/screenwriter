import Foundation

/// A TextBundle: a folder holding a plain-text payload plus sidecar files.
///
/// Our `.screenplay` format is the **uncompressed** variant of this standard.
/// That is the whole design: `.highland` is opaque to git, grep and Syncthing
/// precisely *because* it is the compressed variant. Uncompressed gets both
/// properties at once — Finder shows one document, while every tool sees plain
/// text files that diff line by line.
///
/// Everything not understood is preserved verbatim in `extras` and written back
/// untouched, so a bundle can round-trip through this app without losing state
/// belonging to another one.
public struct TextBundle: Sendable {
    /// The screenplay text.
    public var text: String
    /// The payload's filename. Highland's newer bundles use `text.fountain` and
    /// its older ones use `text.md`; both appear in the reference library (39
    /// and 19 respectively), and a bundle is written back under the name it
    /// arrived with.
    public var textFileName: String
    /// Raw `info.json`, preserved byte-for-byte when it is not being modified.
    public var infoData: Data?
    /// Every other file in the bundle, keyed by path relative to its root.
    public var extras: [String: Data]

    public static let defaultTextFileName = "text.fountain"
    public static let infoFileName = "info.json"
    /// Our namespace inside `info.json`, mirroring how Highland namespaces its
    /// own settings under `com.quoteunquoteapps.highland2`.
    public static let settingsNamespace = "com.stevemurr.screenwriter"
    public static let uti = "com.stevemurr.screenwriter.fountain"

    public init(
        text: String,
        textFileName: String = TextBundle.defaultTextFileName,
        infoData: Data? = nil,
        extras: [String: Data] = [:]
    ) {
        self.text = text
        self.textFileName = textFileName
        self.infoData = infoData
        self.extras = extras
    }

    // MARK: - Reading

    /// Reads an uncompressed bundle from a directory `FileWrapper`.
    public init(directory wrapper: FileWrapper) throws {
        guard wrapper.isDirectory, let children = wrapper.fileWrappers else {
            throw TextBundleError.notADirectory
        }
        var text: String?
        var textName = TextBundle.defaultTextFileName
        var info: Data?
        var extras: [String: Data] = [:]

        for (name, child) in children {
            if name == TextBundle.infoFileName {
                info = child.regularFileContents
                continue
            }
            if TextBundle.isPayloadName(name), let data = child.regularFileContents {
                text = TextBundle.decode(data)
                textName = name
                continue
            }
            TextBundle.collect(child, at: name, into: &extras)
        }

        guard let text else { throw TextBundleError.missingPayload }
        self.init(text: text, textFileName: textName, infoData: info, extras: extras)
    }

    /// Flattens nested directories into path-keyed entries so they can be
    /// rebuilt exactly.
    private static func collect(_ wrapper: FileWrapper, at path: String, into extras: inout [String: Data]) {
        if wrapper.isDirectory {
            for (name, child) in wrapper.fileWrappers ?? [:] {
                collect(child, at: "\(path)/\(name)", into: &extras)
            }
        } else if let data = wrapper.regularFileContents {
            extras[path] = data
        }
    }

    public static func isPayloadName(_ name: String) -> Bool {
        ["text.fountain", "text.md", "text.markdown", "text.txt"].contains(name)
    }

    /// UTF-8, falling back to UTF-16 and then Latin-1 rather than failing.
    /// The corpus is UTF-8 throughout — smart quotes, em dashes, en dashes —
    /// but a screenplay is never worth refusing to open over an encoding guess.
    public static func decode(_ data: Data) -> String {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        if let utf16 = String(data: data, encoding: .utf16) { return utf16 }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Writing

    /// Builds a directory `FileWrapper` for the whole bundle.
    public func directoryWrapper() throws -> FileWrapper {
        var children: [String: FileWrapper] = [:]
        children[textFileName] = FileWrapper(regularFileWithContents: Data(text.utf8))
        children[TextBundle.infoFileName] = FileWrapper(
            regularFileWithContents: infoData ?? TextBundle.defaultInfoData()
        )

        // Rebuild nested paths, so a bundle carrying `assets/poster.png` keeps
        // its shape rather than being flattened into a file with a slash in it.
        for (path, data) in extras {
            var components = path.split(separator: "/").map(String.init)
            guard let filename = components.popLast() else { continue }
            var container = children
            insert(
                FileWrapper(regularFileWithContents: data),
                named: filename,
                path: components,
                into: &container
            )
            children = container
        }
        return FileWrapper(directoryWithFileWrappers: children)
    }

    private func insert(
        _ wrapper: FileWrapper,
        named name: String,
        path: [String],
        into children: inout [String: FileWrapper]
    ) {
        guard let head = path.first else {
            wrapper.preferredFilename = name
            children[name] = wrapper
            return
        }
        var nested = children[head]?.fileWrappers ?? [:]
        insert(wrapper, named: name, path: Array(path.dropFirst()), into: &nested)
        let directory = FileWrapper(directoryWithFileWrappers: nested)
        directory.preferredFilename = head
        children[head] = directory
    }

    public static func defaultInfoData() -> Data {
        let info: [String: Any] = [
            "version": 2,
            "type": TextBundle.uti,
            "transient": false,
            TextBundle.settingsNamespace: ["version": 1]
        ]
        return (try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]))
            ?? Data("{\"version\":2}".utf8)
    }
}

public enum TextBundleError: LocalizedError {
    case notADirectory
    case missingPayload

    public var errorDescription: String? {
        switch self {
        case .notADirectory:
            return "That screenplay bundle isn’t a folder."
        case .missingPayload:
            return "That screenplay bundle has no text file inside it."
        }
    }
}
