import AppKit
import Carbon

@MainActor final class GlobalShortcut {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var registered: String?
    var action: (() -> Void)?
    static let choices: [(String, UInt32)] = [("E", UInt32(kVK_ANSI_E)), ("J", UInt32(kVK_ANSI_J)), ("K", UInt32(kVK_ANSI_K)), ("G", UInt32(kVK_ANSI_G))]
    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, pointer in
            guard let pointer else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<GlobalShortcut>.fromOpaque(pointer).takeUnretainedValue()
            Task { @MainActor in owner.action?() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func register(key: String, option: Bool) throws {
        let identity = "\(key)-\(option)"
        if registered == identity { return }
        let code = Self.choices.first { $0.0 == key }?.1 ?? UInt32(kVK_ANSI_E)
        let modifiers = UInt32(cmdKey | (option ? optionKey : shiftKey))
        var replacement: EventHotKeyRef?
        let status = RegisterEventHotKey(code, modifiers, EventHotKeyID(signature: 0x5155494C, id: 1), GetApplicationEventTarget(), 0, &replacement)
        guard status == noErr else { throw QuillError("Shortcut unavailable (macOS error \(status)). Choose a different combination; the previous shortcut remains active.") }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = replacement
        registered = identity
    }
    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil; handler = nil
    }
}
