import Foundation

/// The `/` menu's catalogue: every Fountain element, and the shorthand that
/// makes it.
///
/// Fountain's syntax is its whole appeal — `#` is an act, `@` forces a cue —
/// and also the entire barrier to using it, because none of it is discoverable.
/// This menu is a way in, not a replacement: every entry inserts the shorthand
/// it names and shows it on the row, so using the menu teaches the thing that
/// makes the menu unnecessary.
struct SlashCommand: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    /// What the element is, in the writer's terms rather than the spec's.
    let subtitle: String
    /// The Fountain shorthand, shown on the row so the menu teaches it.
    let shorthand: String
    let symbol: String
    /// Extra words the row should match on. The title is always matched.
    let keywords: [String]
    /// What replaces the typed `/query`.
    let snippet: String
    /// Where the caret lands, in UTF-16 units from the start of `snippet`.
    /// Defaults to the end, which is right for everything that is a prefix.
    let caretOffset: Int?

    init(
        id: String,
        title: String,
        subtitle: String,
        shorthand: String,
        symbol: String,
        keywords: [String] = [],
        snippet: String,
        caretOffset: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.shorthand = shorthand
        self.symbol = symbol
        self.keywords = keywords
        self.snippet = snippet
        self.caretOffset = caretOffset
    }

    /// Where the caret should sit once this command is inserted at `location`.
    func caretLocation(insertedAt location: Int) -> Int {
        location + (caretOffset ?? (snippet as NSString).length)
    }
}

extension SlashCommand {
    /// Ordered by how often a screenplay needs them, not by the spec's order.
    /// A writer opening this menu mid-script wants a scene or a cue; the
    /// structural containers come first because they are the ones nobody
    /// discovers on their own.
    static let all: [SlashCommand] = [
        SlashCommand(
            id: "act",
            title: "Act",
            subtitle: "Top-level container in the outline",
            shorthand: "#",
            symbol: "square.stack",
            keywords: ["section", "part", "container"],
            snippet: "# "
        ),
        SlashCommand(
            id: "sequence",
            title: "Sequence",
            subtitle: "Nests inside an act",
            shorthand: "##",
            symbol: "square.grid.2x2",
            keywords: ["section", "subsection", "beat", "container"],
            snippet: "## "
        ),
        SlashCommand(
            id: "scene-int",
            title: "Scene — Interior",
            subtitle: "A new slugline, indoors",
            shorthand: "INT.",
            symbol: "building.2",
            keywords: ["heading", "slugline", "inside"],
            snippet: "INT. "
        ),
        SlashCommand(
            id: "scene-ext",
            title: "Scene — Exterior",
            subtitle: "A new slugline, outdoors",
            shorthand: "EXT.",
            symbol: "tree",
            keywords: ["heading", "slugline", "outside"],
            snippet: "EXT. "
        ),
        SlashCommand(
            id: "character",
            title: "Character",
            subtitle: "The line under it becomes dialogue",
            shorthand: "@",
            symbol: "person",
            keywords: ["cue", "dialogue", "speaker", "who"],
            snippet: "@"
        ),
        SlashCommand(
            id: "parenthetical",
            title: "Parenthetical",
            subtitle: "A direction inside a speech",
            shorthand: "( )",
            symbol: "parentheses",
            keywords: ["wryly", "direction", "beat"],
            snippet: "()",
            caretOffset: 1
        ),
        SlashCommand(
            id: "action",
            title: "Action",
            subtitle: "Description — needs no mark at all",
            shorthand: "!",
            symbol: "text.alignleft",
            keywords: ["description", "scene", "prose", "narrative"],
            snippet: ""
        ),
        SlashCommand(
            id: "transition",
            title: "Transition",
            subtitle: "Right-aligned, like CUT TO:",
            shorthand: ">",
            symbol: "arrow.right.to.line",
            keywords: ["cut", "dissolve", "fade"],
            snippet: "> "
        ),
        SlashCommand(
            id: "centered",
            title: "Centered",
            subtitle: "Centred, like a title card",
            shorthand: "> <",
            symbol: "text.aligncenter",
            keywords: ["title card", "middle"],
            snippet: "> <",
            caretOffset: 2
        ),
        SlashCommand(
            id: "synopsis",
            title: "Synopsis",
            subtitle: "Outline only, never printed",
            shorthand: "=",
            symbol: "text.quote",
            keywords: ["summary", "outline", "note"],
            snippet: "= "
        ),
        SlashCommand(
            id: "note",
            title: "Note",
            subtitle: "A margin note, never printed",
            shorthand: "[[ ]]",
            symbol: "note.text",
            keywords: ["comment", "todo", "reminder"],
            snippet: "[[]]",
            caretOffset: 2
        ),
        SlashCommand(
            id: "lyrics",
            title: "Lyric",
            subtitle: "A sung line",
            shorthand: "~",
            symbol: "music.note",
            keywords: ["song", "singing", "music"],
            snippet: "~"
        ),
        SlashCommand(
            id: "page-break",
            title: "Page Break",
            subtitle: "Forces the next page",
            shorthand: "===",
            symbol: "rectangle.split.1x2",
            keywords: ["break", "new page"],
            snippet: "==="
        )
    ]

