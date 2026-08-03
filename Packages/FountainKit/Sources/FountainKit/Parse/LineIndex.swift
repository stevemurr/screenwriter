import Foundation

/// The source split into lines, with UTF-16 ranges.
///
/// UTF-16 throughout, deliberately: these ranges are handed straight to
/// `NSTextStorage` and `NSRange` without conversion. The corpus is full of
/// smart quotes, em dashes and en dashes, so a `String.Index`-based index would
/// need converting at every boundary.
public struct LineIndex: Sendable {
    public struct Line: Sendable, Hashable {
        /// Zero-based line number.
        public var index: Int
        /// Range of the line's text, excluding its terminator.
        public var range: NSRange
        /// Range including the trailing newline, if the line has one.
        public var rangeWithTerminator: NSRange
        /// The line's text without its terminator.
        public var text: String

        /// True when the line is empty or nothing but whitespace.
        ///
        /// Whitespace-only counts as blank because Fountain's structure hangs
        /// on blank-line separation and the corpus has 302 lines ending in a
        /// stray double space. Treating those as non-blank would silently
        /// reclassify the cues that follow them.
        ///
        /// Stored, not computed: classification asks about each line's own
        /// blankness and both its neighbours', so a computed property was
        /// walking every line's graphemes roughly three times over.
        public let isBlank: Bool

        init(index: Int, range: NSRange, rangeWithTerminator: NSRange, text: String) {
            self.index = index
            self.range = range
            self.rangeWithTerminator = rangeWithTerminator
            self.text = text
            self.isBlank = Line.isAllWhitespace(text)
        }

        /// UTF-8 rather than `Character`, which would pay for grapheme breaking
        /// on every line of the document.
        private static func isAllWhitespace(_ text: String) -> Bool {
            for byte in text.utf8 where byte != 0x20 && byte != 0x09 && byte != 0x0D {
                return false
            }
            return true
        }

        /// The text with trailing whitespace removed — what classification runs
        /// against. The raw `text` is retained for byte-exact round-tripping.
        public var trimmedRight: String {
            var scalars = Substring(text)
            while let last = scalars.last, last.isWhitespace { scalars = scalars.dropLast() }
            return String(scalars)
        }
    }

    public let lines: [Line]
    /// UTF-16 offset of the start of each line. Binary-searched to map an
    /// offset back to a line without rescanning.
    public let lineStarts: [Int]

    public init(source: String) {
        let ns = source as NSString
        var lines: [Line] = []
        var starts: [Int] = []
        var lineStart = 0
        var index = 0
        let length = ns.length

        while index < length {
            if ns.character(at: index) == 0x0A {
                starts.append(lineStart)
                let textRange = NSRange(location: lineStart, length: index - lineStart)
                lines.append(
                    Line(
                        index: lines.count,
                        range: textRange,
                        rangeWithTerminator: NSRange(
                            location: lineStart,
                            length: index - lineStart + 1
                        ),
                        text: ns.substring(with: textRange)
                    )
                )
                lineStart = index + 1
            }
            index += 1
        }

        // A trailing segment with no newline is still a line. A document ending
        // in "\n" does not get a phantom empty line here; the caret sits on one
        // visually, which is the ruler's concern, not the parser's.
        if lineStart < length || lines.isEmpty {
            starts.append(lineStart)
            let textRange = NSRange(location: lineStart, length: length - lineStart)
            lines.append(
                Line(
                    index: lines.count,
                    range: textRange,
                    rangeWithTerminator: textRange,
                    text: ns.substring(with: textRange)
                )
            )
        }

        self.lines = lines
        self.lineStarts = starts
    }

    public var count: Int { lines.count }

    public subscript(index: Int) -> Line { lines[index] }

    /// The line containing a UTF-16 offset. O(log n).
    public func lineNumber(containing offset: Int) -> Int {
        guard !lineStarts.isEmpty else { return 0 }
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= offset { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// Whether the line before `index` is blank. Treats the start of the
    /// document as blank, which is what makes the first line of a script
    /// eligible to be a character cue or scene heading.
    public func isPrecededByBlank(_ index: Int) -> Bool {
        index == 0 || lines[index - 1].isBlank
    }

    /// Whether the line after `index` exists and is non-blank.
    public func isFollowedByContent(_ index: Int) -> Bool {
        index + 1 < lines.count && !lines[index + 1].isBlank
    }
}
