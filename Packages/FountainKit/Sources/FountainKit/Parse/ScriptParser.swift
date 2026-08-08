import Foundation

/// Turns Fountain source into a `ParsedScript`.
///
/// **Policy: parse leniently, lint loudly.** This type resolves every line to
/// *some* element, matching what Highland actually does rather than what the
/// spec strictly says — the reference corpus contains en-dash sluglines,
/// lowercase headings, headings with no trailing period, parentheticals on the
/// cue line, and `.`/`>` used as generic "force" marks. Ambiguity is never an
/// error here; `Linter` reports it separately so the two concerns stay
/// independently testable.
///
/// Parsing is a single linear pass, measured at **1.6ms** on the largest script
/// in the reference library (91 KB, 3,608 lines), release build, CPU time on an
/// M1 Max. It runs off the main actor behind `ScreenplayModel`'s 120ms
/// debounce, so there is deliberately no incremental parser.
/// `ScriptParserPerformanceTests` holds that trade honest.
///
/// It was 16.8ms until the line index stopped handing every line out as a
/// bridged `NSString` — see the note on `LineIndex.init(source:)`, which is the
/// single most important thing to know before touching this file.
///
/// The hot path is per-line and allocation-sensitive. Three rules follow, all
/// learned by measurement:
///
/// 1. Never use `String.count` or `Character` iteration on a whole line. They
///    walk grapheme clusters; an ungated `raw.count >= 3` alone cost 6ms.
/// 2. Never use `String.range(of:)` for a literal marker — `markerOffset` is
///    what that is for.
/// 3. **Iterating `.utf8` is only a fast path on a *native* string.** The
///    obvious-looking `Character` predicates are worse still: `isLetter`,
///    `isLowercase` and `isWhitespace` each reach the Unicode property tables
///    with no ASCII shortcut, and `isEffectivelyUppercase` alone was 34% of
///    parse CPU because of it. Gate on a byte, fall back to the general case,
///    and prove the two agree in `ParserFastPathTests`.
public enum ScriptParser {
    public static func parse(_ source: String) -> ParsedScript {
        let index = LineIndex(source: source)
        var elements: [Element] = []
        elements.reserveCapacity(index.count)

        let titlePage = parseTitlePage(index)
        // Resume after the title page block, which is terminated by its first
        // blank line. Everything before that point is already accounted for.
        var line = titlePage.map { firstLine(after: $0, in: index) } ?? 0

        // Blank lines consumed by the title page still need to exist as
        // elements so that ranges tile the document with no gaps.
        for skipped in 0..<line {
            elements.append(
                Element(
                    kind: .blank,
                    range: index[skipped].rangeWithTerminator,
                    lineIndex: skipped,
                    text: ""
                )
            )
        }

        var inBoneyard = false

        while line < index.count {
            let current = index[line]
            let raw = current.trimmedRight

            // --- Boneyard spans lines and outranks everything else ----------
            // Marker scanning goes through UTF-8 rather than `String.range(of:)`,
            // which does full Unicode-aware searching and would run twice on
            // every line of the document.
            if inBoneyard {
                elements.append(make(.boneyard, current, text: raw))
                if markerOffset(raw, 0x2A, 0x2F) != nil { inBoneyard = false }
                line += 1
                continue
            }
            if let open = markerOffset(raw, 0x2F, 0x2A) {
                let close = markerOffset(raw, 0x2A, 0x2F, from: open + 2)
                inBoneyard = close == nil
                elements.append(make(.boneyard, current, text: raw))
                line += 1
                continue
            }

            if current.isBlank {
                elements.append(make(.blank, current, text: ""))
                line += 1
                continue
            }

            let previousKind = elements.last { $0.kind != .boneyard }?.kind
            elements.append(classify(raw, line: current, index: index, previous: previousKind))
            line += 1
        }

        let scenes = buildScenes(elements: elements, source: source)
        let sections = buildSections(elements: elements, scenes: scenes, source: source)
        let characters = orderedCharacters(in: elements)

        return ParsedScript(
            source: source,
            elements: elements,
            titlePage: titlePage,
            scenes: scenes,
            sections: sections,
            characters: characters
        )
    }

    // MARK: - Line classification

