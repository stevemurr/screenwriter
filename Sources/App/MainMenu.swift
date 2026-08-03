import AppKit

/// Builds the menu bar.
///
/// There is no NIB and no SwiftUI scene to generate one, so it is assembled
/// here. Every item targets `nil`, which sends the action down the responder
/// chain — that is what lets `NSDocument` and `NSTextView` answer Save, Revert,
/// Undo, and the editing commands without this file knowing they exist.
@MainActor
enum MainMenu {
    static func install(appName: String = "Screenwriter") {
        let main = NSMenu()
        main.addItem(applicationMenu(appName: appName))
        main.addItem(fileMenu())
        main.addItem(editMenu())
        main.addItem(viewMenu())
        main.addItem(windowMenu())
        NSApp.mainMenu = main
    }

    private static func submenu(_ title: String, _ build: (NSMenu) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        build(menu)
        item.submenu = menu
        return item
    }

    private static func add(
        _ menu: NSMenu,
        _ title: String,
        _ action: Selector?,
        _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = .command,
        target: AnyObject? = nil
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        menu.addItem(item)
    }

    private static func applicationMenu(appName: String) -> NSMenuItem {
        submenu(appName) { menu in
            add(menu, "About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
            menu.addItem(.separator())
            add(menu, "Settings…", #selector(AppDelegate.showSettings(_:)), ",")
            menu.addItem(.separator())
            add(menu, "Hide \(appName)", #selector(NSApplication.hide(_:)), "h")
            add(menu, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
            add(menu, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
            menu.addItem(.separator())
            add(menu, "Quit \(appName)", #selector(NSApplication.terminate(_:)), "q")
        }
    }

    private static func fileMenu() -> NSMenuItem {
        submenu("File") { menu in
            add(menu, "New", #selector(NSDocumentController.newDocument(_:)), "n")
            add(menu, "Open…", #selector(NSDocumentController.openDocument(_:)), "o")

            // NSDocumentController populates this menu itself once it is tagged
            // with the standard "Open Recent" identity.
            let recents = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
            let recentsMenu = NSMenu(title: "Open Recent")
            recentsMenu.identifier = NSUserInterfaceItemIdentifier("NSRecentDocumentsMenu")
            add(recentsMenu, "Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:)))
            recents.submenu = recentsMenu
            menu.addItem(recents)

            menu.addItem(.separator())
            add(menu, "Close", #selector(NSWindow.performClose(_:)), "w")
            add(menu, "Save…", #selector(NSDocument.save(_:)), "s")
            add(menu, "Save As…", #selector(NSDocument.saveAs(_:)), "s", [.command, .shift])
            add(menu, "Revert to Saved", #selector(NSDocument.revertToSaved(_:)))
            menu.addItem(.separator())
            add(menu, "Page Setup…", #selector(NSDocument.runPageLayout(_:)), "p", [.command, .shift])
            add(menu, "Print…", #selector(NSDocument.printDocument(_:)), "p")
        }
    }

    private static func editMenu() -> NSMenuItem {
        submenu("Edit") { menu in
            add(menu, "Undo", Selector(("undo:")), "z")
            add(menu, "Redo", Selector(("redo:")), "z", [.command, .shift])
            menu.addItem(.separator())
            add(menu, "Cut", #selector(NSText.cut(_:)), "x")
            add(menu, "Copy", #selector(NSText.copy(_:)), "c")
            add(menu, "Paste", #selector(NSText.paste(_:)), "v")
            add(menu, "Select All", #selector(NSText.selectAll(_:)), "a")
            menu.addItem(.separator())
            add(menu, "Find…", #selector(NSTextView.performFindPanelAction(_:)), "f")
        }
    }

    private static func viewMenu() -> NSMenuItem {
        submenu("View") { menu in
            add(menu, "Toggle Scenes Sidebar", #selector(AppDelegate.toggleOutline(_:)), "1", [.command, .option])
            add(menu, "Toggle Page Preview", #selector(AppDelegate.togglePreview(_:)), "2", [.command, .option])
            menu.addItem(.separator())
            add(menu, "Plain Text", #selector(AppDelegate.showPlainText(_:)), "1", [.command, .shift])
            add(menu, "Styled", #selector(AppDelegate.showStyled(_:)), "2", [.command, .shift])
            menu.addItem(.separator())
            add(menu, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        }
    }

    private static func windowMenu() -> NSMenuItem {
        let item = submenu("Window") { menu in
            add(menu, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
            add(menu, "Zoom", #selector(NSWindow.performZoom(_:)))
            menu.addItem(.separator())
            add(menu, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        }
        NSApp.windowsMenu = item.submenu
        return item
    }
}
