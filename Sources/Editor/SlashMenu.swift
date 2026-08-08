import AppKit
import FountainKit
import SwiftUI

/// One row of the editor's popup menu, whichever menu it is.
///
/// The `/` catalogue and a completion list want identical chrome, identical keys
/// and identical placement, and differ only in what a row inserts. Sharing the
/// row type is what keeps them from drifting into two menus that behave almost
/// the same.
struct EditorMenuItem: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    /// Right-hand keycap: the Fountain shorthand, or what kind of thing this is.
    let trailing: String
    let symbol: String
    /// Text that replaces the range being completed.
    let insertion: String
    /// Where the caret lands, from the start of `insertion`. Nil means the end.
    let caretOffset: Int?

    func caretLocation(insertedAt location: Int) -> Int {
        location + (caretOffset ?? (insertion as NSString).length)
    }
}

extension SlashCommand {
    var menuItem: EditorMenuItem {
        EditorMenuItem(
            id: id,
            title: title,
            subtitle: subtitle,
            trailing: shorthand,
            symbol: symbol,
            insertion: snippet,
            caretOffset: caretOffset
        )
    }
}

extension Completion.Kind {
    var symbol: String {
        switch self {
        case .character: return "person.fill"
        case .location: return "mappin.and.ellipse"
        case .timeOfDay: return "clock"
        }
    }

    var label: String {
        switch self {
        case .character: return "cast"
        case .location: return "location"
        case .timeOfDay: return "time"
        }
    }
}

extension Completion.Result {
    /// Rows for a completion list. The subtitle says where the suggestion came
    /// from, because "this script already says this" is the whole value — a
    /// completion you cannot source is just a guess.
    var menuItems: [EditorMenuItem] {
        suggestions.map { suggestion in
            EditorMenuItem(
                id: "\(kind.rawValue):\(suggestion)",
                title: suggestion,
                subtitle: kind == .timeOfDay ? "Time of day" : "Used in this script",
                trailing: kind.label,
                symbol: kind.symbol,
                insertion: suggestion,
                caretOffset: nil
            )
        }
    }
}

/// State for the `/` menu, owned by `EditorHostView`.
///
/// Deliberately not a window. A floating `NSPanel` would steal key status from
/// the text view, and everything typed while the menu is open has to keep going
/// into the document — that is what makes it filter. So the menu is an ordinary
/// subview drawn over the editor, and the text view never stops being first
/// responder.
@MainActor
@Observable
final class SlashMenuModel {
    /// Which menu is open. They look the same and differ in one key: ⏎ commits a
    /// slash command, because there is nothing else Return could mean on a line
    /// holding only `/act`. On a completion the line is real text and Return
    /// means *new line* — so it only commits once the writer has picked a row
    /// with the arrows. Tab always commits.
    enum Kind: Equatable {
        case slash
        case completion
    }

    private(set) var kind: Kind = .slash
    private(set) var items: [EditorMenuItem] = []
    private(set) var selection = 0
    /// The text in the document that a choice replaces.
    private(set) var queryRange = NSRange(location: 0, length: 0)

    /// True once the writer has moved the highlight themselves.
    var hasChosenExplicitly: Bool { hasChosen }

    /// Whether the writer has taken over the highlight with the arrow keys.
    ///
    /// Until they do, typing re-ranks the list and the highlight belongs on
    /// whatever now ranks first — otherwise typing `/c`, which puts Character at
    /// the top, leaves the highlight on Act three rows down, and ⏎ inserts the
    /// wrong thing. Once they *have* arrowed, the choice is theirs and refining
    /// the query must not throw it away.
    private var hasChosen = false

    var isVisible: Bool { !items.isEmpty }
    var selected: EditorMenuItem? {
        items.indices.contains(selection) ? items[selection] : nil
    }

    /// Called on every text change and caret move.
    func update(kind: Kind, items: [EditorMenuItem], range: NSRange) {
        guard !items.isEmpty else {
            dismiss()
            return
        }
        let previous = hasChosen ? selected : nil
        self.kind = kind
        self.items = items
        queryRange = range
        selection = previous.flatMap { item in
            items.firstIndex(where: { $0.id == item.id })
        } ?? 0
    }

    func dismiss() {
        items = []
        selection = 0
        hasChosen = false
    }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        hasChosen = true
        selection = (selection + delta + items.count) % items.count
    }

    func select(_ item: EditorMenuItem) {
        guard let index = items.firstIndex(of: item) else { return }
        hasChosen = true
        selection = index
    }
}

/// The menu itself.
///
/// Every dimension here is fixed rather than measured. `NSHostingView`'s
/// `fittingSize` for a view containing a scroll view is not a number this can
/// place a panel with — the first version asked for it, got something unusable,
/// and drew the menu hanging off the bottom-left corner of the editor. The
/// controller needs to know the size *before* it can decide whether the menu
/// fits below the caret, so the size is arithmetic: rows times row height.
struct SlashMenuView: View {
    let model: SlashMenuModel
    let onCommit: (EditorMenuItem) -> Void

    static let width: CGFloat = 330
    static let rowHeight: CGFloat = 40
    static let padding: CGFloat = 6
    static let cornerRadius: CGFloat = 13
    /// Seven rows, so a partial eighth shows there is more below.
    static let maximumListHeight: CGFloat = rowHeight * 7 + rowHeight / 2

    static func height(rows: Int) -> CGFloat {
        min(CGFloat(rows) * rowHeight, maximumListHeight) + padding * 2
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, command in
                        row(command, isSelected: index == model.selection)
                            .frame(height: Self.rowHeight - 1)
                            .contentShape(Rectangle())
                            .onTapGesture { onCommit(command) }
                            .id(command.id)
                    }
                }
            }
            .scrollIndicators(.never)
            .onChange(of: model.selection) { _, _ in
                guard let id = model.selected?.id else { return }
                proxy.scrollTo(id, anchor: .center)
            }
        }
        .padding(Self.padding)
        .frame(
            width: Self.width,
            height: Self.height(rows: model.items.count),
            alignment: .leading
        )
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Self.cornerRadius))
        // Two hairlines: a light one inside the top edge and a darker one all
        // round. That pair is what reads as a raised macOS surface rather than a
        // rectangle with a border on it.
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                .blendMode(.plusLighter)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .strokeBorder(Color.black.opacity(0.14), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
        .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
        .accessibilityIdentifier("editor.slashMenu")
    }

    private func row(_ command: EditorMenuItem, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            // The icon tile carries the selection, which lets the row's own
            // highlight stay soft. A tinted glyph on a tinted tile reads as an
            // object; white-on-accent reads as chosen.
            Image(systemName: command.symbol)
                .font(.system(size: 13, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(
                            isSelected
                                ? AnyShapeStyle(Color.accentColor)
                                : AnyShapeStyle(Color.primary.opacity(0.07))
                        )
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(command.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                Text(command.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            // A keycap, not a label: the shorthand is the thing the menu is
            // teaching, so it needs to look like something you type.
            Text(command.trailing)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2.5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                )
                .layoutPriority(1)
        }
        .padding(.horizontal, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    isSelected
                        ? AnyShapeStyle(Color.accentColor.opacity(0.13))
                        : AnyShapeStyle(Color.clear)
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("slash.\(command.id)")
    }
}