    /// Internal rather than private so `LiveClassifier` can classify a window of
    /// lines through the *same* code path the full pass uses. Two classifiers
    /// that agree by construction is the whole point: the editor styles a block
    /// as it is typed, and the debounced full parse must then find nothing to
    /// change.
    static func classify(
        _ raw: String,
        line: LineIndex.Line,
        index: LineIndex,
        previous: ElementKind?
    ) -> Element {
        // The forcing marks are all single ASCII scalars, so a line can only
        // carry one if its first *byte* is that mark's byte. Testing the byte
        // first means `raw.first` — which breaks a grapheme cluster — and the
        // `Character` comparisons in the switch below only run on the handful of
        // lines that could actually match, rather than on every line of the
        // document. The `Character` tests are kept, not replaced: `#` followed
        // by a combining mark is one cluster that is *not* `"#"`, and that line
        // must still fall through to action exactly as it did before.
        switch raw.utf8.first {
        case 0x23 /* # */, 0x3D /* = */, 0x21 /* ! */, 0x40 /* @ */,
             0x7E /* ~ */, 0x3E /* > */, 0x2E /* . */:
            break
        default:
            return classifyUnforced(raw, line: line, index: index, previous: previous)
        }
        let first = raw.first

        // `===` or longer is a page break; a single `=` is a synopsis. Order
        // matters — checking synopsis first would eat every page break.
        //
        // Counted in UTF-8. `String.count` is a grapheme count, so an ungated
        // `raw.count >= 3` walked every line of the document in full before
        // doing anything else — it was the single largest cost in the parser.
        if first == "=", raw.utf8.count >= 3, raw.utf8.allSatisfy({ $0 == 0x3D }) {
            return make(.pageBreak, line, text: raw)
        }

        if let first {
            switch first {
            case "#":
                let depth = raw.prefix { $0 == "#" }.count
                // `#Act I` with no space after the hash appears in the corpus,
                // so the space is optional.
                let title = trimmedWhitespace(raw.dropFirst(depth))
                return make(.section, line, text: title, mark: "#", depth: depth)

            case "=":
                let text = trimmedWhitespace(raw.dropFirst())
                return make(.synopsis, line, text: text, mark: "=")

            case "!":
                return make(.action, line, text: String(raw.dropFirst()), mark: "!")

            case "@":
                return character(from: String(raw.dropFirst()), line: line, mark: "@")

            case "~":
                return make(.lyrics, line, text: String(raw.dropFirst()), mark: "~")

            case ">":
                let body = trimmedWhitespace(raw.dropFirst())
                if body.hasSuffix("<") {
                    let centered = trimmedWhitespace(body.dropLast())
                    return make(.centered, line, text: centered, mark: ">")
                }
                return make(.transition, line, text: body, mark: ">")

            case ".":
                // A forced scene heading — but not an ellipsis, which is action
                // that happens to start with a dot.
                if !raw.hasPrefix("..") {
                    let body = String(raw.dropFirst())
                    let (heading, number) = splitSceneNumber(body)
                    return make(.sceneHeading, line, text: heading, mark: ".", sceneNumber: number)
                }

            default:
                break
            }
        }

        // `..` and `#` -with-a-combining-mark both land here: the line opened
        // with a mark byte but is not forced after all.
        return classifyUnforced(raw, line: line, index: index, previous: previous)
    }

    /// Everything that does not depend on a leading forcing mark.
    private static func classifyUnforced(
        _ raw: String,
        line: LineIndex.Line,
        index: LineIndex,
        previous: ElementKind?
    ) -> Element {
        // A line that is entirely a note.
        if raw.hasPrefix("[["), raw.hasSuffix("]]") {
            let body = trimmedWhitespace(raw.dropFirst(2).dropLast(2))
            return make(.note, line, text: body)
        }

        if isSceneHeading(raw) {
            let (heading, number) = splitSceneNumber(raw)
            return make(.sceneHeading, line, text: heading, sceneNumber: number)
        }

        let precededByBlank = index.isPrecededByBlank(line.index)

        if precededByBlank, isTransition(raw) {
            return make(.transition, line, text: raw)
        }

        // A character cue needs a blank line before it and content after it.
        // That context sensitivity is the whole reason parsing is a pass rather
        // than a per-line function.
        if precededByBlank, index.isFollowedByContent(line.index), isCharacterCue(raw) {
            return character(from: raw, line: line, mark: nil)
        }

        if previous == .character || previous == .parenthetical || previous == .dialogue {
            if raw.hasPrefix("("), raw.hasSuffix(")") {
                return make(.parenthetical, line, text: raw)
            }
            if previous != .dialogue || !precededByBlank {
                return make(.dialogue, line, text: raw)
            }
        }

        return make(.action, line, text: raw)
    }

