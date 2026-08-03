import AppKit
import FountainKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settingsWindow: NSWindow?

    static var isUITest: Bool { CommandLine.arguments.contains("--uitest") }

    static var isUnitTest: Bool {
        !isUITest && (
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
                || NSClassFromString("XCTestCase") != nil
        )
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Touching the shared controller before any open-file event arrives
        // makes `NSDocumentController` — not this delegate — the owner of every
        // document window.
        _ = NSDocumentController.shared
        MainMenu.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !ScreenplayFont.isCourierPrimeAvailable {
            // A packaging mistake here would surface as PDFs quietly a few
            // points off rather than as an error, so it is worth saying loudly.
            Log.render.error("Courier Prime did not register; falling back to Courier New.")
        }
        NSApp.activate(ignoringOtherApps: false)
    }

    /// A cold launch with no document opens exactly one untitled screenplay.
    /// Under test nothing opens, so a test starts from a known state.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        !Self.isUnitTest
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Menu actions

    /// The model behind the frontmost document window, or nil when the key
    /// window is Settings or there is no document.
    private var frontmostModel: ScreenplayModel? {
        (NSDocumentController.shared.currentDocument as? ScreenplayDocument)?.model
    }

    @objc func toggleOutline(_ sender: Any?) {
        frontmostModel.map { $0.showsOutline.toggle() }
    }

    @objc func togglePreview(_ sender: Any?) {
        frontmostModel.map { $0.showsPreview.toggle() }
    }

    @objc func showPlainText(_ sender: Any?) {
        frontmostModel?.mode = .plainText
    }

    @objc func showStyled(_ sender: Any?) {
        frontmostModel?.mode = .styled
    }

    @objc func showWriteMode(_ sender: Any?) { frontmostModel?.workspace = .write }
    @objc func showBoardMode(_ sender: Any?) { frontmostModel?.workspace = .board }
    @objc func showProductionMode(_ sender: Any?) {
        frontmostModel?.workspace = .production
        frontmostModel?.showsInspector = true
    }

    @objc func showTitlePage(_ sender: Any?) {
        guard frontmostModel != nil else { return }
        NotificationCenter.default.post(name: .showTitlePageInspector, object: nil)
    }

    @objc func showSettings(_ sender: Any?) {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: SettingsView())
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
    }
}
