import Foundation

/// What the caret is in the middle of typing, and what the script has already
/// called things like it.
///
/// Pure and offline: it takes the source, an offset, and a vocabulary, and
/// returns the range to replace plus the candidates. No view, no state, no
/// storage — which is what lets every rule below be a test rather than something
/// you have to reproduce with a keyboard.
public enum Completion {

    public enum Kind: String, Sendable, Hashable {
        case character
        case location
        case timeOfDay
    }

    public struct Result: Sendable, Equatable {
        public var kind: Kind
        /// The token being typed, which a chosen suggestion replaces.
        public var range: NSRange
        /// What has been typed so far.
        public var prefix: String
        /// Matches, best first.
        public var suggestions: [String]
    }

    /// The suggestions for the caret's position, or nil when nothing applies.
    ///
    /// Three contexts, and the boundaries between them are the whole design:
    ///
    /// * **A character cue.** An uppercase line with a blank line above it. This
    ///   is the one that has to be careful — `THE DOOR SLAMS OPEN` is action, and
    ///   the parser cannot tell it from a cue until the *next* line exists.
    ///   Completion runs before that line does, so it goes on what it can see and
    ///   only offers names already in the script. A cast list is a closed set; if
    ///   nothing in it starts with what you typed, there is nothing to offer and
    ///   the menu stays shut.
    /// * **A location**, after `INT. ` and before any ` - `.
    /// * **A time of day**, after the ` - `.
    ///
    /// The caret must be at the end of the line in all three. Editing the middle
    /// of a finished heading is not the same act as writing a new one.
    public static func suggest(
        in source: NSString,
        caret: Int,
        vocabulary: ScriptVocabulary
    ) -> Result? {
        guard caret >= 0, caret <= source.length else { return nil }
        let line = source.lineRange(for: NSRange(location: caret, length: 0))
        var contentsEnd = 0
        source.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: line)
        guard caret == contentsEnd else { return nil }

        let content = source.substring(
            with: NSRange(location: line.location, length: contentsEnd - line.location)
        )
        guard !content.isEmpty else { return nil }

        if let heading = headingResult(content, lineStart: line.location, vocabulary: vocabulary) {
            return heading
        }
        return characterResult(
            content,
            lineStart: line.location,
            source: source,
            vocabulary: vocabulary
        )
    }

    // MARK: - Scene headings

    private static func headingResult(
        _ content: String,
        lineStart: Int,
        vocabulary: ScriptVocabulary
    ) -> Result? {
        // A forced heading counts, so `.INT` completes too.
        var body = content
        var forcedOffset = 0
        if body.hasPrefix("."), !body.hasPrefix("..") {
            body = String(body.dropFirst())
            forcedOffset = 1
        }
        guard let prefix = SceneHeading.prefixes.first(where: {
            ScriptParser.hasUppercasedPrefix(body, $0)
        }) else { return nil }

        let afterPrefix = String(body.dropFirst(prefix.count))
        // `INT` with no space yet is still the prefix being typed, not a
        // location. Wait for the separator before offering anything.
        guard afterPrefix.isEmpty || afterPrefix.hasPrefix(" ") else { return nil }

        let rest = String(afterPrefix.drop(while: { $0 == " " }))
        let restStart = lineStart + forcedOffset + prefix.utf16.count
            + (afterPrefix.utf16.count - rest.utf16.count)

        if let separator = rest.range(of: " - ", options: .backwards)
            ?? rest.range(of: " – ", options: .backwards) {
            let typed = String(rest[separator.upperBound...])
            let start = restStart + rest[rest.startIndex..<separator.upperBound].utf16.count
            return result(
                kind: .timeOfDay,
                candidates: vocabulary.timesOfDay,
                typed: typed,
                range: NSRange(location: start, length: typed.utf16.count)
            )
        }

        // Still typing the location — but a trailing " -" means they are on
        // their way to the time of day, so offer nothing rather than the wrong
        // thing.
        guard !rest.hasSuffix("-"), !rest.hasSuffix("–") else { return nil }
        return result(
            kind: .location,
            candidates: vocabulary.locations,
            typed: rest,
            range: NSRange(location: restStart, length: rest.utf16.count)
        )
    }

    // MARK: - Character cues

    private static func characterResult(
        _ content: String,
        lineStart: Int,
        source: NSString,
        vocabulary: ScriptVocabulary
    ) -> Result? {
        var typed = content
        var offset = 0
        // A forced cue is unambiguous, and completing it needs no guessing about
        // context at all.
        if typed.hasPrefix("@") {
            typed = String(typed.dropFirst())
            offset = 1
        } else {
            guard isPrecededByBlankLine(lineStart, in: source) else { return nil }
            // Only what could still become a cue. Anything with a lowercase
            // letter in it is prose, and a cue is a name rather than a sentence
            // — the same 60-byte bound `ScriptParser.isCharacterCue` uses.
            guard !typed.isEmpty, typed.utf8.count <= 60,
                  ScriptParser.isEffectivelyUppercase(typed) || typed.allSatisfy({ !$0.isLowercase })
            else { return nil }
            guard !typed.contains("(") else { return nil }
        }
        guard !typed.isEmpty else { return nil }

        return result(
            kind: .character,
            candidates: vocabulary.characters,
            typed: typed,
            range: NSRange(location: lineStart + offset, length: typed.utf16.count)
        )
    }

    private static func isPrecededByBlankLine(_ lineStart: Int, in source: NSString) -> Bool {
        guard lineStart > 0 else { return true }
        let previous = source.lineRange(for: NSRange(location: lineStart - 1, length: 0))
        var contentsEnd = 0
        source.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: previous)
        let text = source.substring(
            with: NSRange(location: previous.location, length: contentsEnd - previous.location)
        )
        return text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Matching

    private static func result(
        kind: Kind,
        candidates: [String],
        typed: String,
        range: NSRange
    ) -> Result? {
        let matches = matching(typed, in: candidates)
        guard !matches.isEmpty else { return nil }
        // Nothing to offer when the only match is exactly what is already there.
        guard !(matches.count == 1 && matches[0].caseInsensitiveCompare(typed) == .orderedSame)
        else { return nil }
        return Result(kind: kind, range: range, prefix: typed, suggestions: matches)
    }

    /// Prefix matches first, then word-start matches inside the candidate, so
    /// `LOT` finds `PARKING LOT`. Never a bare substring match: `AR` should not
    /// offer `PARKING LOT`, because a completion list that answers everything is
    /// one you stop reading.
    static func matching(_ typed: String, in candidates: [String]) -> [String] {
        let needle = typed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard !needle.isEmpty else { return candidates }

        var prefixed: [String] = []
        var wordStart: [String] = []
        for candidate in candidates {
            let folded = candidate.folding(
                options: [.caseInsensitive, .diacriticInsensitive], locale: nil
            )
            if folded.hasPrefix(needle) {
                prefixed.append(candidate)
            } else if folded.split(separator: " ").dropFirst().contains(where: {
                $0.hasPrefix(needle)
            }) {
                wordStart.append(candidate)
            }
        }
        return prefixed + wordStart
    }
}
