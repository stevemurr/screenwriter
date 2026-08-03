import Foundation

/// Reports the ambiguity the parser deliberately swallowed.
///
/// **Policy: parse leniently, lint loudly** (Rule 9). `ScriptParser` resolves
/// every line to some element and never refuses input, which is the only way to
/// open the reference corpus at all — it contains en-dash sluglines, lowercase
/// headings, headings with no trailing period, and `.`/`>` used as generic force
/// marks. All of that is *legal* to us and *advice* here. Nothing this type
/// produces blocks anything.
///
/// Every rule was written against a construction that actually occurs in
/// `~/Code/github.com/stevemurr/screenplays`, and each is tuned so it does not
/// fire on the legitimate uses sitting next to it in the same files —
/// `.INT. STRIP CLUB` is forced 44 times in that corpus and must stay silent
/// while `.Open to a commercial…` speaks up. `CorpusGoldenTests` pins the hit
/// count per rule per script so a change in tuning cannot pass unnoticed.
///
/// This runs over elements rather than lines, so it is far cheaper than the
/// parse that produced them and does not share the parser's per-line
/// allocation discipline.
public enum Linter {

    /// Lints a parsed document. Results are in source order; within one offset,
    /// in rule-identifier order, so the output is deterministic.
    public static func lint(
        _ script: ParsedScript,
        rules: Set<LintRule> = Set(LintRule.allCases)
    ) -> [Diagnostic] {
        guard !rules.isEmpty, !script.elements.isEmpty else { return [] }
        let ns = script.source as NSString
        var diagnostics: [Diagnostic] = []

        for (offset, element) in script.elements.enumerated() {
            switch element.kind {
            case .section:
                if rules.contains(.sluglineAsSection) {
                    appendSluglineAsSection(element, ns, into: &diagnostics)
                }

            case .sceneHeading:
                if rules.contains(.sceneHeadingEnDash) {
                    appendEnDash(element, ns, into: &diagnostics)
                }
                if rules.contains(.ambiguousForcedMark) {
                    appendAmbiguousForcedHeading(element, ns, into: &diagnostics)
                }
                if rules.contains(.lowercaseSceneHeading) {
                    appendLowercaseHeading(element, ns, into: &diagnostics)
                }
                if rules.contains(.sceneHeadingSeparator) {
                    appendMissingSeparator(element, ns, into: &diagnostics)
                }
                if rules.contains(.sceneHeadingNeedsBlankLine) {
                    appendMissingBlankLine(
                        element,
                        previous: offset > 0 ? script.elements[offset - 1] : nil,
                        ns,
                        into: &diagnostics
                    )
                }

            case .transition:
                if rules.contains(.ambiguousForcedMark) {
                    appendAmbiguousForcedTransition(element, ns, into: &diagnostics)
                }

            case .character:
                if rules.contains(.trailingWhitespaceOnCue) {
                    appendTrailingWhitespace(element, ns, into: &diagnostics)
                }

            default:
                break
            }
        }

        if rules.contains(.duplicateSceneNumber) {
            appendDuplicateSceneNumbers(script, ns, into: &diagnostics)
        }

        diagnostics.sort {
            $0.range.location != $1.range.location
                ? $0.range.location < $1.range.location
                : $0.rule.rawValue < $1.rule.rawValue
        }
        return diagnostics
    }

    /// Diagnostics grouped by rule — the shape the corpus report and the golden
    /// files want.
    public static func counts(_ diagnostics: [Diagnostic]) -> [LintRule: Int] {
        diagnostics.reduce(into: [:]) { totals, diagnostic in
            totals[diagnostic.rule, default: 0] += 1
        }
    }

    // MARK: - slugline-as-section

