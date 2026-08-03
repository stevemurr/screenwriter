import Foundation
import Testing
@testable import FountainKit

/// The parser's per-line path is a set of fast paths that must be *exactly*
/// equivalent to the plain implementations they replaced. This suite is where
/// that equivalence is proved rather than asserted: every fast path is run
/// side by side with a copy of the code it replaced, over a wide sweep of
/// Unicode and over the reference corpus when it is present.
///
/// Each of these was worth roughly a millisecond of a 16.8ms parse. None of
/// them is worth a single misclassified line, so the reference implementations
/// below are kept verbatim and never "tidied": they are the specification.
@Suite("Parser fast paths")
struct ParserFastPathTests {

    // MARK: - The trap that started it

    /// True when the string owns a contiguous UTF-8 buffer — the standard
    /// library's "native" representation. A `String` bridged from an
    /// `NSString` does not, and every `.utf8`, `.first` or `hasPrefix` on one
    /// goes out through CoreFoundation, one Objective-C message per code unit.
    static func isNative(_ text: String) -> Bool {
        text.utf8.withContiguousStorageIfAvailable { _ in true } ?? false
    }

    /// A slice of the corpus's shape: non-ASCII throughout, because that is
    /// what stops the bridge taking its ASCII fast path.
    static let fixture = """
        Title: The Glass House
        Credit: Written by
        Author: Someone

        INT. GLASS HOUSE – NIGHT

        LENA
        (quietly)
        Something — with an em dash — and “smart quotes”.

        > CUT TO:

        # Act One

        = A synopsis line.

        EXT. LAKE – MORNING

        Rain needles the windows…

        """