    // MARK: - Element predicates

    /// Internal rather than private so `ParserFastPathTests` can hold the
    /// first-byte gate in `isSceneHeading` honest against the table itself.
    static let sceneHeadingPrefixes = [
        "INT./EXT.", "INT/EXT.", "INT./EXT", "INT/EXT", "I/E.", "I/E",
        "INT.", "INT ", "EXT.", "EXT ", "EST.", "EST "
    ]

    /// Lenient by design. `I/E MONTAGE IMAGE` has no period and
    /// `EXT. MOUNTAIN – MORNING` uses an en dash; both are real headings in the
    /// corpus and both are accepted. `Linter` flags the en dash separately.
    ///
    /// Compares byte-wise against an already-uppercase prefix table rather than
    /// uppercasing the line. This runs on every line, and `uppercased()` was
    /// allocating a full copy of each one to look at its first nine characters.
    ///
    /// Gated on the first byte first. Every prefix in the table begins `I` or
    /// `E`, so a line starting with anything else cannot be a heading — and
    /// without the gate every one of those lines walked all twelve prefixes,
    /// building a fresh UTF-8 iterator each time. `ParserFastPathTests` pins
    /// the invariant the gate depends on, so adding a prefix that starts with some
    /// other letter fails loudly rather than silently never matching.
    public static func isSceneHeading(_ text: String) -> Bool {
        guard let first = text.utf8.first else { return false }
        let upper = (first >= 0x61 && first <= 0x7A) ? first - 32 : first
        guard upper == 0x49 /* I */ || upper == 0x45 /* E */ else { return false }
        return sceneHeadingPrefixes.contains { hasUppercasedPrefix(text, $0) }
    }

    /// True when `text` begins with `prefix`, ignoring ASCII case. `prefix` must
    /// already be uppercase ASCII.
    public static func hasUppercasedPrefix(_ text: String, _ prefix: String) -> Bool {
        var characters = text.utf8.makeIterator()
        for expected in prefix.utf8 {
            guard let byte = characters.next() else { return false }
            let upper = (byte >= 0x61 && byte <= 0x7A) ? byte - 32 : byte
            if upper != expected { return false }
        }
        return true
    }

    /// UTF-8 offset of a two-byte marker such as `/*`, or nil.
    ///
    /// Every line of the document is scanned for `/*` whether or not the script
    /// has a boneyard anywhere in it, so this is one of the few places where the
    /// difference between a `String.UTF8View` iterator and a raw pointer walk is
    /// worth spelling out. `LineIndex` guarantees a native line, so the
    /// contiguous path is the one that runs; the iterator loop stays as the
    /// fallback for a foreign string handed in from elsewhere.
    public static func markerOffset(_ text: String, _ first: UInt8, _ second: UInt8, from start: Int = 0) -> Int? {
        let contiguous: Int?? = text.utf8.withContiguousStorageIfAvailable { bytes in
            var offset = max(start, 0) + 1
            let count = bytes.count
            while offset < count {
                if bytes[offset] == second, bytes[offset - 1] == first { return offset - 1 }
                offset += 1
            }
            return Int?.none
        }
        if let contiguous { return contiguous }

        var previous: UInt8 = 0
        var offset = 0
        for byte in text.utf8 {
            if offset > start, previous == first, byte == second { return offset - 1 }
            previous = byte
            offset += 1
        }
        return nil
    }

    /// `CUT TO:`, `FADE OUT.`, `DISSOLVE TO:` — uppercase and terminal.
    public static func isTransition(_ text: String) -> Bool {
        guard isEffectivelyUppercase(text) else { return false }
        if text.hasSuffix("TO:") { return true }
        return ["FADE OUT.", "FADE OUT", "FADE TO BLACK.", "CUT TO BLACK."].contains(text.uppercased())
    }

    /// A cue is uppercase, may carry a `(V.O.)`-style extension, and may end in
    /// `^` for dual dialogue. `CHRIS (teasing and drawn out)` — a lowercase
    /// parenthetical on the cue line — appears in the corpus and is accepted,
    /// because only the name portion is tested for case.
    public static func isCharacterCue(_ text: String) -> Bool {
        var name = text
        if name.hasSuffix("^") { name = String(name.dropLast()) }
        if let open = name.firstIndex(of: "(") { name = String(name[name.startIndex..<open]) }
        name = trimmedWhitespace(name)
        guard !name.isEmpty else { return false }
        // A cue is a name, not a sentence. This keeps a shouted line of action
        // from being promoted to a cue. UTF-8 rather than grapheme count: this
        // runs on every line that follows a blank one.
        guard name.utf8.count <= 60 else { return false }
        return isEffectivelyUppercase(name)
    }

