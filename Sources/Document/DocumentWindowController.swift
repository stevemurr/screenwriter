import AppKit
import SwiftUI

/// Hosts the SwiftUI document UI inside an AppKit document window.
///
/// The SwiftUI root lives in an `NSHostingView` rather than a `DocumentGroup`
/// scene, so `NSDocument` keeps ownership of the window, its title, autosave
/// state, and restoration.
@MainActor
final class DocumentWindowController: NSWindowController {
    private let screenplay: ScreenplayDocument

    init(document: ScreenplayDocument) {
        self.screenplay = document
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = false
        window.minSize = NSSize(width: 720, height: 480)
        window.center()
        window.setFrameAutosaveName("ScreenplayWindow")
        window.tabbingMode = .preferred
        super.init(window: window)

        window.contentView = NSHostingView(
            rootView: RootView(model: document.model, document: document)
        )
        // The subtitle carries the dirty/autosave state the mockups show under
        // the document name.
        window.subtitle = ""
        shouldCascadeWindows = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func synchronizeWindowTitleWithDocumentName() {
        super.synchronizeWindowTitleWithDocumentName()
        window?.subtitle = screenplay.isDocumentEdited ? "Edited" : "Autosaved"
    }
}
