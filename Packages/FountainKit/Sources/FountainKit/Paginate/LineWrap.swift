import Foundation

/// Character-count wrapping for a monospaced page.
///
/// Courier Prime is monospaced and Fountain's emphasis runs (`*bold*`,
/// `_underline_`) do not change advance width, so a line's width is its
/// character count and wrapping is arithmetic. Nothing here measures text,
/// which is why pagination can run on every keystroke.
///
/// The walk is over UTF-8, counting a cell per non-continuation byte — the
/// Unicode scalar count. That is the printed cell count for everything the
/// reference corpus contains (curly quotes, en and em dashes, ellipses) and it
/// avoids grapheme-cluster segmentation, which CLAUDE.md Rule 4 records as
/// having cost the parser 6ms on a single ungated `String.count`.
public enum LineWrap {
    /// One wrapped line: the text plus where it started in the input.
    public struct Segment: Sendable, Hashable {
        /// Trailing whitespace removed — Highland leaves it in the PDF, but a
        /// trailing space is invisible and carrying it would make every
        /// equality check in this engine depend on it.
        public var text: String
        /// UTF-16 offset of the segment's first character within the input, so
        /// a line can be mapped back to the source it came from.
        public var utf16Offset: Int
    }

    /// Wraps `text` to `measure` characters, breaking on whitespace runs and
    /// after a hyphen or dash.
    ///
    /// The dash rule is Highland's, and it is not optional: 384 lines in the
    /// corpus end on an em dash and 342 on a hyphen — `You got a warrant, Agent
    /// What's-` / `his-Face` — which a space-only wrapper cannot produce.
    ///
    /// A word longer than the measure is broken at the measure rather than
    /// allowed to run off the page — there is nowhere else for it to go.
    /// Empty input yields one empty segment, because an element that renders
    /// as nothing still occupies its line.
    /// `continuation`, when given, is the measure for every line after the
    /// first. Parentheticals need it: Highland sets their first line at x=207
    /// with 29 characters and hangs the rest at x=214.195 with 27, so a single
    /// measure re-wraps every parenthetical longer than one line.
    public static func wrap(_ text: String, measure: Int, continuation: Int? = nil) -> [Segment] {
        let measure = max(measure, 1)
        let continuation = max(continuation ?? measure, 1)
        var segments: [Segment] = []
        let bytes = ContiguousArray(text.utf8)
        if bytes.isEmpty {
            return [Segment(text: "", utf16Offset: 0)]
        }

        var lineStart = 0, lineStartUTF16 = 0, lineStartCells = 0
        // The most recent whitespace run that a break may fall on.
        var breakAt = -1, breakResume = 0, breakResumeUTF16 = 0, breakResumeCells = 0
        var runStart = -1
        var previousWasSpace = false
        var cells = 0, utf16 = 0, index = 0

        func emit(_ end: Int) {
            segments.append(makeSegment(bytes, lineStart, end, lineStartUTF16))
        }

        while index < bytes.count {
            let byte = bytes[index]
            guard (byte & 0xC0) != 0x80 else { index += 1; continue }
            let isSpace = byte == 0x20 || byte == 0x09

            // A whitespace run just ended: that is where a break may go.
            if !isSpace, previousWasSpace, runStart >= lineStart {
                breakAt = runStart
                breakResume = index
                breakResumeUTF16 = utf16
                breakResumeCells = cells
            }

            // Only a printing character can overflow the measure. A space
            // sitting exactly on the margin is the break itself and costs
            // nothing — checking here too would wrap one word early on every
            // line that fills its measure exactly, which is one dialogue line
            // in three.
            if !isSpace, cells - lineStartCells >= (segments.isEmpty ? measure : continuation) {
                if breakAt > lineStart {
                    emit(breakAt)
                    lineStart = breakResume
                    lineStartUTF16 = breakResumeUTF16
                    lineStartCells = breakResumeCells
                } else {
                    emit(index)                       // one word, wider than the page
                    lineStart = index
                    lineStartUTF16 = utf16
                    lineStartCells = cells
                }
                breakAt = -1
            }

            if isSpace, !previousWasSpace { runStart = index }
            previousWasSpace = isSpace
            cells += 1
            utf16 += byte >= 0xF0 ? 2 : 1

            // Advance past this scalar's continuation bytes so a dash's break
            // opportunity lands after the whole character.
            var next = index + 1
            while next < bytes.count, (bytes[next] & 0xC0) == 0x80 { next += 1 }
            if isDash(bytes, index), next > lineStart {
                breakAt = next
                breakResume = next
                breakResumeUTF16 = utf16
                breakResumeCells = cells
            }
            index = next
        }

        emit(bytes.count)
        return segments
    }


    /// UTF-16 offsets where a paragraph may be split across a page.
    ///
    /// Each is the start of a sentence: past a `.`, `!` or `?`, past any
    /// closing quote, and past the spaces, landing on the next sentence's first
    /// character. Highland breaks a paragraph here in preference to a line
    /// boundary, re-wrapping both halves — page 5 of `The Quiet Night` ends on
    /// a 36-character line rather than split a sentence.
    ///
    /// The following character must be a capital, a digit or an opening quote,
    /// which is what keeps `Uh... no... no, I haven't.` from being read as
    /// three sentences.
    public static func sentenceBreaks(_ text: String) -> [Int] {
        var breaks: [Int] = []
        let bytes = ContiguousArray(text.utf8)
        var utf16 = 0
        var index = 0
        var sawTerminator = false
        var sawSpace = false

        while index < bytes.count {
            let byte = bytes[index]
            guard (byte & 0xC0) != 0x80 else { index += 1; continue }
            switch byte {
            case 0x2E, 0x21, 0x3F:
                sawTerminator = true
                sawSpace = false
            case 0x20, 0x09:
                if sawTerminator { sawSpace = true }
            case 0x22, 0x27, 0x29, 0x5D:
                // A closing quote or bracket keeps the terminator alive.
                if !sawSpace { break }
                fallthrough
            default:
                if sawTerminator, sawSpace {
                    let isOpener = byte == 0x22 || byte == 0x27 || byte == 0x28
                    if (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x30 && byte <= 0x39) || isOpener {
                        breaks.append(utf16)
                    }
                }
                sawTerminator = false
                sawSpace = false
            }
            utf16 += byte >= 0xF0 ? 2 : 1
            index += 1
        }
        return breaks
    }

    /// ASCII hyphen, en dash, or em dash — the characters a line may break
    /// after.
    private static func isDash(_ bytes: ContiguousArray<UInt8>, _ index: Int) -> Bool {
        if bytes[index] == 0x2D { return true }
        guard bytes[index] == 0xE2, index + 2 < bytes.count, bytes[index + 1] == 0x80
        else { return false }
        return bytes[index + 2] == 0x93 || bytes[index + 2] == 0x94
    }

    private static func makeSegment(
        _ bytes: ContiguousArray<UInt8>,
        _ start: Int,
        _ end: Int,
        _ utf16Offset: Int
    ) -> Segment {
        var end = end
        while end > start, bytes[end - 1] == 0x20 || bytes[end - 1] == 0x09 { end -= 1 }
        guard end > start else {
            return Segment(text: "", utf16Offset: utf16Offset)
        }
        return Segment(
            text: String(decoding: bytes[start..<end], as: UTF8.self),
            utf16Offset: utf16Offset
        )
    }

}
