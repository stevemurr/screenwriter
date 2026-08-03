import Foundation

/// A scene: one heading and everything under it, up to the next heading.
public struct ScriptScene: Sendable, Hashable, Identifiable {
    /// One-based ordinal in document order. Not stable across edits — use
    /// `number` or the heading when resolving sidecar metadata.
    public var index: Int
    /// A `#42#` suffix on the heading, hashes stripped. The reference corpus
    /// has 95 of these in a single script, so they are the primary identity
    /// signal when re-attaching metadata after a reorder.
    public var number: String?
    /// The heading as it reads, forcing mark and scene number removed.
    public var heading: String
    /// The first `= ` synopsis line under the heading, if any. Shown as the
    /// subtitle in the scenes sidebar.
    public var synopsis: String?
    /// UTF-16 range covering the heading through the last line before the next
    /// heading, trailing blanks included. Moving a scene means moving this.
    public var range: NSRange
    /// Indices into `ParsedScript.elements`.
    public var elementRange: Range<Int>
    /// Distinct character cues appearing in this scene, in first-appearance order.
    public var characters: [String]

    public var id: Int { index }

    public init(
        index: Int,
        number: String? = nil,
        heading: String,
        synopsis: String? = nil,
        range: NSRange,
        elementRange: Range<Int>,
        characters: [String] = []
    ) {
        self.index = index
        self.number = number
        self.heading = heading
        self.synopsis = synopsis
        self.range = range
        self.elementRange = elementRange
        self.characters = characters
    }
}

/// A node in the `#`/`##` outline hierarchy.
///
/// A tree rather than a flat list: the corpus nests `# Act One` over
/// `## Beat 1: Mountain Valley Establishing Shots`, and the sidebar renders
/// Acts over Sequences directly from this shape. Some documents are *entirely*
/// sections with no scenes at all, so a section tree with no scenes must render
/// sensibly.
public struct SectionNode: Sendable, Hashable, Identifiable {
    public var title: String
    /// 1 for `#`, 2 for `##`, and so on.
    public var depth: Int
    /// Index into `ParsedScript.elements`.
    public var elementIndex: Int
    /// UTF-16 range covering this section and everything beneath it.
    public var range: NSRange
    public var children: [SectionNode]
    /// Indices into `ParsedScript.scenes` directly under this node.
    public var sceneIndices: [Int]

    public var id: Int { elementIndex }

    public init(
        title: String,
        depth: Int,
        elementIndex: Int,
        range: NSRange,
        children: [SectionNode] = [],
        sceneIndices: [Int] = []
    ) {
        self.title = title
        self.depth = depth
        self.elementIndex = elementIndex
        self.range = range
        self.children = children
        self.sceneIndices = sceneIndices
    }
}

/// The result of parsing a document. Immutable, `Sendable`, and free of AppKit,
/// so it can be produced off the main actor and handed to the UI whole.
public struct ParsedScript: Sendable {
    /// The exact source this was parsed from. Held so consumers can verify a
    /// result is still current before applying it to a text view that may have
    /// moved on — the same guard the ported editor surface uses for highlights.
    public var source: String
    public var elements: [Element]
    public var titlePage: TitlePage?
    public var scenes: [ScriptScene]
    /// Top-level outline nodes; nested nodes hang off `children`.
    public var sections: [SectionNode]
    /// Distinct character cues in first-appearance order, for autocomplete and
    /// the cast list.
    public var characters: [String]

    public init(
        source: String,
        elements: [Element] = [],
        titlePage: TitlePage? = nil,
        scenes: [ScriptScene] = [],
        sections: [SectionNode] = [],
        characters: [String] = []
    ) {
        self.source = source
        self.elements = elements
        self.titlePage = titlePage
        self.scenes = scenes
        self.sections = sections
        self.characters = characters
    }

    public static let empty = ParsedScript(source: "")

    /// The scene containing a UTF-16 offset, for caret-to-sidebar syncing.
    public func scene(at offset: Int) -> ScriptScene? {
        scenes.last { $0.range.location <= offset }
    }

    /// Word count over printable text only — action, dialogue, and headings.
    /// Notes, synopses, sections, and boneyard are excluded, matching what the
    /// status bar in the mockups is counting.
    /// Counted over UTF-8 bytes rather than `Character`s.
    ///
    /// `split` breaks grapheme clusters over every printable line in the
    /// document — Rule 4's mistake one level down. On the 91 KB script, release,
    /// best of 20 on `CLOCK_THREAD_CPUTIME_ID`: **2.30ms splitting, 0.23ms
    /// scanning bytes**, for the identical count of 14,317.
    ///
    /// The same splitting code measured **20.33ms** before `LineIndex` stopped
    /// handing out bridged `NSString`s, which is worth recording because it is
    /// the more interesting number: nothing about this function changed to make
    /// it 9x faster. Every `element.text` was a `__NSCFString`, so walking it by
    /// `Character` paid an `objc_msgSend` per code unit — the parser fix repaid
    /// most of this cost as a side effect, in every consumer of `element.text`
    /// at once. Beware of profiles taken across that commit: a cost attributed
    /// here was, six sevenths of it, the string representation.
    ///
    /// A word is a maximal run of bytes that are not space, tab or newline,
    /// which is exactly what `split` counted: a UTF-8 continuation byte is
    /// always ≥ 0x80 and so never a separator, and no multi-byte character can
    /// contain one of these three bytes.
    public var wordCount: Int {
        var total = 0
        for element in elements {
            switch element.kind {
            case .action, .dialogue, .sceneHeading, .parenthetical, .transition,
                 .centered, .lyrics, .character:
                var inWord = false
                for byte in element.text.utf8 {
                    if byte == 0x20 || byte == 0x0A || byte == 0x09 {
                        inWord = false
                    } else if !inWord {
                        inWord = true
                        total += 1
                    }
                }
            case .section, .synopsis, .note, .boneyard, .blank, .pageBreak:
                break
            }
        }
        return total
    }
}
