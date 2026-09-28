import Foundation

/// Main-actor ownership serializes IDs, process lifecycle, callbacks and cancellation.
@MainActor final class CodexTransport {
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var framing = JSONLines()
    private var sequence = 0
    private var generation = UUID()
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    var notification: ((String, [String: Any]) -> Void)?
    var disconnected: (() -> Void)?
    var running: Bool { process?.isRunning == true }

    static func runtime(custom: String = "") -> String? {
        let candidates = [custom,
          "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
          "/Applications/Codex.app/Contents/Resources/codex",
          "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        return candidates.first { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }
    }
    func start(path: String, cwd: URL) throws {
        stop()
        let proc = Process(), stdin = Pipe(), stdout = Pipe()
        proc.executableURL = URL(fileURLWithPath: path)
        // Per-process overrides only. Never write the user's Codex config.
        let disabled = ["shell_tool", "unified_exec", "shell_snapshot", "apps", "plugins", "remote_plugin", "browser_use", "browser_use_external", "computer_use", "image_generation", "view_image", "multi_agent", "multi_agent_v2", "memories", "hooks", "code_mode", "code_mode_host", "goals", "sleep_tool", "workspace_dependencies", "skill_search", "tool_suggest"]
        proc.arguments = ["app-server", "--listen", "stdio://", "-c", "forced_login_method=\"chatgpt\"", "-c", "model_provider=\"openai\"", "-c", "web_search=\"disabled\"", "-c", "project_doc_max_bytes=0", "-c", "history.persistence=\"none\"", "-c", "features.skip_host_skill_discovery=true"] + disabled.flatMap { ["--disable", $0] }
        var env = ProcessInfo.processInfo.environment
        // Prevent accidental API billing through the parent process environment.
        for key in ["OPENAI_API_KEY", "OPENAI_BASE_URL", "CODEX_API_KEY", "CODEX_THREAD_ID", "CODEX_INTERNAL_ORIGINATOR_OVERRIDE"] { env.removeValue(forKey: key) }
        proc.environment = env
        proc.currentDirectoryURL = cwd
        proc.standardInput = stdin; proc.standardOutput = stdout
        proc.standardError = FileHandle.nullDevice // Protocol errors surface through RPC; never log content/tokens.
        let epoch = generation
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in
                guard let self, self.generation == epoch else { return }
                if data.isEmpty { self.stop(); self.disconnected?(); return }
                do { for message in try self.framing.append(data) { self.receive(message) } }
                catch { self.stop() }
            }
        }
        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == epoch else { return }
                self.stop(); self.disconnected?()
            }
        }
        process = proc; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        try proc.run()
    }
    func stop() {
        generation = UUID()
        output?.readabilityHandler = nil
        try? input?.close(); try? output?.close()
        input = nil; output = nil
        if let process, process.isRunning { process.terminate() }
        process = nil; framing = JSONLines()
        let waiting = pending; pending.removeAll()
        for continuation in waiting.values { continuation.resume(throwing: QuillError("Codex connection closed. Reconnect in Settings.")) }
    }
    func send(_ value: [String: Any]) throws {
        guard let input, running else { throw QuillError("Codex is not connected.") }
        var bytes = try JSONSerialization.data(withJSONObject: value)
        bytes.append(10)
        try input.write(contentsOf: bytes)
    }
    func request(_ method: String, _ params: [String: Any] = [:], timeout: Double = 30) async throws -> [String: Any] {
        sequence += 1
        let id = sequence
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                do { try send(["id": id, "method": method, "params": params]) }
                catch { pending.removeValue(forKey: id)?.resume(throwing: error) }
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    self?.pending.removeValue(forKey: id)?.resume(throwing: QuillError("Codex request timed out. Check your connection and retry."))
                }
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.pending.removeValue(forKey: id)?.resume(throwing: CancellationError()) } })
    }
    private func receive(_ message: [String: Any]) {
        if let id = message["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
            if let error = message["error"] as? [String: Any] {
                continuation.resume(throwing: QuillError(error["message"] as? String ?? "Codex rejected the request."))
            } else if let result = message["result"] as? [String: Any] { continuation.resume(returning: result) }
            else { continuation.resume(throwing: QuillError("Unexpected Codex response.")) }
        } else if let method = message["method"] as? String {
            if let id = message["id"] {
                // No client-side tool execution or approval is available in this editor.
                try? send(["id": id, "error": ["code": -32601, "message": "Quill does not execute tools or grant permissions."]])
            } else { notification?(method, message["params"] as? [String: Any] ?? [:]) }
        }
    }
}
