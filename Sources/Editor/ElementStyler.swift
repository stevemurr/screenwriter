import AppKit
import FountainKit

/// How the source pane renders. Both modes are editable and share one caret —
/// only the attributes applied to the same backing text differ.
public enum EditorMode: String, CaseIterable, Sendable {
    /// Monospace source with a line-number gutter and syntax colouring.
    case plainText
    /// Screenplay indents, Courier Prime, dimmed forcing marks. No gutter.
    case styled

    public var title: String {
        switch self {
        case .plainText: return "Plain Text"
        case .styled: return "Styled"
        }
    }
}

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
    }

    public let mode: EditorMode
    public let layout: PageLayout

    public init(mode: EditorMode, layout: PageLayout = .letter) {
        self.mode = mode
        self.layout = layout
    }

    /// Base attributes for the whole document, applied before per-element runs.
    public func baseAttributes() -> [NSAttributedString.Key: Any] {
        switch mode {
        case .plainText:
            return [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: Style.Element.body,
                .paragraphStyle: NSParagraphStyle.default
            ]
        case .styled:
            return [
                .font: ScreenplayFont.regular(size: layout.fontSize),
                .foregroundColor: Style.Element.body,
                .paragraphStyle: paragraphStyle(for: .action)
            ]
        }
    }

    public func runs(for script: ParsedScript) -> [Run] {
        var runs: [Run] = []
        runs.reserveCapacity(script.elements.count * 2)

        for element in script.elements {
            guard element.range.length > 0 else { continue }

            var attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: color(for: element.kind)
            ]
            if mode == .styled {
                attributes[.paragraphStyle] = paragraphStyle(for: element.kind)
                if let font = font(for: element.kind) { attributes[.font] = font }
            } else if let font = plainFont(for: element.kind) {
                attributes[.font] = font
            }
            runs.append(Run(range: element.range, attributes: attributes))

            // Dim the forcing mark in place. It stays selectable and copyable —
            // it is still really there — but stops competing with the prose.
            if let mark = element.forcingMark {
                let length = mark == "#" ? max(element.depth, 1) : 1
                let markRange = NSRange(location: element.range.location, length: length)
                if NSMaxRange(markRange) <= NSMaxRange(element.range) {
                    runs.append(
                        Run(range: markRange, attributes: [.foregroundColor: Style.Element.forcingMark])
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

    private func plainFont(for kind: ElementKind) -> NSFont? {
        switch kind {
        case .sceneHeading, .section:
            return .monospacedSystemFont(ofSize: 12, weight: .semibold)
        default:
            return nil
        }
    }

    private func font(for kind: ElementKind) -> NSFont? {
        switch kind {
        case .sceneHeading:
            // Highland underlines sluglines in its Final Draft exports; bold
            // reads better on screen and stays out of the PDF's way.
            return ScreenplayFont.bold(size: layout.fontSize)
        case .synopsis, .note:
            return ScreenplayFont.italic(size: layout.fontSize)
        default:
            return ScreenplayFont.regular(size: layout.fontSize)
        }
    }

    /// Screenplay indents expressed relative to the action column, so the text
    /// container is the page's text measure (1.5" to 7.5") and every element
    /// offsets from its left edge. These are the measured Highland positions in
    /// `PageLayout`, not approximations.
    private func paragraphStyle(for kind: ElementKind) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1
        style.minimumLineHeight = layout.lineHeight
        style.maximumLineHeight = layout.lineHeight

        switch kind {
        case .transition:
            style.alignment = .right
        case .centered, .pageBreak:
            style.alignment = .center
        default:
            style.alignment = .natural
            let head = layout.leftEdge(for: kind) - layout.actionLeft
            style.firstLineHeadIndent = head
            style.headIndent = head
            // Negative tail indents measure inward from the container's right
            // edge, which sits at the page's 7.5" line.
            style.tailIndent = -(layout.rightEdge - layout.rightEdge(for: kind))
        }
        return style
    }
}