    /// Case- and diacritic-insensitive prefix-and-substring matching, ranked so
    /// that what you typed the start of comes first. An empty query matches
    /// everything, which is what makes a bare `/` a browsable list.
    static func matching(_ query: String, in catalogue: [SlashCommand] = all) -> [SlashCommand] {
        let needle = query.folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: nil
        )
        guard !needle.isEmpty else { return catalogue }

        func fold(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }

        var ranked: [(command: SlashCommand, rank: Int)] = []
        for command in catalogue {
            let title = fold(command.title)
            if title.hasPrefix(needle) {
                ranked.append((command, 0))
            } else if fold(command.shorthand).hasPrefix(needle) {
                ranked.append((command, 1))
            } else if title.contains(needle) {
                ranked.append((command, 2))
            } else if command.keywords.contains(where: { fold($0).contains(needle) }) {
                ranked.append((command, 3))
            }
        }
        // Stable within a rank, so the catalogue's own ordering survives.
        return ranked
            .enumerated()
            .sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }
            .map(\.element.command)
    }
}

/// Finds the `/query` the caret is sitting in, if any.
///
/// **Only at the start of an otherwise-empty line.** The corpus is full of
/// `INT./EXT.` and `I/E`, and prose has slashes in it, so a Notion-style
/// trigger-anywhere would pop the menu open mid-slugline and mid-sentence. It
/// costs nothing to restrict: every element this menu inserts begins a line
/// anyway.
enum SlashQuery {
    struct Match: Equatable {
        /// The `/query` text itself — what a chosen command replaces.
        var range: NSRange
        var query: String
    }

    static func detect(in source: NSString, caret: Int) -> Match? {
        guard caret >= 0, caret <= source.length else { return nil }
        let line = source.lineRange(for: NSRange(location: caret, length: 0))
        var contentsEnd = 0
        source.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: line)

        // The caret has to be at the end of what is typed. Arrowing back into
        // the middle of `/scene` means the writer is editing text, not picking
        // from a menu.
        guard caret == contentsEnd else { return nil }
        let content = NSRange(location: line.location, length: contentsEnd - line.location)
        guard content.length >= 1, source.substring(with: NSRange(location: content.location, length: 1)) == "/"
        else { return nil }

        let query = source.substring(
            with: NSRange(location: content.location + 1, length: content.length - 1)
        )
        // A space ends it: `/ ` is someone typing, not searching.
        guard !query.contains(" "), !query.contains("\t") else { return nil }
        return Match(range: content, query: query)
    }
}
