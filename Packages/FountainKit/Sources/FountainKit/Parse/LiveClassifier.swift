import Foundation

/// Classifies the handful of lines around an edit, so the editor can style text
/// *as it is typed* rather than after the debounced full parse lands.
///
/// ## Why this can exist at all
/// Fountain looks context-sensitive, and it is — but its context is bounded.
/// A line's classification depends on its own text, whether its neighbours are
/// blank, and the kind of the line before it. That last dependency is the only
/// unbounded-looking one, and it terminates at a blank line: after a blank,
/// `previous` is `.blank`, which matches none of the continuation branches in
/// `ScriptParser.classifyUnforced`. So re-classifying from the start of the
/// edited block reproduces exactly what a full parse would say about it.
///
/// ## What it deliberately does not handle
/// Two constructs are *not* bounded by a blank line, and both are refused rather
/// than guessed at:
///
/// * **Boneyard.** `/* … */` spans blank lines, so a window has no way to know
///   it is inside one. The caller disables live classification for any document
///   whose last full parse contained a boneyard.
/// * **The title page.** It is only parsed at the head of the document (Rule 7),
///   and `CUT TO:` would otherwise read as a title-page key. The caller refuses
///   any window that reaches the head.
///
/// In both cases the editor falls back to what it did before: the debounced
/// parse styles the text a moment later. Correctness is never traded for
/// immediacy — only latency is.
public enum LiveClassifier {

    /// Everything except space, tab, and carriage return — the inverse of what
    /// `LineIndex.Line.isBlank` accepts, so the two agree on what a blank line
    /// is. They must: the window boundaries are blank lines, and a disagreement
    /// would put the window in a different place than the parser's block.
    private static let content = CharacterSet(charactersIn: " \t\r").inverted

    /// The range of full lines that has to be re-classified when `edited`
    /// changes, or nil when the edit cannot be resolved locally.
    ///
    /// Walks back to the start of the edited block and forward through the next
    /// one. Forward needs the extra block because inserting a blank line
    /// *splits* a block: the lines below the new blank stop being dialogue and
    /// become action, and they are past the first blank line the walk meets.
    ///
    /// `limit` bounds both walks. A document with no blank lines in it at all —
    /// a pasted wall of prose — would otherwise make every keystroke walk to the
    /// ends of the file, which is the cost this whole path exists to avoid.
    /// Refusing is correct there; the debounced parse still runs.
    public static func window(
        for edited: NSRange,
        in source: NSString,
        limit: Int = 8_192
    ) -> NSRange? {
        let length = source.length
        guard length > 0 else { return nil }

        let location = min(max(edited.location, 0), length)
        let clamped = NSRange(
            location: location,
            length: min(max(edited.length, 0), length - location)
        )
        let seed = source.lineRange(for: clamped)

        var start = seed.location
        while start > 0 {
            let previous = source.lineRange(for: NSRange(location: start - 1, length: 0))
            if isBlank(previous, in: source) { break }
            start = previous.location
            if seed.location - start > limit { return nil }
        }

        var end = NSMaxRange(seed)
        var blankRuns = 0
        var previousWasBlank = false
        while end < length, blankRuns < 2 {
            let next = source.lineRange(for: NSRange(location: end, length: 0))
            let blank = isBlank(next, in: source)
            end = NSMaxRange(next)
            if blank, !previousWasBlank { blankRuns += 1 }
            previousWasBlank = blank
            if end - start > limit { return nil }
        }

        guard end > start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    /// Classifies `window` — which must be a full-line range, as returned by
    /// `window(for:in:)` — and returns elements whose ranges are absolute in the
    /// document, not relative to the window.
    ///
    /// Runs the identical `ScriptParser.classify` the full pass runs. Anything
    /// that made this a second implementation of the rules would be a second
    /// thing to keep in agreement, and the two disagreeing is precisely the
    /// flicker this is meant to remove.
    public static func classify(_ window: NSRange, in source: NSString) -> [Element] {
        let index = LineIndex(source: source.substring(with: window))
        var elements: [Element] = []
        elements.reserveCapacity(index.count)

        for number in 0..<index.count {
            let line = index[number]
            if line.isBlank {
                elements.append(ScriptParser.make(.blank, line, text: ""))
            } else {
                elements.append(
                    ScriptParser.classify(
                        line.trimmedRight,
                        line: line,
                        index: index,
                        previous: elements.last?.kind
                    )
                )
            }
        }

        for position in elements.indices {
            elements[position].range.location += window.location
        }
        return elements
    }

    /// Whether the first line of `window` could open a title page.
    ///
    /// Rule 7 again, from the other side. `titlePageEnd` refuses a window that
    /// overlaps a title page the parser has *already* found, but a writer typing
    /// `Title:` onto the first line of a document is creating one the last parse
    /// has never seen. Live classification would call that line action; the next
    /// full parse will call it a title page. Refuse it and let the parse decide.
    public static func couldOpenTitlePage(_ window: NSRange, in source: NSString) -> Bool {
        guard window.location == 0, source.length > 0 else { return false }
        let first = source.lineRange(for: NSRange(location: 0, length: 0))
        var contentsEnd = 0
        source.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: first)
        let text = source.substring(with: NSRange(location: 0, length: contentsEnd))
        guard let split = ScriptParser.splitKeyValue(text) else { return false }
        return ScriptParser.titlePageOpeningKeys.contains(split.key.lowercased())
    }

    private static func isBlank(_ line: NSRange, in source: NSString) -> Bool {
        var contentsEnd = 0
        source.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: line)
        let text = NSRange(location: line.location, length: contentsEnd - line.location)
        guard text.length > 0 else { return true }
        return source.rangeOfCharacter(from: content, options: [], range: text).location == NSNotFound
    }
}