    /// Six Trophy Boyz episodes write every heading as `## 1. EXT. RAVINE - DAY`.
    /// Highland treats sections as outline-only and leaves them out of the PDF,
    /// so those scripts export with no sluglines at all. The suggested fix keeps
    /// the writer's ordinal as a real `#1#` scene number, which is how the same
    /// writer numbers scenes in `anal-informant.fountain`.
    private static func appendSluglineAsSection(
        _ element: Element,
        _ ns: NSString,
        into diagnostics: inout [Diagnostic]
    ) {
        let (ordinal, remainder) = splitLeadingOrdinal(element.text)
        guard ScriptParser.isSceneHeading(remainder) else { return }

        let (heading, existingNumber) = ScriptParser.splitSceneNumber(remainder)
        let number = existingNumber ?? ordinal
        let fix = number.map { "\(heading) #\($0)#" } ?? heading

        diagnostics.append(
            Diagnostic(
                rule: .sluglineAsSection,
                message: """
                “\(heading)” is written as a section, so it is outline text — \
                it will not appear in the PDF as a scene heading at all.
                """,
                range: lineRange(of: element, in: ns),
                lineIndex: element.lineIndex,
                replacement: fix
            )
        )
    }

    /// Splits a leading `1.` or `12)` off a section title.
    ///
    /// Internal rather than private so the tests can pin the shape that decides
    /// whether the highest-value rule fires.
    static func splitLeadingOrdinal(_ text: String) -> (number: String?, rest: String) {
        var rest = Substring(text)
        var digits = ""
        while let character = rest.first, character.isASCII, character.isNumber {
            digits.append(character)
            rest = rest.dropFirst()
        }
        guard !digits.isEmpty, let separator = rest.first, separator == "." || separator == ")" else {
            return (nil, text)
        }
        rest = rest.dropFirst().drop { $0 == " " || $0 == "\t" }
        return (digits, String(rest))
    }

    // MARK: - scene-heading-en-dash

    /// `EXT. MOUNTAIN – MORNING #1#`. Four of these across two files, and they
    /// are invisible next to a hyphen at screenplay sizes. One diagnostic per
    /// dash, so accepting the fix is a single character replacement.
    private static func appendEnDash(
        _ element: Element,
        _ ns: NSString,
        into diagnostics: inout [Diagnostic]
    ) {
        let line = lineRange(of: element, in: ns)
        for offset in line.location..<(line.location + line.length)
        where ns.character(at: offset) == 0x2013 {
            diagnostics.append(
                Diagnostic(
                    rule: .sceneHeadingEnDash,
                    message: """
                    This scene heading separates with an en dash. Screenplay \
                    convention — and every tool that splits a heading into \
                    location and time of day — expects a hyphen.
                    """,
                    range: NSRange(location: offset, length: 1),
                    lineIndex: element.lineIndex,
                    replacement: "-"
                )
            )
        }
    }

    // MARK: - ambiguous-forced-mark

    /// `Ergosphere` uses `.` as a generic "force this line" mark:
    /// `.Open to a commercial for the company ENERSPHERE.` is meant as action
    /// but Fountain typesets it as a slugline.
    ///
    /// The gate is deliberately narrow, because the same corpus forces 30
    /// perfectly good headings with the same character. A forced heading is only
    /// suspicious when it carries **no INT/EXT/EST/I-E prefix at all** *and*
    /// reads like prose — lowercase letters anywhere, or simply too long to be a
    /// location. `.INT. STRIP CLUB` and an all-caps `.THE VOID` both stay
    /// silent; all fourteen of Ergosphere's misuses are caught.
    private static func appendAmbiguousForcedHeading(
        _ element: Element,
        _ ns: NSString,
        into diagnostics: inout [Diagnostic]
    ) {
        guard element.forcingMark == ".",
              !ScriptParser.isSceneHeading(element.text),
              containsLowercaseLetter(element.text) || element.text.utf8.count > 40
        else { return }

        diagnostics.append(
            Diagnostic(
                rule: .ambiguousForcedMark,
                message: """
                A leading “.” forces a scene heading, and this line reads like \
                action. It will be typeset as a slugline. Use “!” to force \
                action instead.
                """,
                range: NSRange(location: lineRange(of: element, in: ns).location, length: 1),
                lineIndex: element.lineIndex,
                replacement: "!"
            )
        )
    }

