import Foundation

/// Moving scenes and sections around in the source.
///
/// The Beat Board drags scene cards between sequence columns, and a drop has to
/// rewrite the Fountain text — the document is the model, not a projection of
/// one. This is the whole reason `ScriptScene.range` and `SectionNode.range`
/// cover *everything* under a heading, blank lines and boneyard included: a move
/// is then one contiguous range relocated, which is both correct and a single
/// undoable edit.
///
/// Everything here is a pure `String` transformation so it can be tested without
/// a text view, and applied as one `NSTextStorage` replacement so ⌘Z restores
/// both the text and the board in one step.
public enum SceneReorder {

    /// A single replacement: what to cut, and what to put where.
    ///
    /// Returned rather than applied so the caller can hand it to
    /// `NSTextStorage.replaceCharacters(in:with:)` inside one undo group.
    public struct Edit: Sendable, Hashable {
        /// The range in the *original* source to replace.
        public var range: NSRange
        public var replacement: String
        /// Where the moved block starts once the edit is applied, so the caret
        /// and the sidebar selection can follow it.
        public var resultingOffset: Int
    }

    /// Moves the scene at `index` so it sits immediately before the scene at
    /// `target`, or at the end of the script when `target` is nil.
    ///
    /// Returns nil when the move is a no-op or the indices do not exist, so a
    /// drag that lands where it started does not dirty the document.
    public static func move(
        sceneAt index: Int,
        before target: Int?,
        in script: ParsedScript
    ) -> Edit? {
        guard let moving = script.scenes.first(where: { $0.index == index }),
              let range = movableRange(ofSceneAt: index, in: script)
        else { return nil }
        let destination: NSRange
        if let target {
            guard let scene = script.scenes.first(where: { $0.index == target }) else { return nil }
            guard scene.index != moving.index else { return nil }
            destination = NSRange(location: scene.range.location, length: 0)
        } else {
            guard moving.index != script.scenes.last?.index else { return nil }
            let end = script.scenes.reduce(0) { max($0, NSMaxRange($1.range)) }
            destination = NSRange(location: end, length: 0)
        }
        return move(range: range, to: destination.location, in: script.source)
    }

    /// What moving a scene should actually relocate.
    ///
    /// **Not `ScriptScene.range`.** A scene's range runs to the *next scene
    /// heading*, and a section heading between two scenes falls inside it — so
    /// on the corpus shape of `## Arrival` over two scenes, the second scene's
    /// range contains `## The Test`. Moving that scene took the next sequence's
    /// heading along with it and quietly restructured the outline. Measured on
    /// the board's own fixture: two of four scenes carried a heading they did
    /// not own.
    ///
    /// `ScriptScene.range` is right for what it is for — a scene *is* everything
    /// under its heading, which is what makes the preview and the metadata
    /// anchors work. It is the wrong span to pick up and carry.
    public static func movableRange(ofSceneAt index: Int, in script: ParsedScript) -> NSRange? {
        guard let scene = script.scenes.first(where: { $0.index == index }) else { return nil }
        // Everything after the heading itself, up to the first section heading.
        for offset in scene.elementRange.dropFirst() where script.elements[offset].kind == .section {
            let clipped = script.elements[offset].range.location - scene.range.location
            guard clipped > 0 else { return nil }
            return NSRange(location: scene.range.location, length: clipped)
        }
        return scene.range
    }

    /// Moves a whole section — an act or a sequence — and everything beneath it.
    public static func move(
        section: SectionNode,
        before target: SectionNode?,
        in script: ParsedScript
    ) -> Edit? {
        let destination: Int
        if let target {
            guard target.elementIndex != section.elementIndex else { return nil }
            destination = target.range.location
        } else {
            destination = (script.source as NSString).length
        }
        return move(range: section.range, to: destination, in: script.source)
    }

    /// The primitive: relocate `range` so it begins at `insertion`.
    ///
    /// `insertion` is an offset in the *original* string; the returned edit is
    /// expressed against that same original string.
    public static func move(range: NSRange, to insertion: Int, in source: String) -> Edit? {
        let ns = source as NSString
        guard range.location >= 0, NSMaxRange(range) <= ns.length, range.length > 0 else {
            return nil
        }
        // Dropping a block inside itself is a no-op, not an error.
        guard insertion <= range.location || insertion >= NSMaxRange(range) else { return nil }
        guard insertion != range.location else { return nil }

        var block = ns.substring(with: range)
        // A block lifted from the end of the document may have no trailing
        // newline; it needs one once something follows it.
        if !block.hasSuffix("\n") { block += "\n" }
        // Separation between scenes is a blank line. Normalising here means a
        // move never welds two scenes together or leaves a growing gap behind,
        // however ragged the spacing was around the original.
        block = block.trimmingTrailingNewlines() + "\n\n"

        // Rewrite the whole span between the block and its destination in one
        // replacement, so the edit is a single undoable operation.
        if insertion < range.location {
            let span = NSRange(location: insertion, length: NSMaxRange(range) - insertion)
            let between = ns.substring(with: NSRange(
                location: insertion,
                length: range.location - insertion
            ))
            let replacement = block + between.trimmingTrailingNewlines() + "\n\n"
            guard replacement != ns.substring(with: span) else { return nil }
            return Edit(range: span, replacement: replacement, resultingOffset: insertion)
        } else {
            let span = NSRange(location: range.location, length: insertion - range.location)
            let between = ns.substring(with: NSRange(
                location: NSMaxRange(range),
                length: insertion - NSMaxRange(range)
            ))
            let replacement = between.trimmingTrailingNewlines() + "\n\n" + block
            guard replacement != ns.substring(with: span) else { return nil }
            let offset = insertion - range.length + (replacement.utf16.count - span.length)
            return Edit(
                range: span,
                replacement: replacement,
                resultingOffset: max(offset, 0)
            )
        }
    }

    /// Applies an edit to a string. The app applies it to `NSTextStorage`
    /// instead, so undo sees one operation; this exists for tests and for
    /// headless tools.
    public static func apply(_ edit: Edit, to source: String) -> String {
        (source as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }
}

private extension String {
    func trimmingTrailingNewlines() -> String {
        var text = Substring(self)
        while let last = text.last, last == "\n" || last == "\r" {
            text = text.dropLast()
        }
        return String(text)
    }
}
