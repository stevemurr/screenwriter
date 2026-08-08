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
        public static let sceneHeading = NSColor.systemIndigo
        public static let character = NSColor.systemTeal
        public static let transition = NSColor.systemPurple
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

    public static let paneHeaderHeight: CGFloat = 40
    public static let statusBarHeight: CGFloat = 30
    public static let cornerRadius: CGFloat = 8

    public static let sidebarWidth: CGFloat = 268
    public static let inspectorWidth: CGFloat = 312
    public static let editorMinimumWidth: CGFloat = 420
    public static let previewMinimumWidth: CGFloat = 380
    public static let boardColumnWidth: CGFloat = 280

    /// Width of the action measure — the page's text column, 1.5" to 7.5".
    /// Styled mode lays out inside this so the editor column matches the page.
    public static let scriptColumnWidth: CGFloat = 453

    /// Semantic surfaces keep adjacent panes visually distinct while remaining
    /// fully appearance-adaptive. The generated mocks use this same hierarchy:
    /// quieter chrome, a focused writing surface, and a deeper preview well.
    public static var editorBackground: NSColor { .textBackgroundColor }
    public static var chromeBackground: NSColor { .windowBackgroundColor }
    public static var paneBackground: NSColor { .controlBackgroundColor }
    public static var sidebarBackground: NSColor { .controlBackgroundColor }
    public static var inspectorBackground: NSColor { .controlBackgroundColor }
    public static var canvasBackground: NSColor { .underPageBackgroundColor }
    public static var elevatedBackground: NSColor { .textBackgroundColor }
    public static var separator: NSColor { .separatorColor }

    /// Fixed paper colours are intentional: screenplay pages and beat cards are
    /// physical-paper metaphors in both appearances, just like the PDF preview.
    public static let paper = Color(red: 0.99, green: 0.985, blue: 0.97)
    public static let paperInk = Color(red: 0.08, green: 0.08, blue: 0.09)
    public static let paperSecondaryInk = Color(red: 0.34, green: 0.34, blue: 0.37)
}

/// A pane header — the "FOUNTAIN · Plain Text ⌄" bar from the mockups.
struct PaneHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
                .tracking(0.7)
            Spacer(minLength: 8)
            trailing
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .frame(height: Style.paneHeaderHeight)
        .background(Color(nsColor: Style.chromeBackground))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}