    /// The same misuse with `>`: `>What is the theme…` is a beat prompt, and
    /// Fountain right-aligns it on the page as a transition.
    ///
    /// A real transition is uppercase and usually ends in `TO:`, so requiring
    /// *both* lowercase letters and some length keeps `>TITLE CARD: THE GIG
    /// ECONOMY` — a legitimate forced transition in the corpus — quiet, while
    /// catching all 24 of Ergosphere's outline prompts. `>centred text<` never
    /// reaches here; the parser resolves it to `.centered`.
    private static func appendAmbiguousForcedTransition(
        _ element: Element,
        _ ns: NSString,
        into diagnostics: inout [Diagnostic]
    ) {
        guard element.forcingMark == ">",
              !element.text.hasSuffix("TO:"),
              containsLowercaseLetter(element.text),
              element.text.utf8.count > 30
        else { return }

        diagnostics.append(
            Diagnostic(
                rule: .ambiguousForcedMark,
                message: """
                A leading “>” forces a transition, and this line reads like a \
                note. It will be right-aligned on the page. Use “=” for a \
                synopsis line, which stays out of the printed script.
                """,
                range: NSRange(location: lineRange(of: element, in: ns).location, length: 1),
                lineIndex: element.lineIndex,
                replacement: "="
            )
        )
    }

    // MARK: - lowercase-scene-heading

    /// `INT. NEEL's WORK`, `INT. Horace apartment desk`. Only for headings that
    /// carry a recognised prefix — a forced heading with no prefix is prose, and
    /// `ambiguous-forced-mark` has more useful advice about it than "shout it".
    private static func appendLowercaseHeading(
        _ element: Element,
        _ ns: NSString,
        into diagnostics: inout [Diagnostic]
    ) {
        guard ScriptParser.isSceneHeading(element.text),
              containsLowercaseLetter(element.text)
        else { return }

        diagnostics.append(
            Diagnostic(
                rule: .lowercaseSceneHeading,
                message: "Scene headings are uppercase by convention.",
                range: textRange(of: element, in: ns),
                lineIndex: element.lineIndex,
                replacement: element.text.uppercased()
            )
        )
    }

    // MARK: - scene-heading-separator

    /// Bare prefixes, longest first so `INT/EXT` wins over `INT`.
    private static let bareSceneHeadingPrefixes = [
        "INT./EXT", "INT/EXT", "I/E", "INT", "EXT", "EST"
    ]

    /// `I/E MONTAGE IMAGE - CHRIS BACKGROUND` — the prefix runs straight into
    /// the location with no period.
    ///
    /// The character after the prefix decides: a period is correct, a space (or
    /// end of line) is the defect, and anything else means this was never that
    /// prefix — which is what keeps a forced `.INTERIOR OF A CAR` from being
    /// read as `INT` plus junk.
    private static func appendMissingSeparator(
        _ element: Element,
        _ ns: NSString,
        into diagnostics: inout [Diagnostic]
    ) {
        for prefix in bareSceneHeadingPrefixes {
            guard ScriptParser.hasUppercasedPrefix(element.text, prefix) else { continue }
            let after = element.text.utf8.dropFirst(prefix.utf8.count).first
            if after == 0x2E { return }                      // "." — conforming
            guard after == nil || after == 0x20 else { continue }

            let text = textRange(of: element, in: ns)
            diagnostics.append(
                Diagnostic(
                    rule: .sceneHeadingSeparator,
                    message: """
                    “\(prefix)” has no period after it. “\(prefix).” is the \
                    usual form, and some Fountain readers require it.
                    """,
                    range: NSRange(location: text.location, length: prefix.utf16.count),
                    lineIndex: element.lineIndex,
                    replacement: "\(prefix)."
                )
            )
            return
        }
    }

    // MARK: - trailing-whitespace-on-cue

    /// 302 lines in `anal-informant.fountain` end in stray spaces — Markdown's
    /// two-space hard break, left behind by a conversion. Only cues are worth
    /// flagging: everywhere else the whitespace is invisible and inert, but a
    /// cue's text is the key the cast list, autocomplete and any character
    /// report match on.
    private static func appendTrailingWhitespace(
        _ element: Element,
        _ ns: NSString,
        into diagnostics: inout [Diagnostic]
    ) {
        let line = lineRange(of: element, in: ns)
        var end = line.location + line.length
        while end > line.location {
            let character = ns.character(at: end - 1)
            guard character == 0x20 || character == 0x09 else { break }
            end -= 1
        }
        let trailing = line.location + line.length - end
        guard trailing > 0 else { return }

        diagnostics.append(
            Diagnostic(
                rule: .trailingWhitespaceOnCue,
                message: """
                This character cue ends in invisible whitespace, which can stop \
                it matching the same character elsewhere.
                """,
                range: NSRange(location: end, length: trailing),
                lineIndex: element.lineIndex,
                replacement: ""
            )
        )
    }

