import SwiftUI
import AppKit
import Combine

@main struct QuillApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { Settings { EmptyView() } }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let state = AppState()
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var settingsWindow: NSWindow?
    private var statusPanel: StatusPanel?
    private var statusDismissal: Task<Void, Never>?
    private var subscription: AnyCancellable?
    private var menuStatus: NSMenuItem?
    private var menuCancel: NSMenuItem?
    private var menuCopy: NSMenuItem?
    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.feather()
        item.button?.toolTip = "Quill — Better writing, one shortcut away."
        item.button?.setAccessibilityLabel("Quill menu")
        let menu = NSMenu()
        let status = menu.addItem(withTitle: "Select text, then press \(state.shortcutLabel)", action: nil, keyEquivalent: "")
        menuStatus = status
        let cancel = menu.addItem(withTitle: "Cancel correction", action: #selector(cancelCorrection), keyEquivalent: "")
        cancel.target = self; menuCancel = cancel
        let copy = menu.addItem(withTitle: "Copy last result", action: #selector(copyResult), keyEquivalent: "")
        copy.target = self; menuCopy = copy
        menu.addItem(.separator())
        let open = menu.addItem(withTitle: "Manual editor…", action: #selector(openQuill), keyEquivalent: "")
        open.target = self
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit Quill", action: #selector(quitQuill), keyEquivalent: "q")
        quit.target = self
        menu.autoenablesItems = false
        item.menu = menu; statusItem = item
        updateMenu()
        subscription = state.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateMenu() }
        }
        state.showWindow = { [weak self] in self?.showCorrection() }
        state.hideWindow = { [weak self] in self?.panel?.orderOut(nil) }
        state.showSettings = { [weak self] in self?.openSettings() }
        state.showStatus = { [weak self] in self?.showStatus() }
        state.hideStatus = { [weak self] in self?.statusDismissal?.cancel(); self?.statusPanel?.orderOut(nil) }
        state.restartApp = { [weak self] in self?.restart() }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--smoke-test") {
            showCorrection()
            Task { await smokeTest() }
            return
        }
        #endif
        Task { await state.codex.connect() }
        if ProcessInfo.processInfo.arguments.contains("--snapshot") {
            if ProcessInfo.processInfo.arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
            if ProcessInfo.processInfo.arguments.contains("--settings") { openSettings() } else { showCorrection() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.snapshot() }
        }
        if ProcessInfo.processInfo.arguments.contains("--request-permission") { state.selection.openPermissionSettings() }
        // Normal launch is menu-bar-only. Only explicit Manual editor opens the review UI.
        if ProcessInfo.processInfo.arguments.contains("--permission-check") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                self.state.refreshAccessibility()
                let report: [String: Any] = ["trusted": self.state.accessibility, "bundlePath": Bundle.main.bundlePath, "pid": getpid(), "reviewWindowOpen": self.panel?.isVisible == true]
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]) {
                    try? data.write(to: URL(fileURLWithPath: "/tmp/quill-permission.json"))
                }
            }
        }
    }
    @objc private func cancelCorrection() { state.cancel(dismiss: false); state.notice = "Cancelled — original text unchanged"; showStatus() }
    @objc private func copyResult() { state.copy() }
    private func updateMenu() {
        if ProcessInfo.processInfo.arguments.contains("--diagnostics") {
            let report: [String: Any] = ["trusted": state.accessibility, "reviewWindowOpen": panel?.isVisible == true,
                "busy": state.busy, "replacing": state.replacing, "hasError": state.error != nil,
                "replacementConfirmed": ReplacementDiagnostics.confirmed, "replacementMethod": ReplacementDiagnostics.method,
                "replacementSeconds": ReplacementDiagnostics.elapsed, "elapsedSeconds": state.elapsed ?? 0,
                "timing": state.codex.lastTiming?.dictionary ?? [:]]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]) {
                try? data.write(to: URL(fileURLWithPath: "/tmp/quill-diagnostics.json"), options: .atomic)
            }
        }
        menuCancel?.isEnabled = state.busy && !state.replacing
        menuCopy?.isEnabled = state.canCopy
        menuStatus?.isEnabled = false
        let message = state.error ?? ((state.busy || state.replacing) ? state.notice : "Select text, then press \(state.shortcutLabel)")
        menuStatus?.title = String(message.prefix(100))
        statusItem?.button?.image = state.busy || state.replacing ? NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Quill correcting") : Self.feather()
        statusItem?.button?.toolTip = message
    }
    private func showStatus() {
        statusDismissal?.cancel()
        if statusPanel == nil {
            let panel = StatusPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
            panel.level = .statusBar; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: InPlaceStatusView(state: state))
            statusPanel = panel
        }
        guard let panel = statusPanel, let view = panel.contentView, let screen = NSScreen.main else { return }
        let size = view.fittingSize
        panel.setContentSize(size)
        panel.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.maxX - size.width - 22, y: screen.visibleFrame.maxY - 16))
        panel.orderFrontRegardless() // Deliberately no NSApp.activate / makeKey call.
        if !state.busy && !state.replacing && state.error == nil {
            statusDismissal = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, let self, !self.state.busy, !self.state.replacing else { return }
                self.statusPanel?.orderOut(nil)
            }
        }
    }
    private func restart() {
        guard !state.replacing else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // App path is a positional argument, never interpolated as shell code.
        process.arguments = ["-c", "sleep 1; exec /usr/bin/open \"$1\"", "quill-restart", Bundle.main.bundlePath]
        try? process.run()
        NSApp.terminate(nil)
    }
    @objc private func openQuill() { if state.original.isEmpty { state.openManual() } else { showCorrection() } }
    @objc private func quitQuill() { NSApp.terminate(nil) }
    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 730), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Quill Settings"; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(state: state, codex: state.codex))
            window.center(); settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true); settingsWindow?.makeKeyAndOrderFront(nil)
    }
    private func showCorrection() {
        if panel == nil {
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Quill"; window.level = .floating
            window.isFloatingPanel = true; window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false; window.delegate = self
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.contentView = NSHostingView(rootView: CorrectionView(state: state, codex: state.codex))
            window.minSize = NSSize(width: 500, height: 540)
            window.center(); panel = window
        }
        NSApp.activate(ignoringOtherApps: true); panel?.makeKeyAndOrderFront(nil)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if state.replacing { return false }
        state.cancel(); return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if state.replacing { return .terminateCancel }
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) { state.shutdown() }
    static func feather() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill(); NSColor.black.setStroke()
            let p = NSBezierPath()
            p.move(to: NSPoint(x: 4, y: 4)); p.curve(to: NSPoint(x: 16, y: 17), controlPoint1: NSPoint(x: 2, y: 11), controlPoint2: NSPoint(x: 11, y: 17))
            p.curve(to: NSPoint(x: 7, y: 5), controlPoint1: NSPoint(x: 17, y: 9), controlPoint2: NSPoint(x: 12, y: 5))
            p.line(to: NSPoint(x: 11, y: 11)); p.close(); p.fill()
            let stem = NSBezierPath(); stem.move(to: NSPoint(x: 2, y: 1)); stem.line(to: NSPoint(x: 12, y: 12)); stem.lineWidth = 1.5; stem.lineCapStyle = .round; stem.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    #if DEBUG
    private func smokeTest() async {
        var report: [String: Any] = ["accessibilityGranted": state.selection.trusted, "shortcutRegistered": state.shortcutError == nil, "menuCreated": statusItem?.menu?.items.count == 4]
        await state.codex.connect()
        report["connected"] = state.codex.connected
        report["chatGPT"] = state.codex.chatGPT
        report["models"] = state.codex.models.map(\.id)
        state.manual = "i has send the files yesterday, please checks it."
        state.correctManual()
        let deadline = Date().addingTimeInterval(100)
        while state.busy && Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        report["correctionCompleted"] = state.hasResult
        report["elapsedSeconds"] = state.elapsed
        report["resultCharacters"] = state.result.count
        report["manualReplaceDisabled"] = !state.canReplace
        report["copyEnabled"] = state.canCopy
        report["error"] = state.error
        snapshot()
        let savedDefault = state.defaultStyle
        state.changeStyle(.concise)
        report["temporaryStylePreservedDefault"] = state.defaultStyle == savedDefault
        report["styleChangeInvalidatedResult"] = !state.hasResult
        state.generate()
        try? await Task.sleep(for: .milliseconds(100))
        state.cancel(dismiss: false)
        try? await Task.sleep(for: .milliseconds(500))
        report["cancelClearedResult"] = !state.busy && !state.hasResult
        state.generate()
        let retryDeadline = Date().addingTimeInterval(100)
        while state.busy && Date() < retryDeadline { try? await Task.sleep(for: .milliseconds(100)) }
        report["retryCompleted"] = state.hasResult
        report["retryError"] = state.error
        if let bytes = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? bytes.write(to: URL(fileURLWithPath: "/tmp/quill-smoke.json"))
        }
    }
    #endif

    private func snapshot() {
        guard let view = (ProcessInfo.processInfo.arguments.contains("--settings") ? settingsWindow : panel)?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/quill-window.png"))
    }
}

final class StatusPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