    @Test("Every line's text is a native Swift string")
    func linesAreNative() {
        let index = LineIndex(source: Self.fixture)
        #expect(index.count > 10)
        for line in index.lines {
            #expect(
                Self.isNative(line.text),
                """
                Line \(line.index) is not a native string. Something in LineIndex \
                has gone back to building line text through NSString, and every \
                byte access in the parser is now an Objective-C message.
                """
            )
        }
    }

    /// The counterpart: the construction this replaced, reproduced, and shown
    /// to misbehave. Without this, `linesAreNative` could pass vacuously — it
    /// would not tell anyone that `NSString.substring(with:)` is the thing not
    /// to do.
    ///
    /// If this ever fails, the platform has changed and bridged substrings are
    /// native now. That is good news, but re-measure before acting on it: the
    /// UTF-16 `character(at:)` scan the old code also used was a separate cost.
    @Test("The NSString construction this replaced really does produce foreign strings")
    func nsstringSubstringsAreForeign() {
        let ns = Self.fixture as NSString
        var foreign = 0
        var total = 0
        var start = 0
        for offset in 0..<ns.length where ns.character(at: offset) == 0x0A {
            let text = ns.substring(with: NSRange(location: start, length: offset - start))
            if !text.isEmpty {
                total += 1
                if !Self.isNative(text) { foreign += 1 }
            }
            start = offset + 1
        }
        #expect(total > 10)
        #expect(
            foreign == total,
            """
            \(foreign) of \(total) NSString substrings were foreign. This test \
            exists to show why LineIndex does not build line text that way.
            """
        )
    }

    // MARK: - isEffectivelyUppercase

    /// The pre-change implementation, verbatim. Every `Character` here reaches
    /// the Unicode property tables; that is exactly what the ASCII path avoids.
    static func referenceUppercase(_ text: String) -> Bool {
        var sawLetter = false
        for character in text where character.isLetter {
            sawLetter = true
            if character.isLowercase { return false }
        }
        return sawLetter
    }

    /// Contexts that straddle the point where the fast path gives up: a
    /// non-ASCII scalar before any cased letter, after one, and between two.
    static let contexts: [(String, String)] = [
        ("", ""), ("A", ""), ("", "A"), ("a", ""), ("", "a"),
        ("AB", "CD"), ("A", "a"), ("a", "A"), (" ", " "), ("1", "2"),
        ("LENA (", ")"), ("INT. ", " - DAY"),
    ]

    @Test("The ASCII uppercase test agrees with the Unicode one on every scalar")
    func uppercaseMatchesReferenceAcrossUnicode() {
        for value in 0...0x2FFF {
            guard let scalar = Unicode.Scalar(UInt32(value)) else { continue }
            let piece = String(scalar)
            for (prefix, suffix) in Self.contexts {
                let subject = prefix + piece + suffix
                #expect(
                    ScriptParser.isEffectivelyUppercase(subject) == Self.referenceUppercase(subject),
                    "U+\(String(value, radix: 16, uppercase: true)) in \(String(reflecting: subject))"
                )
            }
        }
    }

    @Test("The ASCII uppercase test agrees on multi-scalar graphemes")
    func uppercaseMatchesReferenceOnClusters() {
        let clusters = [
            "a\u{0301}", "A\u{0301}", "e\u{0301}A", "A\u{0301}a", "\u{0301}A",
            "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", "A\u{1F600}B",
            "\u{200D}a", "a\u{200D}A", "\u{FEFF}ABC", "ABC\u{FEFF}", "\r\n", "A\r\nB",
            // Turkish dotted/dotless I, and a title-case letter that is neither
            // upper nor lower.
            "İSTANBUL", "ısparta", "\u{01C4}", "\u{01C5}", "\u{01C6}", "\u{01C5}A", "a\u{01C5}",
            "ＡＢＣ", "ａｂｃ", "ⅠⅡⅢ", "ⅰⅱⅲ", "ΑΒΓ", "αβγ", "АБВ", "абв",
        ]
        for cluster in clusters {
            for (prefix, suffix) in Self.contexts {
                let subject = prefix + cluster + suffix
                #expect(
                    ScriptParser.isEffectivelyUppercase(subject) == Self.referenceUppercase(subject),
                    "\(String(reflecting: subject))"
                )
            }
        }
    }

    // MARK: - trimmedRight

    /// The pre-change implementation, verbatim.
    static func referenceTrimmedRight(_ text: String) -> String {
        var scalars = Substring(text)
        while let last = scalars.last, last.isWhitespace { scalars = scalars.dropLast() }
        return String(scalars)
    }

    @Test("trimmedRight's fast path agrees with the Character loop")
    func trimmedRightMatchesReference() {
        var subjects = [
            "", " ", "  ", "\t", "\r", "abc", "abc ", "abc\t", "abc\r",
            "abc \t \r", " abc ", "abc\u{00A0}", "abc\u{2003}", "abc\u{2028}",
            "café ", "café", "日本語 ", "日本語", "\u{1F600} ", "\u{1F600}",
            "a\u{0301} ", "a \u{0301}", "LENA  ", "  ", "\u{200A}", "x\u{200A}",
        ]
        for value in 0...0x2FFF {
            guard let scalar = Unicode.Scalar(UInt32(value)) else { continue }
            subjects.append("abc" + String(scalar))
            subjects.append(String(scalar))
        }
        for subject in subjects {
            let line = LineIndex(source: subject).lines[0]
            #expect(
                line.trimmedRight == Self.referenceTrimmedRight(subject),
                "\(String(reflecting: subject))"
            )
        }
    }

    // MARK: - trimmedWhitespace

    @Test("trimmedWhitespace's fast path agrees with Foundation")
    func trimmedWhitespaceMatchesFoundation() {
        var subjects = [
            "", " ", "  ", "\t", " a ", "a", "  LENA  ", "LENA (V.O.)",
            "\u{00A0}x\u{00A0}", "\u{2003}x\u{2003}", "\u{3000}x\u{3000}",
            "\r\n", "\n", "x\n", "\nx", "café", " café ", "\u{1F600}",
        ]
        for value in 0...0x2FFF {
            guard let scalar = Unicode.Scalar(UInt32(value)) else { continue }
            let piece = String(scalar)
            subjects.append(piece)
            subjects.append(piece + "x" + piece)
            subjects.append(" " + piece + " ")
        }
        for subject in subjects {
            #expect(
                ScriptParser.trimmedWhitespace(subject)
                    == subject.trimmingCharacters(in: .whitespaces),
                "\(String(reflecting: subject))"
            )
            let slice = Substring(subject)
            #expect(
                ScriptParser.trimmedWhitespace(slice)
                    == slice.trimmingCharacters(in: .whitespaces),
                "substring \(String(reflecting: subject))"
            )
        }
    }

    // MARK: - isSceneHeading's first-byte gate

    /// The gate skips any line whose first byte is not `I` or `E`. That is only
    /// sound while every prefix in the table starts with one of them, so adding
    /// `POV.` to the table has to fail here rather than silently never match.
    @Test("Every scene-heading prefix starts with a letter the gate lets through")
    func sceneHeadingGateCoversTheTable() {
        for prefix in ScriptParser.sceneHeadingPrefixes {
            let first = try! #require(prefix.utf8.first)
            #expect(
                first == 0x49 || first == 0x45,
                """
                \(String(reflecting: prefix)) starts with a letter that \
                isSceneHeading's first-byte gate rejects, so it can never match. \
                Widen the gate or drop the prefix.
                """
            )
            #expect(prefix == prefix.uppercased(), "\(prefix) must already be uppercase")
        }
    }

    @Test("The gated heading test agrees with the ungated one")
    func sceneHeadingMatchesUngated() {
        func ungated(_ text: String) -> Bool {
            ScriptParser.sceneHeadingPrefixes.contains {
                ScriptParser.hasUppercasedPrefix(text, $0)
            }
        }
        var subjects = [
            "INT. GLASS HOUSE - NIGHT", "int. glass house", "EXT. LAKE – MORNING",
            "I/E MONTAGE IMAGE", "i/e.", "EST. SOMETHING", "est something",
            "Rain needles the windows.", "", " INT. X", "ínt. x", "İNT. X",
            "Interior", "Everything", "eXT. X", "EXTRA",
        ]
        for value in 0...0x2FFF {
            guard let scalar = Unicode.Scalar(UInt32(value)) else { continue }
            subjects.append(String(scalar) + "NT. X")
            subjects.append("INT" + String(scalar))
        }
        for subject in subjects {
            #expect(
                ScriptParser.isSceneHeading(subject) == ungated(subject),
                "\(String(reflecting: subject))"
            )
        }
    }

    // MARK: - markerOffset

    /// The pre-change implementation, verbatim.
    static func referenceMarkerOffset(
        _ text: String, _ first: UInt8, _ second: UInt8, from start: Int = 0
    ) -> Int? {
        var previous: UInt8 = 0
        var offset = 0
        for byte in text.utf8 {
            if offset > start, previous == first, byte == second { return offset - 1 }
            previous = byte
            offset += 1
        }
        return nil
    }

    @Test("The contiguous marker scan agrees with the iterator one")
    func markerOffsetMatchesReference() {
        let subjects = [
            "", "/", "*", "/*", "*/", "a/*b", "a*/b", "/*/*", "*/*/", "/**/",
            "no markers here at all", "trailing /*", "*/ leading",
            "café /* с кириллицей */ x", "\u{1F600}/*\u{1F600}*/",
            "/*/*/*/*/*", "x/*y*/z/*w*/",
        ]
        for subject in subjects {
            for start in 0...max(subject.utf8.count, 1) {
                #expect(
                    ScriptParser.markerOffset(subject, 0x2F, 0x2A, from: start)
                        == Self.referenceMarkerOffset(subject, 0x2F, 0x2A, from: start),
                    "/* in \(String(reflecting: subject)) from \(start)"
                )
                #expect(
                    ScriptParser.markerOffset(subject, 0x2A, 0x2F, from: start)
                        == Self.referenceMarkerOffset(subject, 0x2A, 0x2F, from: start),
                    "*/ in \(String(reflecting: subject)) from \(start)"
                )
            }
        }
    }

    // MARK: - classify's first-byte gate

    /// `classify` tests the first *byte* before it asks for the first
    /// `Character`. The byte only decides whether the line is *worth* asking
    /// about; the `Character` still decides. A forcing mark carrying a combining
    /// accent is one grapheme cluster that is not the mark, so it must come out
    /// unforced — `>́ CUT TO:` is still read as a transition, but on its own
    /// merits, with no forcing mark recorded.
    ///
    /// This is the edge the gate could plausibly have broken, and the corpus
    /// cannot cover it: nobody writes accented forcing marks.
    @Test("A forcing mark carrying a combining accent is not a forced element")
    func combiningMarkAfterForcingMarkIsNotForced() {
        let accented: [(String, ElementKind)] = [
            ("#\u{0301} Act One", .action),
            ("=\u{0301} synopsis", .action),
            ("!\u{0301} action", .action),
            ("@\u{0301}LENA", .action),
            ("~\u{0301}lyrics", .action),
            // Reached through the unforced path and still recognised, because
            // it ends in `TO:` and is uppercase — but without a `>` mark.
            (">\u{0301} CUT TO:", .transition),
            (".\u{0301}FORCED", .action),
        ]
        for (line, expected) in accented {
            let element = ScriptParser.parse(line + "\n").elements.first
            #expect(element?.kind == expected, "\(String(reflecting: line))")
            #expect(
                element?.forcingMark == nil,
                "\(String(reflecting: line)) must not record a forcing mark"
            )
        }

        let forced: [(String, ElementKind, Character)] = [
            ("# Act One", .section, "#"),
            ("= synopsis", .synopsis, "="),
            ("!action", .action, "!"),
            ("@LENA", .character, "@"),
            ("~lyrics", .lyrics, "~"),
            ("> CUT TO:", .transition, ">"),
            (".FORCED", .sceneHeading, "."),
        ]
        for (line, kind, mark) in forced {
            let element = ScriptParser.parse(line + "\n").elements.first
            #expect(element?.kind == kind, "\(String(reflecting: line))")
            #expect(element?.forcingMark == mark, "\(String(reflecting: line)) lost its mark")
        }
    }

    // MARK: - The corpus

    @Test("Every fast path agrees with its reference over the whole corpus")
    func corpusAgrees() throws {
        guard !Corpus.relativePaths.isEmpty else {
            Corpus.recordAbsence("Parser fast-path equivalence not proved on real writing.")
            return
        }
        for relativePath in Corpus.relativePaths {
            let source = try Corpus.source(of: relativePath)
            for line in LineIndex(source: source).lines {
                #expect(Self.isNative(line.text), "\(relativePath):\(line.index) is foreign")
                #expect(
                    line.trimmedRight == Self.referenceTrimmedRight(line.text),
                    "\(relativePath):\(line.index) trimmedRight"
                )
                let trimmed = line.trimmedRight
                #expect(
                    ScriptParser.isEffectivelyUppercase(trimmed)
                        == Self.referenceUppercase(trimmed),
                    "\(relativePath):\(line.index) isEffectivelyUppercase"
                )
                #expect(
                    ScriptParser.markerOffset(trimmed, 0x2F, 0x2A)
                        == Self.referenceMarkerOffset(trimmed, 0x2F, 0x2A),
                    "\(relativePath):\(line.index) markerOffset"
                )
                #expect(
                    ScriptParser.trimmedWhitespace(trimmed)
                        == trimmed.trimmingCharacters(in: .whitespaces),
                    "\(relativePath):\(line.index) trimmedWhitespace"
                )
            }
        }
    }
}
