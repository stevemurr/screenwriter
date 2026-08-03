import AppKit
import FountainKit

/// Content read from disk, before it reaches the main actor.
private struct LoadedScreenplay: Sendable {
    var text: String
    var textFileName: String
    var infoData: Data?
    var extras: [String: Data]
}

/// Hand-off between `read(from:ofType:)`, which AppKit may call on a background
/// queue, and the main actor where the model lives.
private final class LoadedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: LoadedScreenplay?

    func set(_ loaded: LoadedScreenplay) {
        lock.lock()
        defer { lock.unlock() }
        value = loaded
    }

    func take() -> LoadedScreenplay? {
        lock.lock()
        defer { lock.unlock() }
        let taken = value
        value = nil
        return taken
    }
}

/// An open screenplay.
///
/// `NSDocument` rather than SwiftUI's `DocumentGroup`: the app needs the
/// document's `fileURL` to place a metadata sidecar beside a bare `.fountain`,
/// needs to read and write `.screenplay` as a package, and gets autosave-in-
/// place, Versions, and Revert to Saved for free — all of which `FileDocument`
/// either hides or would have to reimplement.
@MainActor
final class ScreenplayDocument: NSDocument {
    let model = ScreenplayModel()
    private nonisolated let pending = LoadedBox()

    enum DocumentType: String {
        case fountain = "com.stevemurr.screenwriter.fountain"
        case package = "com.stevemurr.screenwriter.package"
        case highland = "com.quoteunquoteapps.highland"
    }

    override class var autosavesInPlace: Bool { true }

    // MARK: - Reading

    /// AppKit may call this on a background queue, so it only decodes — the
    /// result is installed on the main actor by `makeWindowControllers` or
    /// `revert`.
    nonisolated override func read(from url: URL, ofType typeName: String) throws {
        pending.set(try Self.load(from: url, ofType: typeName))
    }

    private nonisolated static func load(from url: URL, ofType typeName: String) throws -> LoadedScreenplay {
        switch DocumentType(rawValue: typeName) {
        case .package:
            let bundle = try TextBundle(directory: FileWrapper(url: url))
            return LoadedScreenplay(
                text: bundle.text,
                textFileName: bundle.textFileName,
                infoData: bundle.infoData,
                extras: bundle.extras
            )

        case .highland:
            // Read-only by design, and not wired up until M2. Failing loudly
            // beats a half-open document that cannot be saved anywhere sensible.
            throw ScreenplayDocumentError.highlandImportNotAvailable

        case .fountain, .none:
            let data = try Data(contentsOf: url)
            return LoadedScreenplay(
                text: TextBundle.decode(data),
                textFileName: url.lastPathComponent,
                infoData: nil,
                extras: [:]
            )
        }
    }

    private func installPendingIfNeeded() {
        guard let loaded = pending.take() else { return }
        model.load(loaded.text)
        model.textFileName = loaded.textFileName
        model.bundleInfoData = loaded.infoData
        model.bundleExtras = loaded.extras
        undoManager?.removeAllActions()
    }

    override func revert(toContentsOf url: URL, ofType typeName: String) throws {
        try super.revert(toContentsOf: url, ofType: typeName)
        installPendingIfNeeded()
    }

    // MARK: - Writing

    /// Writing stays on the main thread, which is what lets `fileWrapper` read
    /// the model directly. Enforced rather than assumed.
    nonisolated override func canAsynchronouslyWrite(
        to url: URL,
        ofType typeName: String,
        for saveOperation: NSDocument.SaveOperationType
    ) -> Bool {
        false
    }

    nonisolated override func fileWrapper(ofType typeName: String) throws -> FileWrapper {
        try MainActor.assumeIsolated {
            switch DocumentType(rawValue: typeName) {
            case .package:
                let bundle = TextBundle(
                    text: model.text,
                    textFileName: model.textFileName,
                    infoData: model.bundleInfoData,
                    extras: model.bundleExtras
                )
                return try bundle.directoryWrapper()

            case .highland:
                // The reference library holds 59 of these and they are
                // irreplaceable. The app never opens one for writing.
                throw ScreenplayDocumentError.highlandIsReadOnly

            case .fountain, .none:
                return FileWrapper(regularFileWithContents: Data(model.text.utf8))
            }
        }
    }

    // MARK: - Windows

    override func makeWindowControllers() {
        installPendingIfNeeded()
        addWindowController(DocumentWindowController(document: self))
    }

    /// The document is dirtied by the model's text changing, which happens
    /// through the SwiftUI binding rather than through `NSTextView`'s own undo
    /// registration reaching `NSDocument`.
    func noteTextEdited() {
        updateChangeCount(.changeDone)
    }
}

enum ScreenplayDocumentError: LocalizedError {
    case highlandIsReadOnly
    case highlandImportNotAvailable

    var errorDescription: String? {
        switch self {
        case .highlandIsReadOnly:
            return "Highland documents are opened read-only."
        case .highlandImportNotAvailable:
            return "Importing Highland documents isn’t available yet."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .highlandIsReadOnly:
            return "Save this screenplay as a Screenplay or Fountain document instead. "
                + "The original .highland file is never modified."
        case .highlandImportNotAvailable:
            return "Export the script from Highland as Fountain and open that."
        }
    }
}
