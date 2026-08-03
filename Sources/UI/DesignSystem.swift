import AppKit
import SwiftUI

/// Design tokens.
///
/// Everything resolves from system colours so the app tracks light and dark
/// appearance rather than hard-coding either — the same rule the rest of this
/// codebase follows. Nothing here is a literal RGB value except the element
/// accents, which are drawn from the system palette and therefore adapt too.
public enum Style {

    // MARK: - Element accents

    /// Colours for the Fountain source pane. In the mockups scene headings,
    /// character cues and transitions are tinted while body text stays default;
    /// structural marks (sections, synopses, notes) recede.
    public enum Element {
        public static let sceneHeading = NSColor.systemBlue
        public static let character = NSColor.systemTeal
        public static let transition = NSColor.systemIndigo
        public static let section = NSColor.systemPurple
        public static let synopsis = NSColor.secondaryLabelColor
        public static let note = NSColor.tertiaryLabelColor
        public static let boneyard = NSColor.tertiaryLabelColor
        public static let lyrics = NSColor.systemPink
        public static let body = NSColor.textColor
        /// Forcing marks (`@`, `!`, `.`, `>`, `#`) are dimmed rather than hidden.
        /// Hiding them would make display offsets diverge from storage offsets
        /// and force a mapping layer through selection, arrow keys, find and
        /// copy/paste — deliberately deferred.
        public static let forcingMark = NSColor.quaternaryLabelColor
    }

    // MARK: - Spacing and chrome

    public static let paneHeaderHeight: CGFloat = 38
    public static let statusBarHeight: CGFloat = 28
    public static let cornerRadius: CGFloat = 8
    public static let gutterWidth: CGFloat = 44

    /// Width of the action measure — the page's text column, 1.5" to 7.5".
    /// Styled mode lays out inside this so the editor column matches the page.
    public static let scriptColumnWidth: CGFloat = 453

    public static var editorBackground: NSColor { .textBackgroundColor }
    public static var paneBackground: NSColor { .controlBackgroundColor }
    public static var separator: NSColor { .separatorColor }
}

/// A pane header — the "FOUNTAIN · Plain Text ⌄" bar from the mockups.
struct PaneHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 12)
        .frame(height: Style.paneHeaderHeight)
        .background(Color(nsColor: Style.paneBackground))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: Style.separator))
                .frame(height: 1)
        }
    }
}
