import Foundation

/// The `Title:` block at the head of a document.
///
/// Round-tripping is the whole job here. The structured inspector in the app
/// edits the same block the user can edit as raw text, so this model preserves
/// everything a naive `[String: String]` would throw away: **key order**, the
/// exact indentation of continued values, unknown custom keys, and inline
/// `_**BOLD UNDERLINE**_` emphasis (left in the value verbatim).
///
/// Only 7 of the 17 screenplays in the reference corpus have a title page at
/// all, so `ParsedScript.titlePage` is optional and must never be inferred.
public struct TitlePage: Sendable, Hashable {
    /// One `Key: value` entry, preserving how it was written.
    public struct Entry: Sendable, Hashable {
        /// The key exactly as written, without the colon — `Draft Date`, `Date`,
        /// `Copyright`. The corpus uses `Date:` more often than `Draft Date:`,
        /// so neither is canonical and neither may be rewritten.
        public var key: String
        /// The value, one element per source line. An inline value is a single
        /// element; an indented block is one per continuation line.
        public var values: [String]
        /// True when the value sits on following indented lines rather than
        /// after the colon on the key line.
        public var isIndented: Bool
        /// The exact leading whitespace of continuation lines, so a rewrite
        /// reproduces the author's four spaces or tab rather than imposing one.
        public var indent: String

        public init(key: String, values: [String], isIndented: Bool, indent: String = "    ") {
            self.key = key
            self.values = values
            self.isIndented = isIndented
            self.indent = indent
        }

        /// The value as a single string, newline-joined.
        public var joinedValue: String { values.joined(separator: "\n") }
    }

    /// Entries in source order. Order is preserved on write.
    public var entries: [Entry]
    /// UTF-16 range of the whole block in the source, including any blank lines
    /// that preceded it (`Pixelate` opens with one) but not the blank line that
    /// terminates it.
    public var range: NSRange

    public init(entries: [Entry] = [], range: NSRange = NSRange(location: 0, length: 0)) {
        self.entries = entries
        self.range = range
    }

    /// Case-insensitive lookup, since the corpus is inconsistent about casing.
    public func value(for key: String) -> String? {
        entries.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.joinedValue
    }

    public var title: String? { value(for: "Title") }
    public var credit: String? { value(for: "Credit") }
    public var author: String? { value(for: "Author") }
    public var source: String? { value(for: "Source") }
    public var contact: String? { value(for: "Contact") }
    public var copyright: String? { value(for: "Copyright") }
    /// The corpus writes this as both `Draft Date:` and `Date:`.
    public var draftDate: String? { value(for: "Draft Date") ?? value(for: "Date") }

    /// Keys the app's structured inspector shows as dedicated fields. Anything
    /// else the author wrote is still kept in `entries` and still written back.
    public static let wellKnownKeys = [
        "Title", "Credit", "Author", "Source", "Draft Date", "Date",
        "Contact", "Copyright", "Notes", "Revision"
    ]
}
