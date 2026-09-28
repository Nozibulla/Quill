import SwiftUI

struct StylePicker: View {
    @Binding var selection: WritingStyle
    var body: some View {
        Picker("Writing style", selection: $selection) {
            ForEach(WritingStyle.allCases) { style in Text(style.rawValue).tag(style) }
        }
    }
}

struct CorrectionView: View {
    @ObservedObject var state: AppState
    @ObservedObject var codex: CodexService
    @FocusState private var editorFocused: Bool
    @State private var showOriginal = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage()).resizable().frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Quill").font(.title2.weight(.semibold))
                    Text("Better writing, one shortcut away.").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button { state.showSettings?() } label: { Image(systemName: "gearshape") }.buttonStyle(.borderless).help("Settings").accessibilityLabel("Settings")
            }
            Divider()
            HStack {
                StylePicker(selection: Binding(get: { state.style }, set: state.changeStyle)).frame(maxWidth: 245)
                Spacer()
                Text(state.shortcutLabel).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            if state.style == .custom {
                Text(state.customStyle.isEmpty ? "Add your preferred style in Settings." : state.customStyle).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            if state.original.isEmpty {
                Text("Your writing").font(.headline)
                TextEditor(text: $state.manual).font(.body).focused($editorFocused)
                    .frame(minHeight: 150, idealHeight: 180).padding(6)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                    .accessibilityLabel("Paste writing to correct")
                HStack {
                    Text("Paste here, then choose Correct.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Correct") { state.correctManual(); editorFocused = false }.buttonStyle(.borderedProminent)
                        .disabled(state.manual.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                HStack {
                    Text(state.busy ? "Correcting · \(state.style.rawValue)" : "Revised writing").font(.headline)
                    Spacer()
                    if state.busy { ProgressView().controlSize(.small) }
                    if let elapsed = state.elapsed { Text(String(format: "%.1f s", elapsed)).font(.caption).foregroundStyle(.secondary) }
                }
                TextEditor(text: $state.result).font(.body).focused($editorFocused)
                    .disabled(!state.hasResult || state.busy || state.replacing)
                    .frame(minHeight: 140, idealHeight: 180).padding(6)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                    .accessibilityLabel("Editable corrected text")
                DisclosureGroup("Original writing", isExpanded: $showOriginal) {
                    ScrollView { Text(state.original).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6) }.frame(maxHeight: 110)
                }.font(.subheadline)
                HStack {
                    Text(state.notice).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if state.busy {
                        Button("Stop") { state.cancel(dismiss: false) }
                    } else {
                        Button(state.hasResult ? "Regenerate" : "Generate / Retry") { state.generate(); editorFocused = false }.disabled(state.replacing)
                    }
                }
            }
            if let error = state.error {
                Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if !state.accessibility {
                HStack {
                    Text("Accessibility enables selection capture and replacement.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Allow…") { state.selection.openPermissionSettings() }
                }
            }
            if !state.original.isEmpty && !state.destinationValid && !state.busy {
                Label("Use Copy: the destination is unavailable or its selection changed.", systemImage: "doc.on.doc").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Button("Cancel") { state.cancel() }.keyboardShortcut(.cancelAction).disabled(state.replacing)
                Spacer()
                Button("Copy") { state.copy() }.disabled(!state.canCopy)
                Button(state.replacing ? "Replacing…" : "Replace  ⌘↩") { state.replace() }
                    .keyboardShortcut(.return, modifiers: .command).buttonStyle(.borderedProminent).disabled(!state.canReplace)
            }
            HStack {
                Text(state.chosenModel?.name ?? "Model discovery pending")
                Spacer()
                Text("\(state.speedLabel) · shared Codex allowance")
            }.font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(22).frame(minWidth: 480, idealWidth: 540, maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onKeyPress(.return) {
            guard !editorFocused, state.canReplace else { return .ignored }
            state.replace(); return .handled
        }
    }
}

struct SettingsView: View {
    @ObservedObject var state: AppState
    @ObservedObject var codex: CodexService
    @AppStorage("runtime") private var customRuntime = ""
    var body: some View {
        Form {
            Section("Correct in the app you're using") {
                Text("Select text in a chat box or editor and press \(state.shortcutLabel). Quill corrects and replaces that selection in place. The review window stays closed; messages are never sent.")
                Text("Keep the selection unchanged while correcting. Press the shortcut again to cancel. Editors that do not expose a safe selection cannot be replaced automatically.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Writing Style") {
                StylePicker(selection: $state.defaultStyle)
                Text(state.defaultStyle.guidance(custom: state.customStyle)).font(.caption).foregroundStyle(.secondary)
                TextField("Custom style (up to 500 characters)", text: $state.customStyle, axis: .vertical).lineLimit(2...4)
                Text("The correction window can override this style for one selection. Alternatives always start from the original.").font(.caption).foregroundStyle(.secondary)
            }
            Section("ChatGPT Account") {
                Label(codex.status, systemImage: codex.chatGPT && codex.connected ? "checkmark.circle.fill" : "person.crop.circle.badge.questionmark").foregroundStyle(codex.chatGPT && codex.connected ? .green : .secondary)
                Text(codex.account).textSelection(.enabled)
                HStack {
                    Button("Sign in with ChatGPT") { Task { await codex.signIn() } }.disabled(codex.connecting || codex.loginPending || state.busy)
                    if codex.loginPending { Button("Cancel sign-in") { Task { await codex.cancelLogin() } } }
                    Button("Reconnect") { Task { await codex.connect() } }.disabled(codex.connecting || state.busy || codex.loginPending)
                }
                Text("Corrections consume your shared Codex subscription allowance. API-key billing is disabled. Quill never purchases credits.").font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Usage limits") {
                    Text(codex.usage).font(.caption).textSelection(.enabled)
                    Button("Refresh usage") { Task { await codex.refreshUsage() } }.disabled(!codex.connected)
                }
            }
            Section("Model") {
                Picker("Correction model", selection: $state.modelID) {
                    Text("Automatic (prefer GPT-6 Luna)").tag("")
                    ForEach(codex.models) { model in Text(model.name).tag(model.id) }
                }
                Text("Active: \(state.chosenModel?.name ?? "unavailable") · \(state.chosenModel?.effort ?? "low") reasoning · \(state.speedLabel) speed").font(.caption).foregroundStyle(.secondary)
            }
            Section("Speed") {
                Toggle("Use Fast speed", isOn: $state.preferFast).disabled(state.chosenModel?.supportsFast != true)
                Text("Standard is the default. Fast uses 2.5× the Standard credit rate for GPT-6 where available, so your shared allowance is used faster. It does not purchase credits.").font(.caption).foregroundStyle(.secondary)
                if state.chosenModel?.supportsFast != true { Text("Fast is not advertised for the selected model; Standard is active.").font(.caption).foregroundStyle(.secondary) }
            }
            Section("Last correction timing") {
                Text(codex.lastTiming?.summary ?? "Timing will appear after your next correction.").font(.caption).foregroundStyle(.secondary)
                Text("GPT-6 Luna uses low reasoning. Account checks do not force token refresh. Model and network delay still varies.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Shortcut & Startup") {
                HStack {
                    Picker("Modifiers", selection: $state.optionModifier) { Text("⌘⇧").tag(false); Text("⌘⌥").tag(true) }.frame(width: 200)
                    Picker("Key", selection: $state.shortcutKey) { ForEach(GlobalShortcut.choices, id: \.0) { Text($0.0).tag($0.0) } }.frame(width: 100)
                    Button("Apply") { state.registerShortcut() }
                }
                Text("Active shortcut: \(state.shortcutLabel). Replace: ⌘Return. Return inserts a newline while editing.").font(.caption).foregroundStyle(.secondary)
                if let error = state.shortcutError { Text(error).foregroundStyle(.red) }
                Toggle("Launch Quill at login", isOn: Binding(get: { state.launchAtLogin }, set: state.setLaunch))
                if let error = state.launchError { Text(error).font(.caption).foregroundStyle(.red) }
            }
            Section("Accessibility") {
                Label(state.accessibility ? "Access granted" : "Access needed for selected text", systemImage: state.accessibility ? "checkmark.circle" : "hand.raised")
                Text("This controls the running copy of Quill. If macOS shows Quill enabled but access is still denied, remove the old entry, add this exact app again, enable it, then restart Quill. On this macOS version the permission may be called Device Control and Data Access.").font(.caption).foregroundStyle(.secondary)
                Text(Bundle.main.bundlePath).font(.caption).textSelection(.enabled)
                HStack {
                    Button("Open permission settings") { state.selection.openPermissionSettings() }
                    Button("Reveal this app") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                }
                HStack {
                    Button("Recheck access") { state.refreshAccessibility() }
                    Button("Restart Quill") { state.restartApp?() }
                }
            }
            Section("Codex Runtime") {
                Text(codex.runtimePath.isEmpty ? "No runtime detected yet" : codex.runtimePath).font(.caption).textSelection(.enabled)
                TextField("Optional absolute path to codex", text: $customRuntime)
                Link("Official Codex setup", destination: URL(string: "https://learn.chatgpt.com/docs/cli")!)
                Text("A compatible local Codex app server is required. Quill uses its supported ChatGPT sign-in and token refresh; it does not read credentials.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Privacy & Compatibility") {
                Text("Only explicitly submitted writing and editing instructions are sent. Quill keeps no correction history and uses a fresh ephemeral Codex thread for every request. Codex authentication and service-side data policies still apply. Local runtime diagnostic metadata may remain.")
                Text("Plain-text replacements may lose formatting within a selection. Apps must expose a verifiable Accessibility selection for Replace. Otherwise use manual paste and Copy. A copy/paste fallback preserves clipboard formats where possible; very large or unavailable clipboard data is rejected.")
            }.font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped).frame(width: 600, height: 730)
    }
}

/// A progress/error HUD. Its NSPanel cannot become key, so typing stays in the destination.
struct InPlaceStatusView: View {
    @ObservedObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if state.busy || state.replacing { ProgressView().controlSize(.small) }
                else { Image(systemName: state.error == nil ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(state.error == nil ? .green : .orange) }
                Text(state.notice).font(.callout.weight(.medium))
                Spacer()
                Button { state.hideStatus?() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss status")
            }
            if let error = state.error {
                Text(error).font(.caption).fixedSize(horizontal: false, vertical: true)
                HStack {
                    if state.canCopy { Button("Copy result") { state.copy(); state.hideStatus?() } }
                    Button("Settings…") { state.showSettings?() }
                    if state.permissionIssue { Button("Restart Quill") { state.restartApp?() } }
                }
            } else if state.busy {
                Text("Keep the same text selected. Press \(state.shortcutLabel) again to cancel.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(14).frame(width: 390).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary))
    }
}
