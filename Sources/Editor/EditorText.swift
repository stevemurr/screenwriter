import Foundation

/// Reading characters out of the text view, cheaply and exactly.
///
/// Both of these exist because of the same measurement. In a release build, one
/// keystroke in the middle of the largest script in the reference library
/// (91 KB, 2,265 lines) cost **12.8ms of main-actor CPU** — most of a 60Hz
/// frame, on every character typed. AppKit's own share of that was 0.8ms. The
/// rest was two things this file replaces.
///
/// Everything here is UTF-16, like `LineIndex`, because the offsets come from
/// `NSTextView.selectedRanges` and go straight back to `NSRange`.
enum EditorText {

    /// A snapshot of the text view's contents, in native Swift storage.
    ///
    /// ## Why a snapshot at all
    /// `NSTextView.string` is a **lazily bridged `NSString`** once the document
    /// is big enough — Swift does not copy it, it wraps the text view's own
    /// mutable storage. Measured directly: hold `textView.string` in a `String`,
    /// insert four characters, and the held value's length goes from 89,287 to
    /// 89,291 on its own. It is not a value; it is a window onto memory the
    /// editor keeps mutating.
    ///
    /// That broke two things that were written to be correct:
    ///
    /// * `ScreenplayModel.apply(_:for:)` throws away a parse the document has
    ///   moved past by checking `text == source` — but both sides aliased the
    ///   same live buffer, so the check could not fail;
    /// * that same alias was handed to the detached parse, which then read the
    ///   storage the main thread was writing to.
    ///
    /// ## Why this way
    /// `makeContiguousUTF8()` also takes the copy, and is the obvious one line.
    /// It measured **2.03ms** here. `getCharacters` into a buffer, then Swift's
    /// own UTF-16 decoder, measured **0.165ms** for a byte-identical result —
    /// including for an unpaired surrogate, where both produce `U+FFFD`.
    ///
    /// `getBytes(…encoding: .utf8…)` is faster still and was rejected: on a
    /// string containing an unpaired surrogate it returned `true` and silently
    /// dropped everything from the bad unit onward. Truncating the writer's
    /// document is not a trade available to us.
    ///
    /// `String(decoding:as:)` and not `String(utf16CodeUnits:count:)`, which
    /// looked like a free four-times win when timed on its own — 0.039ms
    /// against 0.166ms — and made a keystroke **six times slower** end to end,
    /// 7.7ms against 1.3ms. It hands back a Cocoa-backed string, so the whole
    /// bridging cost this function exists to pay once came straight back on
    /// every comparison downstream. Measure the keystroke, not the call.
    static func snapshot(of text: NSString) -> String {
        let length = text.length
        guard length > 0 else { return "" }
        return withUnsafeTemporaryAllocation(of: unichar.self, capacity: length) { buffer in
            let base = buffer.baseAddress!
            text.getCharacters(base, range: NSRange(location: 0, length: length))
            return String(decoding: UnsafeBufferPointer(start: base, count: length), as: UTF16.self)
        }
    }

    /// The caret's one-based line and column, for the status bar.
    ///
    /// `LineIndex` answers a much bigger question than the status bar asks: it
    /// materialises a `Line` for *every* line in the document, each with its own
    /// `substring(with:)` and its own stored `isBlank` scan, and the readout
    /// wants two integers out of it. That measured **1.62ms**, and it ran twice
    /// per keystroke — once from `textDidChange` and once from the selection
    /// change AppKit posts alongside it — so 3.24ms of every keystroke went
    /// here. Counting newlines up to the caret gives the same answer in 0.04ms.
    ///
    /// `getCharacters` into a stack block rather than `character(at:)` per unit:
    /// the latter is an `objc_msgSend` per character and measured 0.35ms against
    /// 0.045ms for the same scan. Nothing is allocated on the heap and nothing
    /// is bridged, so it costs the same whether the text view hands back native
    /// Swift storage or a lazily bridged `NSString`.
    ///
    /// The inner loop is a plain `while` and not `for index in 0..<count where
    /// …`. The two optimise to the same thing — 0.017ms either way in release —
    /// but the range-and-`where` form measured **4.57ms against 0.27ms in a
    /// debug build**, because the iterator does not get inlined. This runs twice
    /// per keystroke, and the debug build is what the app is developed in.
    static func lineAndColumn(in text: NSString, at offset: Int) -> (line: Int, column: Int) {
        let caret = min(max(offset, 0), text.length)
        var newlines = 0
        var lineStart = 0
        let block = 1024

        withUnsafeTemporaryAllocation(of: unichar.self, capacity: block) { buffer in
            guard let base = buffer.baseAddress else { return }
            var start = 0
            while start < caret {
                let count = min(block, caret - start)
                text.getCharacters(base, range: NSRange(location: start, length: count))
                var index = 0
                while index < count {
                    if base[index] == 0x0A {
                        newlines += 1
                        lineStart = start + index + 1
                    }
                    index += 1
                }
                start += count
            }
        }

        return (line: newlines + 1, column: caret - lineStart + 1)
    }
}
