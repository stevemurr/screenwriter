import Foundation

extension ScriptParser {
    /// Keys that may *open* a title page.
    ///
    /// This gate is load-bearing. `CUT TO:` appears 48 times in the reference
    /// corpus, and `CLOSE ON:`, `TITLE CARD:`, `On screen:`, `WIDER:`, `TODO:`
    /// and `Through the crack:` all appear too — every one of them matches a
    /// naive `^[A-Z][A-Za-z ]*:` key pattern. Requiring the *first* key to come
    /// from a known vocabulary means a script opening on a transition can never
    /// be swallowed as front matter. Once a title page is established, any
    /// custom key is accepted, so unusual keys still round-trip.
    static let titlePageOpeningKeys: Set<String> = [
        "title", "credit", "author", "authors", "source", "notes",
        "draft date", "date", "contact", "copyright", "revision",
        "format", "episode", "series"
    ]

    /// Parses the `Title:` block, which exists only at the head of the document
    /// and ends at the first blank line.
    ///
    /// Returns `nil` when there is no title page — the common case. Only 7 of
    /// the 17 screenplays in the reference corpus have one, so this must never
    /// be inferred from a document that merely opens with a colon.
    static func parseTitlePage(_ index: LineIndex) -> TitlePage? {
        // `Pixelate` opens with a blank line before `Title:`, so leading blanks
        // are skipped rather than treated as "no title page".
        var line = 0
        while line < index.count, index[line].isBlank { line += 1 }
        guard line < index.count else { return nil }

        guard let opening = splitKeyValue(index[line].trimmedRight),
              titlePageOpeningKeys.contains(opening.key.lowercased())
        else { return nil }

        var entries: [TitlePage.Entry] = []
        // Where the block actually begins. `Pixelate` opens with a blank line
        // before `Title:`, and the range must not swallow it — rewriting the
        // block from the structured inspector replaces exactly this range, and
        // eating a leading blank would silently edit the user's file.
        let firstKeyLine = line
        var lastLine = line

        while line < index.count, !index[line].isBlank {
            let text = index[line].text
            let trimmed = index[line].trimmedRight

            if let pair = splitKeyValue(trimmed) {
                entries.append(
                    TitlePage.Entry(
                        key: pair.key,
                        values: pair.value.isEmpty ? [] : [pair.value],
                        isIndented: pair.value.isEmpty
                    )
                )
            } else if !entries.isEmpty {
                // A continuation line. The author's exact indentation is kept so
                // a rewrite reproduces their four spaces or tab rather than
                // imposing one of ours.
                let indent = String(text.prefix { $0 == " " || $0 == "\t" })
                var entry = entries.removeLast()
                if entry.values.isEmpty { entry.isIndented = true }
                if !indent.isEmpty { entry.indent = indent }
                entry.values.append(trimmed.trimmingCharacters(in: .whitespaces))
                entries.append(entry)
            }

            lastLine = line
            line += 1
        }

        guard !entries.isEmpty else { return nil }

        let start = index[firstKeyLine].range.location
        let end = index[lastLine].rangeWithTerminator
        return TitlePage(
            entries: entries,
            range: NSRange(location: start, length: end.location + end.length - start)
        )
    }

    /// The first source line after the title-page block.
    static func firstLine(after titlePage: TitlePage, in index: LineIndex) -> Int {
        let end = titlePage.range.location + titlePage.range.length
        guard end < (index.lineStarts.last ?? 0) + 1 || end > 0 else { return 0 }
        var line = 0
        while line < index.count, index[line].range.location < end { line += 1 }
        return line
    }

    /// Splits `Key: value`, requiring the key to be a plain identifier-ish run.
    ///
    /// Rejects a leading indent, so a continuation line that happens to contain
    /// a colon is not mistaken for a new key.
    static func splitKeyValue(_ text: String) -> (key: String, value: String)? {
        guard let first = text.first, first != " ", first != "\t" else { return nil }
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let key = String(text[text.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, key.count <= 40 else { return nil }
        // Letters, spaces, and simple separators only — a key is a label, never
        // a sentence.
        guard key.allSatisfy({ $0.isLetter || $0 == " " || $0 == "-" || $0 == "_" }) else {
            return nil
        }
        let value = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        return (key, value)
    }
}

extension TitlePage {
    /// Sets a key's value, preserving the entry's position and style.
    ///
    /// A new key is appended rather than inserted, because there is no
    /// meaningful place to put it in someone else's ordering. Setting a value to
    /// empty removes the entry — an empty `Author:` line is worse than none.
    public mutating func setValue(_ value: String, for key: String) {
        let index = entries.firstIndex { $0.key.caseInsensitiveCompare(key) == .orderedSame }
        let lines = value.components(separatedBy: "\n").filter { !$0.isEmpty }

        guard !lines.isEmpty else {
            if let index { entries.remove(at: index) }
            return
        }
        if let index {
            // Keep the author's own key spelling and indentation. `Date:` stays
            // `Date:` rather than being normalised to `Draft Date:`.
            entries[index].values = lines
            if lines.count > 1 { entries[index].isIndented = true }
        } else {
            entries.append(
                TitlePage.Entry(key: key, values: lines, isIndented: lines.count > 1)
            )
        }
    }

    /// Writes this title page back into `source`, replacing the existing block
    /// or inserting one at the top if the document has none.
    ///
    /// Only `range` is replaced, so everything else in the document — including
    /// any blank line the author left above `Title:` — is untouched.
    public func applied(to source: String, existing: TitlePage?) -> String {
        let text = serialized()
        let ns = source as NSString

        guard let existing else {
            guard !text.isEmpty else { return source }
            // A title page must be followed by a blank line, or the first line
            // of the script would be read as another key.
            return text + "\n\n" + source
        }

        guard !text.isEmpty else {
            // Removing the block takes its trailing blank line with it, so the
            // document does not accumulate empty space at the top.
            var cut = existing.range
            while NSMaxRange(cut) < ns.length,
                  ns.character(at: NSMaxRange(cut)) == 0x0A {
                cut.length += 1
            }
            return ns.replacingCharacters(in: cut, with: "")
        }
        // `range` covers the block's final line terminator, and `serialized()`
        // does not emit one. Without restoring it the blank line that *ends* the
        // title page disappears, and the first line of the script silently
        // becomes another continuation value.
        return ns.replacingCharacters(in: existing.range, with: text + "\n")
    }

    /// Serialises back to Fountain, preserving key order, inline-versus-indented
    /// style, and each entry's original indentation.
    public func serialized() -> String {
        var lines: [String] = []
        for entry in entries {
            if entry.isIndented || entry.values.count > 1 {
                lines.append("\(entry.key):")
                for value in entry.values { lines.append("\(entry.indent)\(value)") }
            } else {
                lines.append("\(entry.key): \(entry.values.first ?? "")")
            }
        }
        return lines.joined(separator: "\n")
    }
}
