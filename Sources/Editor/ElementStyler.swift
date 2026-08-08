import AppKit
import FountainKit

/// Turns a `ParsedScript` into text attributes.
///
/// Pure and synchronous: it takes a parse result and returns ranges plus
/// attributes, touching no view. That keeps it callable off the main actor and
/// lets the surface apply the result through exactly the same guarded path the
/// ported topside code uses for syntax highlighting.
///
/// **Never mutates the backing string.** Indents, colour, and font are all
/// attributes; the user's bytes are what they typed. That is what keeps
/// selection, arrow keys, find, and copy/paste behaving normally.
public struct ElementStyler: Sendable {
    /// `@unchecked` because `[NSAttributedString.Key: Any]` cannot be proven
    /// `Sendable`. The values are only ever `NSColor`, `NSFont`, and an already
    /// -copied `NSParagraphStyle` — immutable value-like objects that are safe
    /// to hand across an actor boundary. Nothing mutates a run after it is
    /// built.
    public struct Run: @unchecked Sendable {
        public let range: NSRange
        public let attributes: [NSAttributedString.Key: Any]
        /// Changes exactly when `attributes` would, and never merely because the
        /// run moved or its text grew.
        ///
        /// This is what lets `EditorHostView.applyStyle` tell "the writer typed a
        /// character into a line of dialogue" — every run styled identically,
        /// nothing to write — from "that line just became a character cue".
        /// Comparing the attribute dictionaries themselves is not an option:
        /// `[NSAttributedString.Key: Any]` is not `Equatable`, and the values are
        /// freshly-allocated `NSParagraphStyle`s that would compare by identity.
        ///
        /// `Hasher` is seeded per process, which is fine and deliberate: a
        /// signature is only ever compared against another one computed in the
        /// same process, moments earlier.
        public let signature: Int

        init(range: NSRange, attributes: [NSAttributedString.Key: Any], signature: Int) {
            self.range = range
            self.attributes = attributes
            self.signature = signature
        }
    }

    public let layout: PageLayout
    /// Type size for the editing surface. Scales the styled columns with it, so
    /// the page keeps its proportions at any size.
    public let fontSize: CGFloat

    public init(layout: PageLayout = .letter, fontSize: CGFloat = 12) {
        self.layout = layout
        self.fontSize = fontSize
    }

    /// Editor size over the page's own 12pt.
    private var scale: CGFloat { fontSize / layout.fontSize }

    /// Base attributes for the whole document, applied before per-element runs.
    public func baseAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: ScreenplayFont.regular(size: fontSize),
            .foregroundColor: Style.Element.body,
            .paragraphStyle: paragraphStyle(for: .action)
        ]
    }

    /// Underlines what the linter flagged, without changing anything else about
    /// the line. Applied after the element runs so it layers on top.
    public func diagnosticRuns(_ diagnostics: [Diagnostic], length: Int) -> [Run] {
        diagnostics.compactMap { diagnostic in
            guard diagnostic.range.length > 0,
                  NSMaxRange(diagnostic.range) <= length
            else { return nil }
            var hasher = Hasher()
            hasher.combine("diagnostic")
            hasher.combine(diagnostic.severity)
            // Length, unlike an element's, is part of what an underline *is*:
            // it is the extent of the thing being flagged.
            hasher.combine(diagnostic.range.length)
            return Run(
                range: diagnostic.range,
                attributes: [
                    .underlineStyle: NSUnderlineStyle.patternDot.rawValue
                        | NSUnderlineStyle.single.rawValue,
                    .underlineColor: diagnostic.severity == .warning
                        ? NSColor.systemOrange
                        : NSColor.tertiaryLabelColor
                ],
                signature: hasher.finalize()
            )
        }
    }

    public func runs(for script: ParsedScript) -> [Run] {
        runs(for: script.elements)
    }

    /// The element overload, so a window classified by `LiveClassifier` styles
    /// through exactly the same code as a full parse.
    public func runs(for elements: [Element]) -> [Run] {
        var runs: [Run] = []
        runs.reserveCapacity(elements.count * 2)

        for element in elements {
            guard element.range.length > 0 else { continue }

            var attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: color(for: element.kind)
            ]
            attributes[.paragraphStyle] = paragraphStyle(for: element.kind)
            if let font = font(for: element.kind) { attributes[.font] = font }
            // Deliberately *not* the range: an element whose text grew by one
            // character is styled identically, and that is the whole common case
            // of typing.
            var hasher = Hasher()
            hasher.combine(element.kind)
            runs.append(
                Run(
                    range: element.range,
                    attributes: attributes,
                    signature: hasher.finalize()
                )
            )

            // Dim the forcing mark in place. It stays selectable and copyable —
            // it is still really there — but stops competing with the prose.
            if let mark = element.forcingMark {
                let length = mark == "#" ? max(element.depth, 1) : 1
                let markRange = NSRange(location: element.range.location, length: length)
                if NSMaxRange(markRange) <= NSMaxRange(element.range) {
                    var markHasher = Hasher()
                    markHasher.combine("mark")
                    // `#` to `##` moves the boundary without changing any kind,
                    // so the mark run's length is part of its identity.
                    markHasher.combine(length)
                    runs.append(
                        Run(
                            range: markRange,
                            attributes: [.foregroundColor: Style.Element.forcingMark],
                            signature: markHasher.finalize()
                        )
                    )
                }
            }
        }
        return runs
    }

    // MARK: - Attributes by element

    private func color(for kind: ElementKind) -> NSColor {
        switch kind {
        case .sceneHeading: return Style.Element.sceneHeading
        case .character: return Style.Element.character
        case .transition, .centered: return Style.Element.transition
        case .section: return Style.Element.section
        case .synopsis: return Style.Element.synopsis
        case .note: return Style.Element.note
        case .boneyard: return Style.Element.boneyard
        case .lyrics: return Style.Element.lyrics
        case .pageBreak: return Style.Element.forcingMark
        case .action, .dialogue, .parenthetical, .blank: return Style.Element.body
        }
    }

    private func font(for kind: ElementKind) -> NSFont? {
        switch kind {
        case .sceneHeading:
            // Highland underlines sluglines in its Final Draft exports; bold
            // reads better on screen and stays out of the PDF's way.
            return ScreenplayFont.bold(size: fontSize)
        case .synopsis, .note:
            return ScreenplayFont.italic(size: fontSize)
        default:
            return ScreenplayFont.regular(size: fontSize)
        }
    }

    /// Screenplay indents expressed relative to the action column, so the text
    /// container is the page's text measure (1.5" to 7.5") and every element
    /// offsets from its left edge. These are the measured Highland positions in
    /// `PageLayout`, not approximations.
    private func paragraphStyle(for kind: ElementKind) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1
        style.minimumLineHeight = layout.lineHeight * scale
        style.maximumLineHeight = layout.lineHeight * scale

        switch kind {
        case .transition:
            style.alignment = .right
        case .centered, .pageBreak:
            style.alignment = .center
        default:
            style.alignment = .natural
            // Scaled with the type: at 20pt the dialogue column has to move
            // out too, or the screenplay stops looking like one.
            let head = (layout.leftEdge(for: kind) - layout.actionLeft) * scale
            style.firstLineHeadIndent = head
            style.headIndent = head
            // Negative tail indents measure inward from the container's right
            // edge, which sits at the page's 7.5" line.
            style.tailIndent = -(layout.rightEdge - layout.rightEdge(for: kind)) * scale
        }
        return style
    }
}
