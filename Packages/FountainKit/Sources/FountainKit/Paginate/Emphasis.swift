import Foundation

/// A styled span of a printed line.
public struct EmphasisRun: Sendable, Hashable {
    public struct Style: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let bold = Style(rawValue: 1 << 0)
        public static let italic = Style(rawValue: 1 << 1)
        public static let underline = Style(rawValue: 1 << 2)
    }

    /// UTF-16 offsets into the line's printed text.
    public var range: Range<Int>
    public var style: Style

    public init(range: Range<Int>, style: Style) {
        self.range = range
        self.style = style
    }
}

/// Splits Fountain's `*italic*`, `**bold**`, `***both***` and `_underline_`
/// into printed text plus styled ranges.
///
/// Pagination needs this, not just the renderer: Highland does not print the
/// marks, so counting them makes every emphasised line wrap early. The Quiet
/// Night sets `**VHS STATIC**` in almost every paragraph, and counting its four
/// asterisks re-wrapped most of the script.
///
/// Delimiters are matched in pairs rather than simply deleted, which matters:
/// five of the six lines in the reference corpus containing an underscore use
/// it inside a word — `**ONEBOX_MANYPATHS**`, `"READ_FIRST.txt"` — and Highland
/// prints those underscores. An unmatched delimiter stays in the text.
public enum Emphasis {
    public struct Parsed: Sendable {
        /// The text as it prints, with matched delimiters removed.
        public var text: String
        /// Styled spans, in printed-text UTF-16 offsets.
        public var runs: [EmphasisRun]
        /// `(printed offset, UTF-16 units removed before it)`, ascending.
        /// Empty when nothing was removed, which is the common case.
        var shifts: [(printed: Int, removed: Int)]

        /// Maps an offset in the printed text back to the input.
        public func inputOffset(forPrinted offset: Int) -> Int {
            var removed = 0
            for shift in shifts {
                if shift.printed <= offset { removed = shift.removed } else { break }
            }
            return offset + removed
        }
    }

    public static func parse(_ text: String) -> Parsed {
        // Almost every line has no markers at all; skipping the scan entirely
        // keeps pagination linear in practice rather than only in theory.
        var interesting = false
        for byte in text.utf8 where byte == 0x2A || byte == 0x5F || byte == 0x5C || byte == 0x7B {
            interesting = true
            break
        }
        guard interesting else { return Parsed(text: text, runs: [], shifts: []) }
        return scan(Array(text.utf8))
    }

    // MARK: - Scanning

    private struct Run {
        var start: Int
        var length: Int
        var marker: UInt8
        var canOpen: Bool
        var canClose: Bool
        var taken = false
    }

    private static func scan(_ bytes: [UInt8]) -> Parsed {
        var runs = delimiterRuns(bytes)
        // Longest first, so `***` is not eaten by `**`.
        var pairs: [(open: Int, close: Int, style: EmphasisRun.Style)] = []
        for (marker, length, style) in [
            (UInt8(0x2A), 3, EmphasisRun.Style([.bold, .italic])),
            (UInt8(0x2A), 2, EmphasisRun.Style.bold),
            (UInt8(0x2A), 1, EmphasisRun.Style.italic),
            (UInt8(0x5F), 1, EmphasisRun.Style.underline)
        ] {
            var index = 0
            while index < runs.count {
                guard !runs[index].taken,
                      runs[index].marker == marker,
                      runs[index].length == length,
                      runs[index].canOpen
                else { index += 1; continue }
                var close = index + 1
                while close < runs.count {
                    if !runs[close].taken,
                       runs[close].marker == marker,
                       runs[close].length == length,
                       runs[close].canClose {
                        break
                    }
                    close += 1
                }
                guard close < runs.count else { index += 1; continue }
                runs[index].taken = true
                runs[close].taken = true
                pairs.append((runs[index].start, runs[close].start, style))
                index = close + 1
            }
        }

        // Build the printed text, dropping matched delimiters and the
        // backslash of an escaped one.
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var removals = Set<Int>()
        var lengths: [Int: Int] = [:]
        for run in runs where run.taken {
            removals.insert(run.start)
            lengths[run.start] = run.length
        }
        var shifts: [(printed: Int, removed: Int)] = []
        var removed = 0
        var printedOffsets = [Int](repeating: 0, count: bytes.count + 1)
        var printedUTF16 = 0
        var index = 0
        while index <= bytes.count {
            printedOffsets[index] = printedUTF16
            guard index < bytes.count else { break }
            if removals.contains(index) {
                let length = lengths[index] ?? 1
                removed += length
                shifts.append((printed: printedUTF16, removed: removed))
                for offset in index..<(index + length) { printedOffsets[offset] = printedUTF16 }
                index += length
                continue
            }
            let byte = bytes[index]
            // Highland's inline markup — `{{REVISION: #07a04a}}` and
            // `{{/REVISION}}`, 32 of them in the corpus — marks a revised span
            // and never prints. Dropping it here is what keeps `Weed and
            // pills.` from typesetting as `{{REVISION: #07a04a}}Weed and`.
            if byte == 0x7B, index + 1 < bytes.count, bytes[index + 1] == 0x7B,
               let close = closingBrace(bytes, from: index + 2) {
                removed += close - index
                shifts.append((printed: printedUTF16, removed: removed))
                for offset in index..<close { printedOffsets[offset] = printedUTF16 }
                index = close
                continue
            }
            if byte == 0x5C, index + 1 < bytes.count,
               bytes[index + 1] == 0x2A || bytes[index + 1] == 0x5F {
                removed += 1
                shifts.append((printed: printedUTF16, removed: removed))
                index += 1
                continue
            }
            output.append(byte)
            if (byte & 0xC0) != 0x80 { printedUTF16 += byte >= 0xF0 ? 2 : 1 }
            index += 1
        }

        let styled = pairs.map { pair in
            EmphasisRun(
                range: printedOffsets[pair.open]..<printedOffsets[pair.close],
                style: pair.style
            )
        }
        return Parsed(
            text: String(decoding: output, as: UTF8.self),
            runs: styled.filter { !$0.range.isEmpty },
            shifts: shifts
        )
    }

    /// The index just past a closing `}}`, or nil if the span never closes.
    private static func closingBrace(_ bytes: [UInt8], from start: Int) -> Int? {
        var index = start
        while index + 1 < bytes.count {
            if bytes[index] == 0x7D, bytes[index + 1] == 0x7D { return index + 2 }
            index += 1
        }
        return nil
    }

    private static func delimiterRuns(_ bytes: [UInt8]) -> [Run] {
        var runs: [Run] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            guard byte == 0x2A || byte == 0x5F else { index += 1; continue }
            if index > 0, bytes[index - 1] == 0x5C { index += 1; continue }   // escaped
            var end = index
            while end < bytes.count, bytes[end] == byte { end += 1 }
            let after = end < bytes.count ? bytes[end] : 0x20
            let before = index > 0 ? bytes[index - 1] : 0x20
            runs.append(
                Run(
                    start: index,
                    length: end - index,
                    marker: byte,
                    canOpen: after != 0x20 && after != 0x09 && end < bytes.count,
                    canClose: before != 0x20 && before != 0x09 && index > 0
                )
            )
            index = end
        }
        return runs
    }
}