    /// True when every cased letter is uppercase and at least one letter exists.
    /// Digits, punctuation, and accents pass through untested.
    ///
    /// ASCII is decided byte-wise. `Character.isLetter` and `Character.isLowercase`
    /// have no ASCII shortcut — each one reaches
    /// `_swift_stdlib_getBinaryProperties` to look the scalar up in the Unicode
    /// property tables — and this predicate runs on every line that follows a
    /// blank one, up to twice (once via `isTransition`, once via
    /// `isCharacterCue`). Measured on the 91 KB script it was **34% of total
    /// parse CPU**, the largest single cost left after line indexing.
    ///
    /// The first byte over 0x7F hands the *whole* string back to the Unicode
    /// loop, so accented and non-Latin text still gets the full answer. Bailing
    /// out mid-string is safe because the fast loop only ever returns early on
    /// an ASCII lowercase letter, and the Unicode loop would reach that same
    /// letter and return false too. `ParserFastPathTests` checks the two
    /// against each other over every scalar up to U+2FFF and the whole corpus.
    public static func isEffectivelyUppercase(_ text: String) -> Bool {
        var sawLetter = false
        for byte in text.utf8 {
            if byte >= 0x80 { return isEffectivelyUppercaseUnicode(text) }
            if byte >= 0x61, byte <= 0x7A { return false }
            if byte >= 0x41, byte <= 0x5A { sawLetter = true }
        }
        return sawLetter
    }

    /// The general case, kept verbatim so the ASCII path above has something to
    /// be checked against.
    private static func isEffectivelyUppercaseUnicode(_ text: String) -> Bool {
        var sawLetter = false
        for character in text where character.isLetter {
            sawLetter = true
            if character.isLowercase { return false }
        }
        return sawLetter
    }

    // MARK: - Fragments

