import AppKit

// AppKit's entry point, not SwiftUI's `App` lifecycle.
//
// This is a deliberate departure from the `@main struct …: App` shell the other
// apps in this codebase use, and it was forced by evidence: a SwiftUI `App`
// declaring only a `Settings` scene launches, but `NSDocumentController` never
// receives the open-file event and no document window is ever created. SwiftUI's
// lifecycle only carries the document architecture through `DocumentGroup`,
// which was rejected for this app — a `FileDocument` cannot see the document's
// URL (needed to place the metadata sidecar beside a `.fountain`), cannot read
// or write `.screenplay` as a package, and copies the whole document on every
// keystroke.
//
// Going through `NSApplicationMain` gets the full document architecture — New,
// Open, Save, Save As, Revert, Open Recent, autosave-in-place, Versions, and
// window restoration — for free. SwiftUI still draws every view; it just does so
// inside `NSHostingView` under an AppKit window, exactly as
// `DocumentWindowController` sets up.
//
// The menu bar is built in `MainMenu.swift`, because with no NIB and no SwiftUI
// scene there is nothing else to build it.
// Top-level code in `main.swift` is the program entry point and therefore runs
// on the main thread, but it is not main-actor isolated in Swift 5 mode — hence
// the explicit assumption. `delegate` is a top-level binding so it stays alive
// for the life of the process; `NSApplication.delegate` does not retain it.
let delegate = MainActor.assumeIsolated { () -> AppDelegate in
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    return delegate
}
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