    // MARK: - duplicate-scene-number

    /// Two headings carrying the same `#N#`. Scene numbers are what sidecar
    /// metadata re-attaches by after a reorder, so a collision means two scenes
    /// competing for one set of notes. There is no safe automatic fix: only the
    /// writer knows which scene the number belongs to, so this is the one rule
    /// that offers no replacement.
    private static func appendDuplicateSceneNumbers(
        _ script: ParsedScript,
        _ ns: NSString,
        into diagnostics: inout [Diagnostic]
    ) {
        var firstLine: [String: Int] = [:]
        for scene in script.scenes {
            guard let number = scene.number, !number.isEmpty,
                  scene.elementRange.lowerBound < script.elements.count
            else { continue }
            let key = number.uppercased()
            guard let previous = firstLine[key] else {
                firstLine[key] = scene.elementRange.lowerBound
                continue
            }

            let element = script.elements[scene.elementRange.lowerBound]
            let line = lineRange(of: element, in: ns)
            var range = ns.range(of: "#\(number)#", options: .literal, range: line)
            if range.location == NSNotFound { range = line }

            diagnostics.append(
                Diagnostic(
                    rule: .duplicateSceneNumber,
                    message: """
                    Scene number #\(number)# is already used on line \
                    \(script.elements[previous].lineIndex + 1). Notes attached \
                    to one of these scenes will follow the other.
                    """,
                    range: range,
                    lineIndex: element.lineIndex
                )
            )
        }
    }

    // MARK: - scene-heading-needs-blank-line

    /// `## Beat 2: Dominic Kills Sal` followed immediately by
    /// `EXT. SALS COTTAGE - MORNING #3#`, 22 times in one script. We read it as
    /// a heading and so does Highland; the Fountain spec asks for the blank
    /// line, and a stricter reader demotes the heading to action without saying
    /// so — the same failure as `slugline-as-section`, arriving by a different
    /// route.
    private static func appendMissingBlankLine(
        _ element: Element,
        previous: Element?,
        _ ns: NSString,
        into diagnostics: inout [Diagnostic]
    ) {
        // Start of document counts as preceded by a blank. Boneyard is stripped
        // before anything reads the text, so it is not a separator either way.
        guard let previous, previous.kind != .blank, previous.kind != .boneyard else { return }

        let line = lineRange(of: element, in: ns)
        diagnostics.append(
            Diagnostic(
                rule: .sceneHeadingNeedsBlankLine,
                message: """
                No blank line before this scene heading. Fountain asks for one, \
                and a reader that insists will typeset the heading as action.
                """,
                range: line,
                lineIndex: element.lineIndex,
                replacement: "\n\(ns.substring(with: line))"
            )
        )
    }

    // MARK: - Source ranges

    /// The element's line without its terminator — what a squiggle should cover.
    private static func lineRange(of element: Element, in ns: NSString) -> NSRange {
        var range = element.range
        guard range.location >= 0, range.location + range.length <= ns.length else {
            return NSRange(location: min(max(range.location, 0), ns.length), length: 0)
        }
        while range.length > 0 {
            let last = ns.character(at: range.location + range.length - 1)
            guard last == 0x0A || last == 0x0D else { break }
            range.length -= 1
        }
        return range
    }

    /// The range of the element's *resolved* text inside its line — past any
    /// forcing mark and short of any `#42#` suffix. Located by search rather
    /// than arithmetic so it stays correct whatever the parser strips next;
    /// falls back to the whole line if the text has been rewritten beyond
    /// recognition.
    private static func textRange(of element: Element, in ns: NSString) -> NSRange {
        let line = lineRange(of: element, in: ns)
        guard !element.text.isEmpty else { return line }
        let found = ns.range(of: element.text, options: .literal, range: line)
        return found.location == NSNotFound ? line : found
    }

    /// True when any cased letter is lowercase. Mirrors
    /// `ScriptParser.isEffectivelyUppercase` from the other side, so a line with
    /// no letters at all reports neither.
    private static func containsLowercaseLetter(_ text: String) -> Bool {
        text.contains { $0.isLowercase }
    }
}
