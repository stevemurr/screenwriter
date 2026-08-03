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
    public var wordCount: Int {
        elements.reduce(into: 0) { total, element in
            switch element.kind {
            case .action, .dialogue, .sceneHeading, .parenthetical, .transition,
                 .centered, .lyrics, .character:
                total += element.text.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count
            case .section, .synopsis, .note, .boneyard, .blank, .pageBreak:
                break
            }
        }
    }
}
