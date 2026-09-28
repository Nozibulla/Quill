import AppKit
import Combine

@MainActor final class CodexService: ObservableObject {
    @Published var status = "Not connected"
    @Published var account = "Sign in with ChatGPT"
    @Published var chatGPT = false
    @Published var models: [ModelOption] = []
    @Published var usage = "Usage information unavailable"
    @Published var runtimePath = ""
    @Published var loginPending = false
    @Published var lastTiming: CorrectionTiming?
    @Published var connected = false
    @Published var connecting = false
    private let rpc = CodexTransport()
    private var loginID: String?
    private var isolation: [String: Any] = [:]
    private var messages: [String: String] = [:]
    private var completions: [String: [String: Any]] = [:]
    private var activeThread: String?
    private var activeTurn: String?
    private var workingDirectory: URL?
    private var loginTask: Task<Void, Never>?

    init() {
        rpc.notification = { [weak self] method, params in self?.receive(method, params) }
        rpc.disconnected = { [weak self] in
            self?.connected = false; self?.chatGPT = false
            self?.status = "Codex stopped. Reconnect to continue."
        }
    }
    func connect() async {
        if connecting {
            while connecting && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
            return
        }
        connecting = true
        defer { connecting = false }
        do {
            guard let path = CodexTransport.runtime(custom: UserDefaults.standard.string(forKey: "runtime") ?? "") else {
                throw QuillError("Codex runtime missing. Install the official Codex CLI or ChatGPT desktop app, then reconnect.")
            }
            runtimePath = path; status = "Connecting…"; connected = false; chatGPT = false
            if let old = workingDirectory { try? FileManager.default.removeItem(at: old) }
            let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("quill-session-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
            workingDirectory = cwd
            try rpc.start(path: path, cwd: cwd)
            _ = try await rpc.request("initialize", ["clientInfo": ["name": "quill", "title": "Quill", "version": "1.0"], "capabilities": ["experimentalApi": true]])
            try rpc.send(["method": "initialized", "params": [:]])
            let config = try await rpc.request("config/read", ["includeLayers": false])
            let values = config["config"] as? [String: Any] ?? [:]
            isolation = ["developer_instructions": ""]
            // Disable every configured MCP server by name so table-merge semantics cannot re-enable it.
            for name in (values["mcp_servers"] as? [String: Any] ?? [:]).keys { isolation["mcp_servers.\(name).enabled"] = false }
            let skills = try await rpc.request("skills/list", ["cwds": [cwd.path], "forceReload": true])
            let entries = (skills["data"] as? [[String: Any]] ?? []).flatMap { $0["skills"] as? [[String: Any]] ?? [] }
            isolation["skills.config"] = entries.compactMap { s -> [String: Any]? in
                guard let path = s["path"] as? String else { return nil }
                return ["path": path, "enabled": false]
            }
            try await refreshAccount()
            try await discoverModels()
            connected = true; status = chatGPT ? "Connected · ChatGPT subscription" : "ChatGPT sign-in required"
            Task { await refreshUsage() } // Usage is not on the correction critical path.
        } catch { status = error.localizedDescription; connected = false; rpc.stop() }
    }
    func refreshAccount() async throws {
        let response = try await rpc.request("account/read", ["refreshToken": false])
        let a = response["account"] as? [String: Any] ?? [:]
        chatGPT = a["type"] as? String == "chatgpt"
        account = chatGPT ? "\(a["email"] as? String ?? "ChatGPT account") · \(a["planType"] as? String ?? "")" : "ChatGPT sign-in required (API billing is disabled)"
    }
    private func discoverModels() async throws {
        var result: [ModelOption] = [], cursor: String?
        repeat {
            var params: [String: Any] = ["limit": 100, "includeHidden": false]
            if let cursor { params["cursor"] = cursor }
            let response = try await rpc.request("model/list", params)
            result += (response["data"] as? [[String: Any]] ?? []).compactMap { row in
                guard let id = row["model"] as? String, (row["inputModalities"] as? [String] ?? ["text"]).contains("text") else { return nil }
                return ModelOption(id: id, name: row["displayName"] as? String ?? id,
                    efforts: (row["supportedReasoningEfforts"] as? [[String: Any]] ?? []).compactMap { $0["reasoningEffort"] as? String }, isDefault: row["isDefault"] as? Bool ?? false,
                    serviceTiers: (row["serviceTiers"] as? [[String: Any]] ?? []).compactMap { tier in
                        guard let id = tier["id"] as? String else { return nil }
                        return ModelSpeedTier(id: id, name: tier["name"] as? String ?? id)
                    })
            }
            cursor = response["nextCursor"] as? String
        } while cursor != nil
        models = result
        if result.isEmpty { throw QuillError("This account has no available text models.") }
    }
    func refreshUsage() async {
        do {
            let response = try await rpc.request("account/rateLimits/read")
            let buckets = response["rateLimitsByLimitId"] as? [String: [String: Any]]
            let snapshots = buckets?.sorted(by: { $0.key < $1.key }).map { ($0.key, $0.value) }
                ?? [("Codex", response["rateLimits"] as? [String: Any] ?? [:])]
            var rows: [String] = []
            for (name, snapshot) in snapshots {
                for key in ["primary", "secondary"] {
                    if let window = snapshot[key] as? [String: Any], let used = window["usedPercent"] as? Double {
                        let reset = (window["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened) } ?? "unavailable"
                        rows.append("\(name): \(Int(max(0, 100 - used)))% remaining · resets \(reset)")
                    }
                }
            }
            usage = rows.isEmpty ? "Usage information unavailable from this runtime." : rows.joined(separator: "\n")
        } catch { usage = "Usage information unavailable: \(error.localizedDescription)" }
    }
    func signIn() async {
        if !connected { await connect() }
        guard rpc.running else { return }
        do {
            let result = try await rpc.request("account/login/start", ["type": "chatgpt"])
            guard let raw = result["authUrl"] as? String, let url = URL(string: raw), url.scheme == "https" else { throw QuillError("Codex did not return a secure sign-in URL.") }
            loginID = result["loginId"] as? String; loginPending = true
            status = "Complete ChatGPT sign-in in your browser."
            NSWorkspace.shared.open(url)
            loginTask?.cancel()
            loginTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled, self?.loginPending == true else { return }
                await self?.cancelLogin()
                self?.status = "Sign-in timed out. Try again."
            }
        } catch { status = error.localizedDescription }
    }
    func cancelLogin() async {
        loginTask?.cancel()
        if let loginID { _ = try? await rpc.request("account/login/cancel", ["loginId": loginID]) }
        loginID = nil; loginPending = false; status = "Sign-in cancelled"
    }
    func correct(_ original: String, style: WritingStyle, custom: String, model: ModelOption, serviceTier: String = "default") async throws -> String {
        guard serviceTier == "default" || (serviceTier == "priority" && model.supportsFast) else {
            throw QuillError("The selected model does not advertise Fast speed. Choose Standard in Settings.")
        }
        var timing = CorrectionTiming()
        var phase = Date()
        defer { lastTiming = timing }
        if !connected { await connect() }
        timing.connection = Date().timeIntervalSince(phase); phase = Date()
        try Task.checkCancellation()
        guard connected, let cwd = workingDirectory else { throw QuillError(status) }
        try await refreshAccount()
        timing.accountCheck = Date().timeIntervalSince(phase); phase = Date()
        guard chatGPT else { throw QuillError("Sign in with ChatGPT in Settings. Quill never uses API-key billing.") }
        try Task.checkCancellation()
        let thread = try await rpc.request("thread/start", ["model": model.id, "modelProvider": "openai", "cwd": cwd.path,
            "approvalPolicy": "never", "sandbox": "read-only", "ephemeral": true, "serviceTier": serviceTier, "config": isolation,
            "baseInstructions": "You are Quill, a text editor. Edit only the supplied writing. Do not execute tools.",
            "developerInstructions": style.instruction(custom: custom)])
        guard let metadata = thread["thread"] as? [String: Any], let id = metadata["id"] as? String,
              metadata["ephemeral"] as? Bool == true, (thread["instructionSources"] as? [String] ?? ["unverified"]).isEmpty,
              thread["modelProvider"] as? String == "openai" else {
            throw QuillError("The runtime could not confirm an isolated ephemeral OpenAI session. Update Codex before correcting text.")
        }
        timing.threadSetup = Date().timeIntervalSince(phase); phase = Date()
        activeThread = id
        defer {
            messages[id] = nil; completions[id] = nil
            if activeThread == id { activeThread = nil; activeTurn = nil }
            Task { _ = try? await rpc.request("thread/unsubscribe", ["threadId": id]) }
        }
        try Task.checkCancellation()
        let response = try await rpc.request("turn/start", ["threadId": id,
            "input": [["type": "text", "text": original, "text_elements": []]], "effort": model.effort, "serviceTierForTurn": serviceTier])
        activeTurn = (response["turn"] as? [String: Any])?["id"] as? String
        let deadline = Date().addingTimeInterval(90)
        while completions[id] == nil {
            try Task.checkCancellation()
            guard rpc.running else { throw QuillError("Codex stopped. Reconnect and retry.") }
            guard Date() < deadline else { await interrupt(); throw QuillError("Correction timed out after 90 seconds. Retry when your connection is ready.") }
            try await Task.sleep(for: .milliseconds(80))
        }
        timing.generation = Date().timeIntervalSince(phase)
        let completion = completions[id]!
        guard completion["status"] as? String == "completed" else {
            let error = completion["error"] as? [String: Any]
            throw QuillError(error?["message"] as? String ?? "Correction interrupted. Your original text is unchanged.")
        }
        guard let text = messages[id], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw QuillError("Codex returned no revised text. Retry or choose another model.")
        }
        Task { await refreshUsage() }
        return text
    }
    func interrupt() async {
        if let activeThread, let activeTurn { _ = try? await rpc.request("turn/interrupt", ["threadId": activeThread, "turnId": activeTurn], timeout: 5) }
    }
    /// Closing the owned child also cancels a turn whose start reply has not yet arrived.
    func cancelCorrection() {
        rpc.stop(); connected = false; activeThread = nil; activeTurn = nil
        messages.removeAll(); completions.removeAll()
        status = "Ready to reconnect"
    }
    func shutdown() {
        loginTask?.cancel(); rpc.stop()
        if let workingDirectory { try? FileManager.default.removeItem(at: workingDirectory) }
    }
    private func receive(_ method: String, _ params: [String: Any]) {
        if method == "account/login/completed" {
            loginTask?.cancel(); loginPending = false; loginID = nil
            if params["success"] as? Bool == true {
                Task { do { try await refreshAccount(); try await discoverModels(); status = "Connected · ChatGPT subscription"; await refreshUsage() } catch { status = error.localizedDescription } }
            } else { status = params["error"] as? String ?? "Sign-in cancelled" }
        }
        if method == "account/updated" { Task { try? await refreshAccount() } }
        guard let id = params["threadId"] as? String, id == activeThread else { return }
        if method == "item/completed", let item = params["item"] as? [String: Any], item["type"] as? String == "agentMessage" {
            if item["phase"] as? String != "commentary" { messages[id] = item["text"] as? String }
        }
        if method == "turn/completed", let turn = params["turn"] as? [String: Any] { completions[id] = turn }
    }
}
