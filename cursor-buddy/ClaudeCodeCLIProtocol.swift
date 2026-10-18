import Foundation

/// Pure, process-free pieces of the Claude Code CLI integration: executable discovery,
/// command-line arguments, stream-json input/output, and local session files.
/// The CLI's own sign-in is used, so turns count against the user's Claude plan.
nonisolated enum ClaudeCodeCLIProtocol {
    /// Prefix that distinguishes a linked Claude Code session from a Codex thread ID.
    static let linkedSessionPrefix = "claude:"

    static func linkedThreadID(sessionID: String) -> String { linkedSessionPrefix + sessionID }

    static func sessionID(fromLinkedThreadID threadID: String) -> String? {
        guard threadID.hasPrefix(linkedSessionPrefix) else { return nil }
        let id = String(threadID.dropFirst(linkedSessionPrefix.count))
        return isValidSessionID(id) ? id : nil
    }

    static func isValidSessionID(_ id: String) -> Bool { UUID(uuidString: id) != nil }

    static func error(_ message: String) -> NSError {
        NSError(domain: "ClaudeCodeCLI", code: -30, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: Executable discovery

    /// GUI apps start with a minimal PATH, so known install locations are listed explicitly,
    /// including Nix profiles, before the inherited PATH.
    static func executableCandidates(home: String, user: String, environment: [String: String]) -> [String] {
        var candidates: [String] = []
        if let explicit = environment["OPENCLICKY_CLAUDE_EXECUTABLE"], !explicit.isEmpty {
            candidates.append((explicit as NSString).expandingTildeInPath)
        }
        candidates += [
            home + "/.local/bin/claude",
            home + "/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/etc/profiles/per-user/" + user + "/bin/claude",
            home + "/.nix-profile/bin/claude",
            "/run/current-system/sw/bin/claude"
        ]
        candidates += (environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/claude" }
        return candidates
    }

    static func findExecutable(fileManager: FileManager = .default,
                               environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        executableCandidates(home: fileManager.homeDirectoryForCurrentUser.path, user: NSUserName(), environment: environment)
            .first { fileManager.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    // MARK: Arguments

    static let standaloneTools = ["WebSearch", "WebFetch"]
    /// Linked sessions may inspect their project but never edit it from the cursor.
    static let linkedReadOnlyTools = ["Read", "Grep", "Glob", "WebSearch", "WebFetch"]

    private static let streamArguments = [
        "-p", "--input-format", "stream-json", "--output-format", "stream-json",
        "--verbose", "--include-partial-messages"
    ]

    /// An isolated, stateless voice/screen turn: no user hooks, MCP servers, or saved transcript.
    static func standaloneArguments(model: String, systemPrompt: String) -> [String] {
        streamArguments + [
            "--model", model,
            "--system-prompt", systemPrompt,
            "--no-session-persistence",
            "--setting-sources", "",
            "--strict-mcp-config",
            "--tools", standaloneTools.joined(separator: ","),
            "--allowedTools", standaloneTools.joined(separator: ","),
            "--permission-mode", "default"
        ]
    }

    /// Continues an existing session in place. Its model, settings, and history are kept;
    /// the cursor contract is appended for this turn only and is not saved in the transcript.
    static func resumeArguments(sessionID: String, appendedSystemPrompt: String) -> [String] {
        streamArguments + [
            "--resume", sessionID,
            "--append-system-prompt", appendedSystemPrompt,
            "--allowedTools", linkedReadOnlyTools.joined(separator: ","),
            "--permission-mode", "default"
        ]
    }

    /// Without a custom provider, Anthropic credentials are removed so the CLI uses its own
    /// subscription sign-in instead of billing a key per token.
    static func environment(base: [String: String], executable: URL, maxOutputTokens: Int?,
                            customBaseURL: String?, customAPIKey: String?) -> [String: String] {
        var environment = base
        let path = [executable.deletingLastPathComponent().path, base["PATH"] ?? "", "/usr/bin:/bin:/usr/sbin:/sbin"]
        environment["PATH"] = path.filter { !$0.isEmpty }.joined(separator: ":")
        environment["CLAUDE_AGENT_SDK_CLIENT_APP"] = "openclicky/1.0"
        if let maxOutputTokens { environment["CLAUDE_CODE_MAX_OUTPUT_TOKENS"] = String(maxOutputTokens) }
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL"] { environment.removeValue(forKey: key) }
        if let customBaseURL, !customBaseURL.isEmpty {
            environment["ANTHROPIC_BASE_URL"] = customBaseURL
            if let customAPIKey, !customAPIKey.isEmpty { environment["ANTHROPIC_API_KEY"] = customAPIKey }
        }
        return environment
    }

    // MARK: Input

    static func mediaType(for data: Data) -> String {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
    }

    static func userMessageLine(textBlocks: [String], images: [(data: Data, label: String)]) throws -> Data {
        var content: [[String: Any]] = textBlocks.filter { !$0.isEmpty }.map { ["type": "text", "text": $0] }
        for image in images {
            content.append(["type": "image", "source": [
                "type": "base64", "media_type": mediaType(for: image.data), "data": image.data.base64EncodedString()
            ]])
        }
        let message: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": content],
            "parent_tool_use_id": NSNull()
        ]
        return try JSONSerialization.data(withJSONObject: message) + Data("\n".utf8)
    }

    /// A linked session keeps its own context, so a cursor turn carries only the question and screen labels.
    static func linkedUserText(_ prompt: String, screenLabels: [String]) -> String {
        guard !screenLabels.isEmpty else { return prompt }
        return prompt + "\n\n[OpenClicky current screenshots: " + screenLabels.joined(separator: "; ") + "]"
    }

    /// Per-turn policy and recent history for a stateless standalone turn.
    static func standaloneTextBlocks(systemPrompt: String,
                                     history: [(userPlaceholder: String, assistantResponse: String)],
                                     imageLabels: [String], prompt: String) -> [String] {
        var blocks: [String] = []
        if !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append("OpenClicky current voice policy and runtime context for this turn:\n" + systemPrompt)
        }
        if !history.isEmpty {
            var lines = ["Recent conversation:"]
            for entry in history {
                if !entry.userPlaceholder.isEmpty { lines.append("User: " + entry.userPlaceholder) }
                if !entry.assistantResponse.isEmpty { lines.append("OpenClicky: " + entry.assistantResponse) }
            }
            blocks.append(lines.joined(separator: "\n"))
        }
        if !imageLabels.isEmpty {
            blocks.append((["Screen context:"] + imageLabels.enumerated().map { "\($0.offset + 1). \($0.element)" })
                .joined(separator: "\n"))
        }
        blocks.append(prompt)
        return blocks
    }

    // MARK: Output

    nonisolated enum StreamEvent: Equatable {
        case started(sessionID: String)
        case text(String)
        case finished(String)
        case failed(String)
    }

    /// Folds stream-json lines into accumulated text and one terminal event.
    nonisolated struct StreamState {
        private(set) var text = ""
        private(set) var sessionID: String?
        private(set) var isFinished = false

        mutating func consume(line: String) -> StreamEvent? {
            guard !isFinished, let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String else { return nil }
            switch type {
            case "system":
                guard object["subtype"] as? String == "init", sessionID == nil,
                      let id = object["session_id"] as? String else { return nil }
                sessionID = id
                return .started(sessionID: id)
            case "stream_event":
                let event = object["event"] as? [String: Any]
                if event?["type"] as? String == "message_start" { startsNewMessage = !text.isEmpty; return nil }
                let delta = event?["delta"] as? [String: Any]
                guard event?["type"] as? String == "content_block_delta", delta?["type"] as? String == "text_delta",
                      let chunk = delta?["text"] as? String, !chunk.isEmpty else { return nil }
                // Separate consecutive assistant messages, such as before and after a web search.
                if startsNewMessage { text += "\n\n"; startsNewMessage = false }
                text += chunk
                return .text(text)
            case "result":
                isFinished = true
                let result = object["result"] as? String ?? ""
                if object["is_error"] as? Bool == true {
                    let errors = (object["errors"] as? [String])?.joined(separator: "\n") ?? ""
                    let message = !result.isEmpty ? result : !errors.isEmpty ? errors : (object["subtype"] as? String ?? "error")
                    return .failed("Claude Code: " + message)
                }
                return .finished(result.isEmpty ? text : result)
            default:
                return nil
            }
        }

        private var startsNewMessage = false
    }

    // MARK: Local sessions

    nonisolated struct SessionSummary: Equatable {
        let id: String
        let title: String
        let cwd: String
        let modifiedAt: Date
    }

    static func configDirectory(home: String, environment: [String: String]) -> URL {
        if let configured = environment["CLAUDE_CONFIG_DIR"], !configured.isEmpty {
            return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath, isDirectory: true)
        }
        return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".claude", isDirectory: true)
    }

    /// Reads title, working directory, and visible transcript from one session file.
    nonisolated struct SessionMessage: Equatable {
        let id: String
        let isUser: Bool
        var text: String
        let createdAt: Date
    }

    static func parseSession(lines: [Substring], id: String, modifiedAt: Date) -> (summary: SessionSummary?, messages: [SessionMessage]) {
        var cwd: String?
        var customTitle: String?
        var agentName: String?
        var entries: [SessionMessage] = []
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = record["type"] as? String else { continue }
            switch type {
            case "custom-title": customTitle = record["customTitle"] as? String ?? customTitle
            case "agent-name": agentName = record["agentName"] as? String ?? agentName
            case "user", "assistant":
                if cwd == nil { cwd = record["cwd"] as? String }
                guard record["isSidechain"] as? Bool != true, record["isMeta"] as? Bool != true,
                      let message = record["message"] as? [String: Any],
                      let text = visibleText(message["content"], role: type), !text.isEmpty else { continue }
                let isUser = type == "user"
                let date = (record["timestamp"] as? String).flatMap(formatter.date(from:)) ?? modifiedAt
                let entryID = record["uuid"] as? String ?? UUID().uuidString
                // Streaming writes one record per assistant content block; merge them into one reply.
                if !isUser, let last = entries.last, !last.isUser {
                    entries[entries.count - 1].text = last.text + "\n\n" + text
                } else {
                    entries.append(SessionMessage(id: entryID, isUser: isUser, text: text, createdAt: date))
                }
            default: continue
            }
        }
        guard let cwd else { return (nil, entries) }
        let firstPrompt = entries.first(where: \.isUser).map { String($0.text.prefix(60)) }
        let folder = URL(fileURLWithPath: cwd).lastPathComponent
        let title = [customTitle, agentName, firstPrompt].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? folder + " · " + String(id.prefix(8))
        return (SessionSummary(id: id, title: title, cwd: cwd, modifiedAt: modifiedAt), entries)
    }

    private static func visibleText(_ content: Any?, role: String) -> String? {
        if let text = content as? String { return isInternalUserText(text, role: role) ? nil : text }
        guard let blocks = content as? [[String: Any]] else { return nil }
        // Tool results and tool calls are not conversation text.
        let texts = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
            .filter { !isInternalUserText($0, role: role) }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    private static func isInternalUserText(_ text: String, role: String) -> Bool {
        guard role == "user" else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("<command-") || trimmed.hasPrefix("<local-command") || trimmed.hasPrefix("<system-reminder>")
            || trimmed.hasPrefix("Caveat: The messages below")
    }

    /// Live interactive owners from the CLI's session registry (`sessions/<pid>.json`).
    static func liveOwners(registryRecords: [[String: Any]], isProcessAlive: (Int32) -> Bool) -> [String: String] {
        var owners: [String: String] = [:]
        for record in registryRecords {
            guard let id = record["sessionId"] as? String, let pid = (record["pid"] as? NSNumber)?.int32Value,
                  isProcessAlive(pid) else { continue }
            owners[id] = record["status"] as? String ?? "running"
        }
        return owners
    }
}
