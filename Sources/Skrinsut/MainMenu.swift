import AppKit

/// Main menu: Skrinsut / File / Edit / Draw / Zoom / Window.
/// Editor actions use nil targets so they travel the responder chain to the key editor window.
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        let app = submenu(main, "Skrinsut")
        app.addItem(withTitle: "About Skrinsut", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(item("Settings…", #selector(AppDelegate.showPreferences), ",", target: AppDelegate.shared))
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Skrinsut", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        // No Quit here: Skrinsut lives in the menu bar, so ⌘Q must not kill it. Quitting is
        // the menu-bar menu's Quit item only; ⌘W closes the key window and leaves it running.

        let file = submenu(main, "File")
        file.addItem(item("Copy Image", #selector(EditorWindowController.menuCopy(_:)), "c", [.command, .shift]))
        file.addItem(item("Save Image", #selector(EditorWindowController.menuSave(_:)), "s"))
        file.addItem(item("Save Image As…", #selector(EditorWindowController.menuSaveAs(_:)), "s", [.command, .shift]))
        file.addItem(item("Pin to Screen", #selector(EditorWindowController.menuPin(_:)), "p"))
        file.addItem(item("Print…", #selector(EditorWindowController.menuPrint(_:)), "p", [.command, .shift]))
        file.addItem(item("Recognize Text", #selector(EditorWindowController.recognizeText(_:)), "r", [.command, .shift]))
        file.addItem(.separator())
        file.addItem(item("Open File…", #selector(AppDelegate.openFile), "o", target: AppDelegate.shared))
        file.addItem(item("Open From Clipboard", #selector(AppDelegate.openFromClipboard), "v", [.command, .shift], target: AppDelegate.shared))
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let edit = submenu(main, "Edit")
        edit.addItem(item("Undo", #selector(EditorWindowController.undo(_:)), "z"))
        edit.addItem(item("Redo", #selector(EditorWindowController.redo(_:)), "z", [.command, .shift]))
        edit.addItem(item("Reset Crop", #selector(EditorWindowController.menuUncrop(_:)), ""))
        edit.addItem(item("Rasterize (Merge) Image", #selector(EditorWindowController.menuRasterize(_:)), ""))
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Delete", action: #selector(EditorWindowController.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // Draw: single-letter shortcuts are handled by the canvas; shown here for discoverability.
        let draw = submenu(main, "Draw")
        for tool in Tool.allCases {
            let i = NSMenuItem(title: tool.title, action: #selector(EditorWindowController.selectTool(_:)), keyEquivalent: "")
            i.representedObject = tool.rawValue
            if let key = tool.shortcut { i.title += "  (\(String(key).uppercased()))" }
            draw.addItem(i)
        }

        draw.addItem(.separator())
        draw.addItem(item("Snap to Objects", #selector(EditorWindowController.toggleSnapping(_:)), ""))
        draw.addItem(item("Add Capture", #selector(EditorWindowController.menuAddCapture(_:)), "a", [.command, .shift]))

        let zoom = submenu(main, "Zoom")
        zoom.addItem(item("Zoom In", #selector(EditorWindowController.menuZoomIn(_:)), "+"))
        zoom.addItem(item("Zoom Out", #selector(EditorWindowController.menuZoomOut(_:)), "-"))
        zoom.addItem(.separator())
        zoom.addItem(item("Zoom To Fit", #selector(EditorWindowController.menuZoomToFit(_:)), "1"))
        zoom.addItem(item("Zoom To 100%", #selector(EditorWindowController.menuZoomTo100(_:)), "0"))
        zoom.addItem(item("Zoom To Selection", #selector(EditorWindowController.menuZoomToSelection(_:)), "2"))

        let window = submenu(main, "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window

        return main
    }

    private static func submenu(_ parent: NSMenu, _ title: String) -> NSMenu {
        let item = parent.addItem(withTitle: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        return menu
    }

    private static func item(_ title: String, _ action: Selector, _ key: String,
                             _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.target = target
        return i
    }
}
