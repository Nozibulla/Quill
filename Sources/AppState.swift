import AppKit
import Combine
import ServiceManagement

@MainActor final class AppState: ObservableObject {
    private let defaults: UserDefaults
    let codex = CodexService()
    let selection: any SelectionAccess
    private let corrector: ((String, WritingStyle, String) async throws -> String)?
    let shortcut = GlobalShortcut()
    @Published var original = ""
    @Published var result = ""
    @Published var manual = ""
    @Published var style: WritingStyle = .natural
    @Published var busy = false
    @Published var replacing = false
    @Published var hasResult = false
    @Published var error: String?
    @Published var notice = "Select writing in another app, or paste it below."
    @Published var elapsed: Double?
    @Published var destinationValid = false
    @Published var accessibility = false
    @Published var shortcutError: String?
    @Published var shortcutLabel = "⌘⇧E"
    @Published var launchError: String?
    @Published var defaultStyle: WritingStyle { didSet { defaults.set(defaultStyle.rawValue, forKey: "style") } }
    @Published var customStyle: String { didSet { defaults.set(String(customStyle.prefix(500)), forKey: "customStyle") } }
    @Published var modelID: String { didSet { defaults.set(modelID, forKey: "model") } }
    @Published var preferFast: Bool { didSet { defaults.set(preferFast, forKey: "preferFast") } }
    var serviceTier: String { preferFast && chosenModel?.supportsFast == true ? "priority" : "default" }
    var speedLabel: String { serviceTier == "priority" ? "Fast" : "Standard" }
    @Published var shortcutKey: String
    @Published var optionModifier: Bool
    @Published private(set) var inPlace = false
    @Published private(set) var permissionIssue = false
    private var inPlaceGuard = InPlaceGuard()
    private var capturing = false
    private var destination: Destination?
    private var operation: Task<Void, Never>?
    private var gate = RevisionGate()
    private var timer: Timer?
    var showStatus: (() -> Void)?
    var hideStatus: (() -> Void)?
    var restartApp: (() -> Void)?
    var showWindow: (() -> Void)?
    var hideWindow: (() -> Void)?
    var showSettings: (() -> Void)?
    var chosenModel: ModelOption? { ModelOption.preferred(codex.models, saved: modelID) }
    var canReplace: Bool { hasResult && !busy && !replacing && destinationValid && !result.isEmpty }
    var canCopy: Bool { hasResult && !busy && !replacing && !result.isEmpty }
    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    init(defaults: UserDefaults = .standard, registerShortcut: Bool = true,
         selection: (any SelectionAccess)? = nil,
         corrector: ((String, WritingStyle, String) async throws -> String)? = nil) {
        self.defaults = defaults
        self.selection = selection ?? SelectionService()
        self.corrector = corrector
        defaultStyle = WritingStyle(rawValue: defaults.string(forKey: "style") ?? "") ?? .natural
        customStyle = defaults.string(forKey: "customStyle") ?? ""
        modelID = defaults.string(forKey: "model") ?? ""
        preferFast = defaults.bool(forKey: "preferFast")
        shortcutKey = defaults.string(forKey: "shortcutKey") ?? "E"
        optionModifier = defaults.bool(forKey: "optionModifier")
        shortcut.action = { [weak self] in self?.capture() }
        if registerShortcut { self.registerShortcut() }
        accessibility = self.selection.trusted
        timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshAccessibility()
                self.destinationValid = self.destination.map { self.selection.valid($0, requireFrontmost: self.inPlace) } ?? false
                if self.inPlace && self.busy && self.destination != nil { self.inPlaceGuard.observe(valid: self.destinationValid) }
            }
        }
    }
    func registerShortcut() {
        do {
            try shortcut.register(key: shortcutKey, option: optionModifier)
            defaults.set(shortcutKey, forKey: "shortcutKey")
            defaults.set(optionModifier, forKey: "optionModifier")
            shortcutLabel = "⌘\(optionModifier ? "⌥" : "⇧")\(shortcutKey)"
            shortcutError = nil
        } catch { shortcutError = error.localizedDescription }
    }
    func setLaunch(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchError = SMAppService.mainApp.status == .requiresApproval ? "Approve Quill in System Settings → General → Login Items." : nil
            objectWillChange.send()
        } catch { launchError = error.localizedDescription }
    }
    func openManual() {
        guard !replacing else { return }
        invalidate(); inPlace = false; hideStatus?()
        original = ""; result = ""; manual = ""; destination = nil; destinationValid = false; style = defaultStyle
        notice = "Paste a short message to get started. Results are copied manually."
        showWindow?()
    }
    private func invalidate() {
        _ = gate.advance()
        operation?.cancel(); operation = nil
        if busy { codex.cancelCorrection() }
        busy = false; hasResult = false; error = nil; permissionIssue = false; elapsed = nil
    }
    /// The global shortcut never opens or activates the review editor.
    func capture() {
        guard !replacing else { return }
        if busy || capturing { cancel(dismiss: false); notice = "Cancelled — original text unchanged"; showStatus?(); return }
        guard !selection.frontmostIsQuill else {
            error = "Select text in the app where you are writing, then press \(shortcutLabel)."; showStatus?(); return
        }
        capturing = true
        invalidate(); inPlace = true
        let revision = gate.id
        destination = nil; destinationValid = false; original = ""; result = ""; style = defaultStyle
        notice = "Reading selection…"; showStatus?()
        operation = Task {
            defer { capturing = false }
            do {
                let captured = try await selection.capture()
                guard gate.accepts(revision), !Task.isCancelled else { return }
                guard let target = captured.1 else { throw QuillError("This editor does not expose a verifiable selection for safe replacement. No text was changed.") }
                original = captured.0; destination = target
                destinationValid = selection.valid(target, requireFrontmost: true)
                guard destinationValid else { throw QuillError("Selection changed during capture. Select the writing and try again.") }
                generate(inPlace: true)
            } catch {
                guard gate.accepts(revision), !Task.isCancelled else { return }
                permissionIssue = !selection.trusted
                self.error = error.localizedDescription; notice = "Nothing changed"; showStatus?()
            }
        }
    }
    func refreshAccessibility(granted: Bool? = nil) {
        accessibility = granted ?? selection.trusted
        if accessibility && permissionIssue {
            permissionIssue = false; error = nil
            notice = "Access granted — select text and press \(shortcutLabel)"
        }
    }
    func correctManual() {
        guard !manual.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        original = manual; destination = nil; destinationValid = false
        generate()
    }
    func changeStyle(_ newStyle: WritingStyle) {
        guard style != newStyle else { return }
        invalidate(); style = newStyle
        notice = "Style changed. Choose Generate to revise the original text."
    }
    func generate(inPlace automaticallyReplace: Bool = false) {
        guard !original.isEmpty, !replacing else { return }
        invalidate(); inPlace = automaticallyReplace; inPlaceGuard = InPlaceGuard()
        guard original.utf8.count <= 32_000 else { error = "Please use a shorter selection (up to 32 KB)."; return }
        let revision = gate.id, text = original, selectedStyle = style, preference = customStyle
        busy = true; result = ""; notice = "Correcting · \(style.rawValue)"
        if inPlace { showStatus?() }
        operation = Task {
            let start = Date()
            do {
                let revised: String
                if let corrector {
                    revised = try await corrector(text, selectedStyle, preference)
                } else {
                    if !codex.connected { await codex.connect() }
                    try Task.checkCancellation()
                    guard gate.accepts(revision) else { return }
                    guard let model = chosenModel else { throw QuillError(codex.status + " Open Settings to check the runtime and account.") }
                    revised = try await codex.correct(text, style: selectedStyle, custom: preference, model: model, serviceTier: serviceTier)
                }
                guard gate.accepts(revision), !Task.isCancelled else { return }
                result = revised; busy = false; hasResult = true; elapsed = Date().timeIntervalSince(start)
                notice = revised == text ? "No changes needed" : "Review your revision before replacing."
                destinationValid = destination.map { selection.valid($0, requireFrontmost: automaticallyReplace) } ?? false
                if automaticallyReplace {
                    inPlaceGuard.observe(valid: destinationValid)
                    guard inPlaceGuard.allowsReplacement, let target = destination else {
                        throw QuillError("Your field, selection, or app changed while correcting. Nothing was replaced. The result is available with Copy.")
                    }
                    replacing = true; notice = "Applying correction…"
                    // Never reactivate a background app for an automatic correction.
                    try await selection.replace(revised, at: target, activateDestination: false)
                    replacing = false; hasResult = false
                    elapsed = Date().timeIntervalSince(start)
                    notice = revised == text ? "No changes needed" : "Fixed in \(target.application.localizedName ?? "your app") · \(String(format: "%.1f", elapsed ?? 0)) s"
                    original = ""; result = ""; destination = nil; destinationValid = false
                    showStatus?()
                }
            } catch {
                guard gate.accepts(revision), !Task.isCancelled else { return }
                busy = false; replacing = false
                // A failed destination check still leaves a complete result available to Copy.
                hasResult = !result.isEmpty
                self.error = error.localizedDescription
                notice = error is ReplacementUnconfirmed ? "Check your draft — replacement unconfirmed" : "Correction was not applied"
                if automaticallyReplace { showStatus?() }
            }
        }
    }
    func cancel(dismiss: Bool = true) {
        guard !replacing else { return }
        invalidate(); destination = nil; destinationValid = false
        if dismiss { original = ""; result = ""; manual = ""; hideWindow?(); hideStatus?() }
        else { notice = "Cancelled. Your original writing is unchanged." }
    }
    func copy(to pasteboard: NSPasteboard = .general) {
        guard canCopy else { return }
        pasteboard.clearContents(); pasteboard.setString(result, forType: .string)
        notice = "Copied to clipboard"
    }
    func replace() {
        guard canReplace, let destination else { return }
        replacing = true
        let replacement = result
        operation = Task {
            do {
                try await selection.replace(replacement, at: destination, activateDestination: true)
                replacing = false
                cancel()
            } catch {
                replacing = false; destinationValid = false; self.destination = nil
                self.error = error.localizedDescription; showWindow?()
            }
        }
    }
    func shutdown() { operation?.cancel(); timer?.invalidate(); shortcut.stop(); codex.shutdown() }
}
