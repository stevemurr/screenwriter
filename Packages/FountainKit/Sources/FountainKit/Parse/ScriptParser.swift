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
/// Parsing is a single linear pass, measured at ~15ms on the largest script in
/// the reference library (91 KB). That is too slow to run inline on a keystroke
/// and comfortably fast enough to run off the main actor behind a debounce,
/// which is what `ScreenplayModel` does — so there is deliberately no
/// incremental parser. `ScriptParserPerformanceTests` holds that trade honest.
///
/// The hot path is per-line and allocation-sensitive. Two rules follow, both
/// learned by measurement: never use `String.count` or `Character` iteration on
/// a whole line (they walk grapheme clusters — an ungated `raw.count >= 3` alone
/// cost 6ms), and never use `String.range(of:)` for a literal marker.
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

    private static func classify(
        _ raw: String,
        line: LineIndex.Line,
        index: LineIndex,
        previous: ElementKind?
    ) -> Element {
        let first = raw.first

        // `===` or longer is a page break; a single `=` is a synopsis. Order
        // matters — checking synopsis first would eat every page break.
        //
        // Gated on the first character, and counted in UTF-8. `String.count` is
        // a grapheme count, so an ungated `raw.count >= 3` walked every line of
        // the document in full before doing anything else — it was the single
        // largest cost in the parser.
        if first == "=", raw.utf8.count >= 3, raw.utf8.allSatisfy({ $0 == 0x3D }) {
            return make(.pageBreak, line, text: raw)
        }

        if let first {
            switch first {
            case "#":
                let depth = raw.prefix { $0 == "#" }.count
                // `#Act I` with no space after the hash appears in the corpus,
                // so the space is optional.
                let title = raw.dropFirst(depth).trimmingCharacters(in: .whitespaces)
                return make(.section, line, text: title, mark: "#", depth: depth)

            case "=":
                let text = raw.dropFirst().trimmingCharacters(in: .whitespaces)
                return make(.synopsis, line, text: text, mark: "=")

            case "!":
                return make(.action, line, text: String(raw.dropFirst()), mark: "!")

            case "@":
                return character(from: String(raw.dropFirst()), line: line, mark: "@")

            case "~":
                return make(.lyrics, line, text: String(raw.dropFirst()), mark: "~")

            case ">":
                let body = raw.dropFirst().trimmingCharacters(in: .whitespaces)
                if body.hasSuffix("<") {
                    let centered = body.dropLast().trimmingCharacters(in: .whitespaces)
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

        // A line that is entirely a note.
        if raw.hasPrefix("[["), raw.hasSuffix("]]") {
            let body = raw.dropFirst(2).dropLast(2).trimmingCharacters(in: .whitespaces)
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

    private static let sceneHeadingPrefixes = [
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
    public static func isSceneHeading(_ text: String) -> Bool {
        sceneHeadingPrefixes.contains { hasUppercasedPrefix(text, $0) }
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
    public static func markerOffset(_ text: String, _ first: UInt8, _ second: UInt8, from start: Int = 0) -> Int? {
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
        name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return false }
        // A cue is a name, not a sentence. This keeps a shouted line of action
        // from being promoted to a cue. UTF-8 rather than grapheme count: this
        // runs on every line that follows a blank one.
        guard name.utf8.count <= 60 else { return false }
        return isEffectivelyUppercase(name)
    }

    /// True when every cased letter is uppercase and at least one letter exists.
    /// Digits, punctuation, and accents pass through untested.
    public static func isEffectivelyUppercase(_ text: String) -> Bool {
        var sawLetter = false
        for character in text where character.isLetter {
            sawLetter = true
            if character.isLowercase { return false }
        }
        return sawLetter
    }

    // MARK: - Fragments

    /// Splits a trailing `#42#` scene number off a heading.
    public static func splitSceneNumber(_ text: String) -> (heading: String, number: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix("#"), trimmed.count > 2 else { return (trimmed, nil) }
        let withoutTrailing = trimmed.dropLast()
        guard let openIndex = withoutTrailing.lastIndex(of: "#") else { return (trimmed, nil) }
        let number = String(withoutTrailing[withoutTrailing.index(after: openIndex)...])
        guard !number.isEmpty, !number.contains(" ") else { return (trimmed, nil) }
        let heading = String(withoutTrailing[withoutTrailing.startIndex..<openIndex])
            .trimmingCharacters(in: .whitespaces)
        return (heading, number)
    }

    private static func character(
        from text: String,
        line: LineIndex.Line,
        mark: Character?
    ) -> Element {
        var body = text.trimmingCharacters(in: .whitespaces)
        var dual = false
        if body.hasSuffix("^") {
            dual = true
            body = String(body.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return make(.character, line, text: body, mark: mark, isDual: dual)
    }

    /// The cue's name with any `(V.O.)` extension and dual-dialogue caret
    /// removed — the key used for the cast list and autocomplete.
    public static func characterName(from cueText: String) -> String {
        var name = cueText
        if name.hasSuffix("^") { name = String(name.dropLast()) }
        if let open = name.firstIndex(of: "(") { name = String(name[name.startIndex..<open]) }
        return name.trimmingCharacters(in: .whitespaces)
    }

    private static func make(
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