    /// `trimmingCharacters(in: .whitespaces)`, with the Foundation call skipped
    /// when the ends of the string prove there is nothing to trim.
    ///
    /// The parser makes 2,895 of these calls on the 91 KB script — 0.8 per
    /// source line — and 2,439 of them return the string unchanged. Not one of
    /// them has a non-ASCII byte at either end. `trimmingCharacters` walks
    /// grapheme clusters and asks a `CharacterSet` about each one, so paying
    /// that to discover there was nothing to do was most of the cost.
    ///
    /// `CharacterSet.whitespaces` is space, tab, and the Unicode space
    /// separators — and every one of those separators is multi-byte in UTF-8.
    /// So a leading or trailing byte under 0x80 that is neither 0x20 nor 0x09 is
    /// definitively not in the set, and neither is the grapheme cluster it
    /// belongs to, whose first scalar is exactly that byte.
    static func trimmedWhitespace(_ text: String) -> String {
        guard let first = text.utf8.first, let last = text.utf8.last else { return text }
        if first < 0x80, last < 0x80,
           first != 0x20, first != 0x09, last != 0x20, last != 0x09 {
            return text
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// The `Substring` half of the pair. `StringProtocol` cannot express this
    /// once: its `UTF8View` is only known to be a `Collection`, so `last` is not
    /// available on it.
    static func trimmedWhitespace(_ text: Substring) -> String {
        guard let first = text.utf8.first, let last = text.utf8.last else { return String(text) }
        if first < 0x80, last < 0x80,
           first != 0x20, first != 0x09, last != 0x20, last != 0x09 {
            return String(text)
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Splits a trailing `#42#` scene number off a heading.
    public static func splitSceneNumber(_ text: String) -> (heading: String, number: String?) {
        let trimmed = trimmedWhitespace(text)
        guard trimmed.hasSuffix("#"), trimmed.count > 2 else { return (trimmed, nil) }
        let withoutTrailing = trimmed.dropLast()
        guard let openIndex = withoutTrailing.lastIndex(of: "#") else { return (trimmed, nil) }
        let number = String(withoutTrailing[withoutTrailing.index(after: openIndex)...])
        guard !number.isEmpty, !number.contains(" ") else { return (trimmed, nil) }
        let heading = trimmedWhitespace(withoutTrailing[withoutTrailing.startIndex..<openIndex])
        return (heading, number)
    }

    private static func character(
        from text: String,
        line: LineIndex.Line,
        mark: Character?
    ) -> Element {
        var body = trimmedWhitespace(text)
        var dual = false
        if body.hasSuffix("^") {
            dual = true
            body = trimmedWhitespace(body.dropLast())
        }
        return make(.character, line, text: body, mark: mark, isDual: dual)
    }

    /// The cue's name with any `(V.O.)` extension and dual-dialogue caret
    /// removed — the key used for the cast list and autocomplete.
    public static func characterName(from cueText: String) -> String {
        var name = cueText
        if name.hasSuffix("^") { name = String(name.dropLast()) }
        if let open = name.firstIndex(of: "(") { name = String(name[name.startIndex..<open]) }
        return trimmedWhitespace(name)
    }

    static func make(
        _ kind: ElementKind,
        _ line: LineIndex.Line,
        text: String,
        mark: Character? = nil,
        depth: Int = 0,
        sceneNumber: String? = nil,
        isDual: Bool = false
    ) -> Element {
        Element(
            kind: kind,
            range: line.rangeWithTerminator,
            lineIndex: line.index,
            text: text,
            forcingMark: mark,
            depth: depth,
            sceneNumber: sceneNumber,
            isDualDialogue: isDual
        )
    }

    // MARK: - Derived structure

    private static func buildScenes(elements: [Element], source: String) -> [ScriptScene] {
        let length = (source as NSString).length
        var scenes: [ScriptScene] = []
        var headings: [Int] = []
        for (offset, element) in elements.enumerated() where element.kind == .sceneHeading {
            headings.append(offset)
        }

        for (ordinal, start) in headings.enumerated() {
            let end = ordinal + 1 < headings.count ? headings[ordinal + 1] : elements.count
            let heading = elements[start]
            let slice = elements[start..<end]

            let synopsis = slice.first { $0.kind == .synopsis }?.text
            var characters: [String] = []
            for element in slice where element.kind == .character {
                let name = characterName(from: element.text)
                if !name.isEmpty, !characters.contains(name) { characters.append(name) }
            }

            let location = heading.range.location
            let upperBound = end < elements.count ? elements[end].range.location : length
            scenes.append(
                ScriptScene(
                    index: ordinal + 1,
                    number: heading.sceneNumber,
                    heading: heading.text,
                    synopsis: synopsis,
                    range: NSRange(location: location, length: max(upperBound - location, 0)),
                    elementRange: start..<end,
                    characters: characters
                )
            )
        }
        return scenes
    }

    /// Builds the `#`/`##` outline into a tree using an explicit depth stack.
    private static func buildSections(
        elements: [Element],
        scenes: [ScriptScene],
        source: String
    ) -> [SectionNode] {
        let length = (source as NSString).length
        var roots: [SectionNode] = []
        // Each entry is a node under construction plus the depth it sits at.
        var stack: [SectionNode] = []

        func attach(_ node: SectionNode) {
            if var parent = stack.popLast() {
                parent.children.append(node)
                stack.append(parent)
            } else {
                roots.append(node)
            }
        }

        func closeTo(depth: Int, end: Int) {
            while let last = stack.last, last.depth >= depth {
                var node = stack.removeLast()
                node.range = NSRange(
                    location: node.range.location,
                    length: max(end - node.range.location, 0)
                )
                attach(node)
            }
        }

        for (offset, element) in elements.enumerated() where element.kind == .section {
            closeTo(depth: element.depth, end: element.range.location)
            stack.append(
                SectionNode(
                    title: element.text,
                    depth: element.depth,
                    elementIndex: offset,
                    range: NSRange(location: element.range.location, length: 0)
                )
            )
        }
        closeTo(depth: 1, end: length)

        // Attribute each scene to the deepest section whose range contains it.
        func assign(_ nodes: inout [SectionNode]) {
            for position in nodes.indices {
                var node = nodes[position]
                assign(&node.children)
                let claimedByChild = Set(node.children.flatMap(\.sceneIndices))
                node.sceneIndices = scenes
                    .filter { NSLocationInRange($0.range.location, node.range) }
                    .map(\.index)
                    .filter { !claimedByChild.contains($0) }
                nodes[position] = node
            }
        }
        assign(&roots)
        return roots
    }

    private static func orderedCharacters(in elements: [Element]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for element in elements where element.kind == .character {
            let name = characterName(from: element.text)
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            ordered.append(name)
        }
        return ordered
    }
}
