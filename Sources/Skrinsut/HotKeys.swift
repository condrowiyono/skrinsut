import AppKit
import Carbon.HIToolbox

/// Global hotkey actions (Settings ▸ Shortcuts).
enum HotKeyAction: String, CaseIterable, Identifiable {
    case fullscreen, area, window, ocr, repeatArea, record

    var id: String { rawValue }
    var title: String {
        switch self {
        case .fullscreen: "Fullscreen screenshot"
        case .area: "Area screenshot"
        case .window: "Window screenshot"
        case .ocr: "Instant Text/QR Recognition"
        case .repeatArea: "Repeat area screenshot"
        case .record: "Record screen (start/stop)"
        }
    }

    var defaultCombo: KeyCombo? {
        let cmdShift = UInt32(cmdKey | shiftKey)
        switch self {
        case .fullscreen: return KeyCombo(keyCode: UInt32(kVK_ANSI_1), modifiers: cmdShift, display: "⇧⌘1")
        case .area: return KeyCombo(keyCode: UInt32(kVK_ANSI_2), modifiers: cmdShift, display: "⇧⌘2")
        case .window: return KeyCombo(keyCode: UInt32(kVK_ANSI_7), modifiers: cmdShift, display: "⇧⌘7")
        case .ocr: return KeyCombo(keyCode: UInt32(kVK_ANSI_8), modifiers: cmdShift, display: "⇧⌘8")
        case .repeatArea: return KeyCombo(keyCode: UInt32(kVK_ANSI_9), modifiers: cmdShift, display: "⇧⌘9")
        case .record: return KeyCombo(keyCode: UInt32(kVK_ANSI_6), modifiers: cmdShift, display: "⇧⌘6")
        }
    }
}

struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32   // Carbon modifier mask
    var display: String

    init(keyCode: UInt32, modifiers: UInt32, display: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.display = display
    }

    /// Builds a combo from a key-down event; requires at least one of ⌘ ⌃ ⌥.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .control, .option]).isEmpty else { return nil }
        var carbon: UInt32 = 0
        var symbols = ""
        if flags.contains(.control) { carbon |= UInt32(controlKey); symbols += "⌃" }
        if flags.contains(.option) { carbon |= UInt32(optionKey); symbols += "⌥" }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey); symbols += "⇧" }
        if flags.contains(.command) { carbon |= UInt32(cmdKey); symbols += "⌘" }
        let key = (event.charactersIgnoringModifiers ?? "?").uppercased()
        self.init(keyCode: UInt32(event.keyCode), modifiers: carbon, display: symbols + key)
    }
}

final class HotKeyManager {
    static let shared = HotKeyManager()
    var onAction: ((HotKeyAction) -> Void)?

    private var refs: [EventHotKeyRef] = []
    private var actionsByID: [UInt32: HotKeyAction] = [:]
    private var installed = false
    private static let signature: OSType = 0x534B_524E // 'SKRN'

    private func storageKey(_ a: HotKeyAction) -> String { "hotkey-\(a.rawValue)" }

    func combo(for action: HotKeyAction) -> KeyCombo? {
        let d = UserDefaults.standard
        if d.object(forKey: storageKey(action)) == nil { return action.defaultCombo }
        guard let data = d.data(forKey: storageKey(action)) else { return nil } // explicitly cleared
        return try? JSONDecoder().decode(KeyCombo.self, from: data)
    }

    func setCombo(_ combo: KeyCombo?, for action: HotKeyAction) {
        let d = UserDefaults.standard
        if let combo, let data = try? JSONEncoder().encode(combo) {
            d.set(data, forKey: storageKey(action))
        } else {
            d.set(Data(), forKey: storageKey(action)) // empty data == disabled
        }
        reload()
    }

    func install() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let id = hkID.id
            DispatchQueue.main.async { HotKeyManager.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, nil)
        reload()
    }

    func suspend() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        actionsByID.removeAll()
    }

    func reload() {
        suspend()
        for (i, action) in HotKeyAction.allCases.enumerated() {
            guard let combo = combo(for: action) else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: UInt32(i + 1))
            let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
                actionsByID[id.id] = action
            } else {
                NSLog("Skrinsut: failed to register hotkey \(combo.display) for \(action.rawValue) (\(status))")
            }
        }
    }

    private func fire(_ id: UInt32) {
        if let action = actionsByID[id] { onAction?(action) }
    }
}
