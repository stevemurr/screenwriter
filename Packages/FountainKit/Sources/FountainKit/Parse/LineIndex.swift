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
        ///
        /// The overwhelming case is a line with nothing to trim, and that is
        /// decided from the last UTF-8 byte. `Character.isWhitespace` reads the
        /// Unicode property tables and `scalars.last` walks a grapheme cluster
        /// backwards, so the old unconditional loop paid both on every line of
        /// the document to discover that only **82 of 3,608** lines in the 91 KB
        /// script actually needed trimming. 2,115 lines take the gate below;
        /// 1,343 are empty and fall through to a loop that exits immediately.
        /// Over the whole index: 1.27ms → 0.11ms.
        ///
        /// The gate is deliberately conservative: any byte over 0x7F, and every
        /// ASCII whitespace byte, takes the general path. A grapheme cluster
        /// whose *first* scalar is whitespace — which is what
        /// `Character.isWhitespace` actually tests — can only end in an ASCII
        /// byte via `\r\n`, and `\n` is in the excluded set.
        public var trimmedRight: String {
            if let last = text.utf8.last, last < 0x80,
               last != 0x20, last != 0x09, last != 0x0A,
               last != 0x0B, last != 0x0C, last != 0x0D {
                return text
            }
            var scalars = Substring(text)
            while let last = scalars.last, last.isWhitespace { scalars = scalars.dropLast() }
            return String(scalars)
        }
    }

    public let lines: [Line]
    /// UTF-16 offset of the start of each line. Binary-searched to map an
    /// offset back to a line without rescanning.
    public let lineStarts: [Int]

    /// Splits the source into lines by scanning its UTF-8 bytes.
    ///
    /// **Never build a line's text with `NSString.substring(with:)`.** That
    /// returns a lazily-bridged `__NSCFString`, and a `String` backed by one is
    /// *foreign* in the standard library's sense: it has no contiguous UTF-8
    /// buffer, so `.utf8`, `.first`, `hasPrefix` and every other access falls
    /// out to `-[__NSCFString characterAtIndex:]` through CoreFoundation, one
    /// Objective-C message per code unit. Measured on the 91 KB script, 2,265 of
    /// 3,608 lines were foreign — every non-blank one — and roughly 40% of total
    /// parse CPU was spent in CoreFoundation and `objc_msgSend` underneath
    /// `_StringGuts.foreign…` entry points. Rule 4 says to iterate `.utf8`
    /// rather than `Character`; that advice only buys anything on a *native*
    /// string, which is what `String(decoding:as:)` over raw bytes produces.
    ///
    /// Scanning bytes rather than `ns.character(at:)` removes the other half:
    /// that call is an `objc_msgSend` into `String.UTF16View._nativeGetIndex`
    /// for every code unit in the document.
    ///
    /// Ranges stay UTF-16 because they are handed to `NSTextStorage` unchanged,
    /// so the scan carries a UTF-16 counter alongside the byte offset: one unit
    /// per non-continuation byte, two for a four-byte sequence, which is a
    /// surrogate pair in UTF-16.
    public init(source: String) {
        // A native string already has the buffer; borrow it and copy nothing.
        if let scanned = source.utf8.withContiguousStorageIfAvailable({ LineIndex.scan($0) }) {
            (lines, lineStarts) = scanned
            return
        }
        // A foreign one has to be materialised once. `Array(source.utf8)` rather
        // than `String.makeContiguousUTF8()`, which is what `withUTF8` would
        // reach for: measured on the 91 KB script arriving from an
        // `NSTextStorage`, the array copy is 0.28ms and `makeContiguousUTF8` is
        // 2.08ms — a 7x difference for producing the identical bytes. This is
        // the path the running app takes, because `NSTextView.string` bridges to
        // a foreign `String`.
        let bytes = Array(source.utf8)
        (lines, lineStarts) = bytes.withUnsafeBufferPointer { LineIndex.scan($0) }
    }

    private static func scan(_ bytes: UnsafeBufferPointer<UInt8>) -> ([Line], [Int]) {
        var lines: [Line] = []
        var starts: [Int] = []
        let count = bytes.count
        // The corpus averages about 25 bytes a line; one guess beats a dozen
        // reallocations.
        lines.reserveCapacity(count / 24 + 1)
        starts.reserveCapacity(count / 24 + 1)

        var lineStartByte = 0
        var lineStartUTF16 = 0
        var utf16 = 0
        var offset = 0

        while offset < count {
            let byte = bytes[offset]
            if byte < 0x80 {
                if byte == 0x0A {
                    starts.append(lineStartUTF16)
                    let textRange = NSRange(
                        location: lineStartUTF16,
                        length: utf16 - lineStartUTF16
                    )
                    lines.append(
                        Line(
                            index: lines.count,
                            range: textRange,
                            rangeWithTerminator: NSRange(
                                location: lineStartUTF16,
                                length: textRange.length + 1
                            ),
                            text: text(bytes, lineStartByte, offset)
                        )
                    )
                    offset += 1
                    utf16 += 1
                    lineStartByte = offset
                    lineStartUTF16 = utf16
                    continue
                }
                utf16 += 1
            } else if byte >= 0xC0 {
                utf16 += byte >= 0xF0 ? 2 : 1
            }
            offset += 1
        }

        // A trailing segment with no newline is still a line. A document ending
        // in "\n" does not get a phantom empty line here; the caret sits on one
        // visually, which is the ruler's concern, not the parser's.
        if lineStartByte < count || lines.isEmpty {
            starts.append(lineStartUTF16)
            let textRange = NSRange(location: lineStartUTF16, length: utf16 - lineStartUTF16)
            lines.append(
                Line(
                    index: lines.count,
                    range: textRange,
                    rangeWithTerminator: textRange,
                    text: text(bytes, lineStartByte, count)
                )
            )
        }
        return (lines, starts)
    }

    /// A native `String` over `bytes[from..<to]`, which is already known to be
    /// well-formed UTF-8 because it was cut at a `\n`.
    private static func text(
        _ bytes: UnsafeBufferPointer<UInt8>,
        _ from: Int,
        _ to: Int
    ) -> String {
        guard to > from else { return "" }
        return String(decoding: UnsafeBufferPointer(rebasing: bytes[from..<to]), as: UTF8.self)
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
