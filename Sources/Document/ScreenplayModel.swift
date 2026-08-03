import Foundation
import FountainKit
import Observation

/// The live state of one open screenplay.
///
/// Reference type, held by `ScreenplayDocument`. A value-typed `FileDocument`
/// would copy this string and its parse tree on every keystroke; at 91 KB —
/// the largest script in the reference library — that is not a trade worth
/// making.
@MainActor
@Observable
public final class ScreenplayModel {
    /// The source of truth. Everything else is derived.
    public var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            scheduleReparse()
        }
    }

    private var parseTask: Task<Void, Never>?

    /// How long typing must pause before a reparse runs. Long enough to coalesce
    /// a burst of keystrokes, short enough that the outline and preview still
    /// feel attached to the text.
    private static let debounce = Duration.milliseconds(120)

    public private(set) var script: ParsedScript = .empty
    /// Non-blocking advice about the document. Computed alongside the parse and
    /// off the same actor, because the two always have to agree about ranges.
    public private(set) var diagnostics: [Diagnostic] = []
    public var showsDiagnostics = false
    /// Bumped on every reparse so the editor surface knows the styling is stale.
    public private(set) var revision: UInt64 = 0
    /// Bumped only when the text is replaced from outside — a file load or a
    /// revert — never by a user edit.
    public private(set) var replacementToken: UInt64 = 0

    public var mode: EditorMode = .plainText
    public var showsPreview = true
    public var showsOutline = true

    /// The payload filename to write back under, so a bundle that arrived as
    /// `text.md` is not silently renamed.
    public var textFileName: String = TextBundle.defaultTextFileName
    /// Sidecar files from an opened bundle, preserved untouched on write.
    public var bundleExtras: [String: Data] = [:]
    public var bundleInfoData: Data?

    public init() {}

    /// Installs text that came from disk rather than from the user.
    ///
    /// Parses synchronously: a document must open with its outline already
    /// populated, and the cost is paid once rather than per keystroke.
    public func load(_ source: String) {
        text = source
        parseTask?.cancel()
        applyParse(ScriptParser.parse(source), for: source)
        replacementToken &+= 1
    }

    /// Reparses off the main actor after typing pauses.
    ///
    /// Measured at ~15ms for the largest script in the reference library
    /// (91 KB), which is close enough to a 60Hz frame that doing it inline on
    /// every keystroke would drop frames. It is therefore debounced *and* run
    /// off the main actor — the editor surface already tolerates a parse result
    /// arriving a moment after the text, because it re-checks that the text view
    /// still holds the source a result was computed from before applying it.
    private func scheduleReparse() {
        parseTask?.cancel()
        let source = text
        parseTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            let parsed = await Task.detached(priority: .userInitiated) {
                ScriptParser.parse(source)
            }.value
            guard !Task.isCancelled else { return }
            self?.applyParse(parsed, for: source)
        }
    }

    private func applyParse(_ parsed: ParsedScript, for source: String) {
        // Discard a result the document has already moved past.
        guard text == source else { return }
        script = parsed
        diagnostics = Linter.lint(parsed)
        revision &+= 1
    }

    public var warningCount: Int { diagnostics.count { $0.severity == .warning } }
    public var suggestionCount: Int { diagnostics.count { $0.severity == .suggestion } }

    /// Applies a diagnostic's suggested fix.
    ///
    /// Re-lints synchronously first: the fix is a range into a specific parse,
    /// and applying it against a document that has moved on would corrupt text
    /// rather than repair it.
    public func applyFix(_ diagnostic: Diagnostic) {
        reparseNow()
        guard let current = diagnostics.first(where: { $0.id == diagnostic.id }),
              current.isFixable
        else { return }
        text = current.applied(to: text)
        reparseNow()
    }

    /// Forces any pending reparse to complete now. For tests and for anything
    /// that must act on a current parse, such as export.
    public func reparseNow() {
        parseTask?.cancel()
        applyParse(ScriptParser.parse(text), for: text)
    }

    // MARK: - Derived, for the status bar and sidebar

    public var pageCountEstimate: Int {
        // A real paginator lands in M5. Until then the status bar shows an
        // honest estimate from the line count rather than a fabricated number.
        max(1, Int((Double(script.elements.count) / 55.0).rounded(.up)))
    }

    public var sceneCount: Int { script.scenes.count }
    public var characterCount: Int { script.characters.count }
    public var wordCount: Int { script.wordCount }
}
