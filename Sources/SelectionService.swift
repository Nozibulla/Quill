import AppKit
import ApplicationServices
import Carbon
import CryptoKit

@MainActor final class ClipboardLease {
    private let pasteboard: NSPasteboard
    private let saved: [[NSPasteboard.PasteboardType: Data]]
    private var ownedCount: Int
    private var ownedText: String
    init(text: String, pasteboard: NSPasteboard = .general) throws {
        self.pasteboard = pasteboard
        let initialCount = pasteboard.changeCount
        var snapshots: [[NSPasteboard.PasteboardType: Data]] = []
        var size = 0
        for item in pasteboard.pasteboardItems ?? [] {
            var data: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard let bytes = item.data(forType: type) else { throw QuillError("Clipboard contains data that cannot be safely preserved. Use manual paste.") }
                size += bytes.count
                guard size < 32_000_000 else { throw QuillError("Clipboard is too large to preserve safely. Use manual paste.") }
                data[type] = bytes
            }
            snapshots.append(data)
        }
        guard pasteboard.changeCount == initialCount else { throw QuillError("Clipboard changed while preserving it. Try again.") }
        saved = snapshots
        pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
        ownedCount = pasteboard.changeCount; ownedText = text
    }
    var changeCount: Int { ownedCount }
    func adoptCopy(_ text: String) -> Bool {
        guard pasteboard.changeCount == ownedCount + 1 else { return false }
        ownedCount = pasteboard.changeCount; ownedText = text
        return true
    }
    func restore() {
        guard pasteboard.changeCount == ownedCount, pasteboard.string(forType: .string) == ownedText else { return }
        pasteboard.clearContents()
        let items = saved.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, bytes) in values { item.setData(bytes, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}

struct Destination {
    let application: NSRunningApplication
    let element: AXUIElement
    let window: AXUIElement?
    let fingerprint: SelectionFingerprint
    let valueHash: String?
}

@MainActor protocol SelectionAccess {
    var trusted: Bool { get }
    var frontmostIsQuill: Bool { get }
    func openPermissionSettings()
    func capture() async throws -> (String, Destination?)
    func valid(_ destination: Destination, requireFrontmost: Bool) -> Bool
    func replace(_ text: String, at destination: Destination, activateDestination: Bool) async throws
}

@MainActor final class SelectionService: SelectionAccess {
    var frontmostIsQuill: Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() }
    static let permissionHelp = "macOS has not granted access to this running copy of Quill. In Device Control and Data Access (Accessibility), remove the old Quill entry, add the app shown in Settings, enable it, then restart Quill."
    private var permissionProbeApplication: NSRunningApplication?
    var trusted: Bool {
        if AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary) { return true }
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() { permissionProbeApplication = app }
        // Some OS transitions can leave the trust flag stale. Only accept a real,
        // successful cross-process AX read as evidence of usable permission.
        // This is still enforced by macOS; no permission database is accessed.
        guard let app = permissionProbeApplication, !app.isTerminated, let element = focused(app) else { return false }
        var names: CFArray?
        return AXUIElementCopyAttributeNames(element, &names) == .success && names != nil
    }
    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    func openPermissionSettings() {
        requestPermission()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
    }
    func focused(_ app: NSRunningApplication) -> AXUIElement? {
        guard let value = attribute(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedUIElementAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
    func secure(_ element: AXUIElement) -> Bool {
        if IsSecureEventInputEnabled() { return true }
        var node: AXUIElement? = element
        for _ in 0..<8 {
            guard let current = node else { break }
            if attribute(current, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole { return true }
            guard let parent = attribute(current, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            node = unsafeBitCast(parent, to: AXUIElement.self)
        }
        return false
    }
    func range(_ element: AXUIElement) -> CFRange? {
        guard let raw = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = unsafeBitCast(raw, to: AXValue.self)
        var result = CFRange()
        guard AXValueGetType(value) == .cfRange, AXValueGetValue(value, .cfRange, &result), result.location >= 0, result.length > 0 else { return nil }
        return result
    }
    func selectedText(_ element: AXUIElement, range: CFRange) -> String? {
        if let text = attribute(element, kAXSelectedTextAttribute) as? String, !text.isEmpty { return text }
        if let value = readableValue(element) {
            let ns = value as NSString
            if range.location <= ns.length, range.length <= ns.length - range.location { return ns.substring(with: NSRange(location: range.location, length: range.length)) }
        }
        return nil
    }
    private func readableValue(_ element: AXUIElement) -> String? {
        if let value = attribute(element, kAXValueAttribute) as? String { return value }
        guard let count = attribute(element, kAXNumberOfCharactersAttribute) as? Int, count >= 0, count <= 1_000_000 else { return nil }
        var all = CFRange(location: 0, length: count)
        guard let parameter = AXValueCreate(.cfRange, &all) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value) == .success else { return nil }
        return value as? String
    }
    private func hash(_ element: AXUIElement) -> String? {
        guard let text = readableValue(element) else { return nil }
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func capture() async throws -> (String, Destination?) {
        ReplacementDiagnostics.confirmed = false
        ReplacementDiagnostics.method = "none"
        ReplacementDiagnostics.elapsed = 0
        guard trusted else { throw QuillError(Self.permissionHelp) }
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid(), let element = focused(app) else { throw QuillError("Select writing in another application, then press your Quill shortcut. You can also paste here.") }
        guard !secure(element) else { throw QuillError("Quill does not read secure input fields.") }
        guard let selection = range(element) else { throw QuillError("No verifiable text selection. Select text or paste it here manually.") }
        if let text = selectedText(element, range: selection), !text.isEmpty {
            let windowRaw = attribute(element, kAXWindowAttribute)
            let window = windowRaw.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? unsafeBitCast($0, to: AXUIElement.self) : nil }
            return (text, Destination(application: app, element: element, window: window,
                fingerprint: SelectionFingerprint(pid: app.processIdentifier, location: selection.location, length: selection.length, text: text), valueHash: hash(element)))
        }
        // Copy fallback requires an AX selection and a non-secure focused control.
        // It is capture-only: without independently readable selected text, Replace is unsafe.
        let lease = try ClipboardLease(text: "quill-capture-\(UUID().uuidString)")
        defer { lease.restore() }
        key(CGKeyCode(kVK_ANSI_C), pid: app.processIdentifier)
        try? await Task.sleep(for: .milliseconds(350))
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              let current = focused(app), CFEqual(current, element), !secure(current),
              let currentRange = range(current), currentRange.location == selection.location, currentRange.length == selection.length,
              let text = NSPasteboard.general.string(forType: .string), !text.isEmpty,
              lease.adoptCopy(text) else { throw QuillError("Could not safely capture that selection. Paste it into Quill instead.") }
        try Task.checkCancellation()
        return (text, nil)
    }
    func valid(_ destination: Destination, requireFrontmost: Bool = false) -> Bool {
        guard trusted, !destination.application.isTerminated,
              !requireFrontmost || NSWorkspace.shared.frontmostApplication?.processIdentifier == destination.application.processIdentifier,
              let current = focused(destination.application), CFEqual(current, destination.element), !secure(current),
              let selection = range(current), let text = selectedText(current, range: selection) else { return false }
        if let window = destination.window {
            guard let currentWindow = attribute(current, kAXWindowAttribute), CFEqual(window, currentWindow) else { return false }
        }
        if let expected = destination.valueHash, hash(current) != expected { return false }
        return destination.fingerprint.matches(SelectionFingerprint(pid: destination.application.processIdentifier, location: selection.location, length: selection.length, text: text))
    }
    func replace(_ text: String, at destination: Destination, activateDestination: Bool = true) async throws {
        guard valid(destination, requireFrontmost: !activateDestination) else { throw QuillError("The original field or selection changed. Nothing was replaced.") }
        if activateDestination {
            guard destination.application.activate(options: []) else { throw QuillError("Could not activate the original application. Copy the result instead.") }
            try await Task.sleep(for: .milliseconds(180))
        }
        try Task.checkCancellation()
        guard valid(destination, requireFrontmost: true) else { throw QuillError("The destination changed. Nothing was inserted; use Copy.") }
        ReplacementDiagnostics.confirmed = false
        ReplacementDiagnostics.method = "none"
        let started = Date()
        defer { ReplacementDiagnostics.elapsed = Date().timeIntervalSince(started) }
        if text == destination.fingerprint.text { ReplacementDiagnostics.confirmed = true; return }
        guard let before = readableValue(destination.element) else {
            throw QuillError("This editor cannot expose enough text to verify a replacement. Nothing was changed; use Copy.")
        }
        let plan = try ReplacementPlan(before: before, selection: destination.fingerprint, replacement: text)
        let lease = try ClipboardLease(text: text)
        guard valid(destination, requireFrontmost: true) else {
            lease.restore()
            throw QuillError("Selection changed before paste. Nothing was replaced.")
        }
        // Use the editor's normal paste command so web/controlled editors receive
        // their input/change events. AXSelectedText can return success without editing.
        ReplacementDiagnostics.method = "verifiedPaste"
        key(CGKeyCode(kVK_ANSI_V), pid: destination.application.processIdentifier)
        let read: () -> String? = { [self] in
            guard !destination.application.isTerminated,
                  let current = focused(destination.application), CFEqual(current, destination.element),
                  !secure(current) else { return nil }
            return readableValue(current)
        }
        if await ReplacementVerifier.confirm(expected: plan.expected, read: read) {
            lease.restore()
            ReplacementDiagnostics.confirmed = true
            return
        }
        // Do not paste a second time or claim success when the first attempt is
        // uncertain. A slow consumer can still read the temporary clipboard value.
        Task {
            if await ReplacementVerifier.confirm(expected: plan.expected, timeout: 20, read: read) { lease.restore() }
        }
        throw ReplacementUnconfirmed()
    }

    private func key(_ code: CGKeyCode, pid: pid_t) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        down?.flags = .maskCommand; up?.flags = .maskCommand
        down?.postToPid(pid); up?.postToPid(pid)
    }
}
