import Foundation

extension Notification.Name {
    static let toolbarConfigChanged = Notification.Name("skrinsut.toolbarConfigChanged")
}

/// The editor toolbar's three configurable groups (Settings ▸ Toolbar).
enum ToolbarGroup: String, CaseIterable, Identifiable {
    case actions, tools, readouts
    var id: String { rawValue }

    var title: String {
        switch self {
        case .actions: "Quick Actions"
        case .tools: "Tools"
        case .readouts: "Readouts"
        }
    }

    var defaultItems: [String] {
        switch self {
        case .actions: ["copy", "save", "pin", "drag", "ocr"]
        case .tools:
            [Tool.select, .arrow, .text, .ruler, .rectangle, .blur, .freehand, .magnifier,
             .highlighter, .spotlight, .counter, .oval, .line, .crop].map(\.rawValue) + ["addCapture", "backdrop"]
        case .readouts: ["color", "size", "zoom"]
        }
    }

    private static let extras: [String: (title: String, symbol: String)] = [
        "copy": ("Copy Image", "doc.on.doc"),
        "save": ("Save Image", "square.and.arrow.down"),
        "pin": ("Pin to Screen", "pin"),
        "drag": ("Drag Out", "hand.draw"),
        "ocr": ("Recognize Text", "text.viewfinder"),
        "addCapture": ("Add Capture / Image", "photo.badge.plus"),
        "backdrop": ("Backdrop / Beautify", "sparkles.rectangle.stack"),
        "color": ("Color Picker", "eyedropper"),
        "size": ("Image Size", "ruler"),
        "zoom": ("Zoom", "magnifyingglass"),
    ]

    static func title(_ id: String) -> String { Tool(rawValue: id)?.title ?? extras[id]?.title ?? id }
    static func symbol(_ id: String) -> String { Tool(rawValue: id)?.symbol ?? extras[id]?.symbol ?? "questionmark" }
}

/// Toolbar order and visibility, stored in UserDefaults.
enum ToolbarConfig {
    private static var d: UserDefaults { .standard }
    private static let hiddenKey = "setting-toolbarHidden"
    private static func orderKey(_ g: ToolbarGroup) -> String { "setting-toolbarOrder-\(g.rawValue)" }

    /// Stored order, minus unknown ids, plus any default ids added since it was saved.
    static func order(_ g: ToolbarGroup) -> [String] {
        let defaults = g.defaultItems
        let stored = (d.stringArray(forKey: orderKey(g)) ?? []).filter(defaults.contains)
        return stored + defaults.filter { !stored.contains($0) }
    }

    static var hidden: Set<String> { Set(d.stringArray(forKey: hiddenKey) ?? []) }

    /// Visible items of a group, in order.
    static func visible(_ g: ToolbarGroup) -> [String] {
        let h = hidden
        return order(g).filter { !h.contains($0) }
    }

    static func setOrder(_ items: [String], for g: ToolbarGroup) {
        d.set(items, forKey: orderKey(g))
        changed()
    }

    static func setHidden(_ ids: Set<String>) {
        d.set(ids.sorted(), forKey: hiddenKey)
        changed()
    }

    static func reset() {
        ToolbarGroup.allCases.forEach { d.removeObject(forKey: orderKey($0)) }
        d.removeObject(forKey: hiddenKey)
        changed()
    }

    private static func changed() { NotificationCenter.default.post(name: .toolbarConfigChanged, object: nil) }
}
