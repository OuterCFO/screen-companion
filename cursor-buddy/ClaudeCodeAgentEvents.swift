import Foundation

/// Background agent turns run by the `claude` CLI, translated into the same transcript
/// updates that Codex turns produce. Pure and process-free so it can be tested.
nonisolated enum ClaudeCodeAgentEvent: Equatable {
    case sessionStarted(id: String)
    /// A text chunk of the assistant message `messageID`.
    case textDelta(messageID: String, text: String)
    /// A tool call started; `isCommand` marks shell commands, `planText` carries a todo list.
    case toolStarted(id: String, summary: String, isCommand: Bool, planText: String?)
    /// The full text of an assistant message so far.
    case messageText(messageID: String, text: String)
    case turnCompleted(result: String)
    case turnFailed(message: String)
}

nonisolated enum ClaudeCodeAgentProtocol {
    /// Agent turns load the user's own Claude Code settings, CLAUDE.md, skills, and MCP servers.
    /// `auto` lets Claude Code's safety checks approve actions unattended, matching how Codex agents run;
    /// restricted sessions may only edit files in their sandbox folder.
    static func arguments(model: String, resumeSessionID: String?, restricted: Bool) -> [String] {
        var arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json",
                         "--verbose", "--include-partial-messages", "--model", model,
                         "--permission-mode", restricted ? "acceptEdits" : "auto",
                         // Same rule as Codex agents: native app builds stay in Xcode.
                         "--disallowedTools", "Bash(xcodebuild:*)"]
        if let resumeSessionID, ClaudeCodeCLIProtocol.isValidSessionID(resumeSessionID) {
            arguments += ["--resume", resumeSessionID]
        }
        return arguments
    }

    static func isClaudeAgentModel(_ modelID: String) -> Bool { modelID.hasPrefix("claude-") }

    /// Folds stream-json lines into agent events.
    struct Parser {
        private var currentMessageID: String?
        /// Text of each assistant message from its completed records, which are authoritative.
        private var recordTexts: [String: String] = [:]
        private var announcedTools = Set<String>()
        private(set) var isFinished = false

        mutating func consume(line: String) -> [ClaudeCodeAgentEvent] {
            guard !isFinished, let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String else { return [] }
            switch type {
            case "system":
                guard object["subtype"] as? String == "init", let id = object["session_id"] as? String else { return [] }
                return [.sessionStarted(id: id)]
            case "stream_event":
                return streamEvent(object["event"] as? [String: Any] ?? [:])
            case "assistant":
                return assistantRecord(object["message"] as? [String: Any] ?? [:])
            case "result":
                isFinished = true
                let result = object["result"] as? String ?? ""
                if object["is_error"] as? Bool == true {
                    let errors = (object["errors"] as? [String])?.joined(separator: "\n") ?? ""
                    return [.turnFailed(message: "Claude Code: " + (!result.isEmpty ? result : !errors.isEmpty ? errors : "the task failed."))]
                }
                return [.turnCompleted(result: result)]
            default:
                return []
            }
        }

        private mutating func streamEvent(_ event: [String: Any]) -> [ClaudeCodeAgentEvent] {
            switch event["type"] as? String {
            case "message_start":
                currentMessageID = (event["message"] as? [String: Any])?["id"] as? String ?? UUID().uuidString
                return []
            case "content_block_delta":
                let delta = event["delta"] as? [String: Any]
                guard delta?["type"] as? String == "text_delta", let text = delta?["text"] as? String, !text.isEmpty else { return [] }
                return [.textDelta(messageID: currentMessageID ?? "claude-message", text: text)]
            default:
                return []
            }
        }

        private mutating func assistantRecord(_ message: [String: Any]) -> [ClaudeCodeAgentEvent] {
            let messageID = message["id"] as? String ?? currentMessageID ?? UUID().uuidString
            var events: [ClaudeCodeAgentEvent] = []
            for block in message["content"] as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "text":
                    guard let text = block["text"] as? String, !text.isEmpty else { continue }
                    let full = recordTexts[messageID].map { $0 + "\n\n" + text } ?? text
                    recordTexts[messageID] = full
                    events.append(.messageText(messageID: messageID, text: full))
                case "tool_use":
                    let id = block["id"] as? String ?? UUID().uuidString
                    guard announcedTools.insert(id).inserted else { continue }
                    let name = block["name"] as? String ?? "tool"
                    let input = block["input"] as? [String: Any] ?? [:]
                    events.append(.toolStarted(id: id, summary: ClaudeCodeAgentProtocol.toolSummary(name: name, input: input),
                                               isCommand: name == "Bash", planText: ClaudeCodeAgentProtocol.planText(name: name, input: input)))
                default:
                    continue
                }
            }
            return events
        }
    }

    /// A short, plain-language description of a tool call for the task's activity line.
    static func toolSummary(name: String, input: [String: Any]) -> String {
        func fileName(_ key: String) -> String {
            (input[key] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "a file"
        }
        switch name {
        case "Bash":
            if let description = input["description"] as? String, !description.isEmpty { return description }
            let command = (input["command"] as? String ?? "a command").split(separator: "\n").first.map(String.init) ?? ""
            return "Running " + String(command.prefix(80))
        case "Read": return "Reading " + fileName("file_path")
        case "Edit", "MultiEdit": return "Editing " + fileName("file_path")
        case "Write": return "Writing " + fileName("file_path")
        case "NotebookEdit": return "Editing " + fileName("notebook_path")
        case "Grep", "Glob": return "Searching files"
        case "WebSearch": return "Searching the web" + ((input["query"] as? String).map { " for " + String($0.prefix(60)) } ?? "")
        case "WebFetch": return "Reading a web page"
        case "Task", "Agent": return "Starting a helper agent"
        case "TodoWrite": return "Planning next steps"
        default: return "Using " + name
        }
    }

    static func planText(name: String, input: [String: Any]) -> String? {
        guard name == "TodoWrite", let todos = input["todos"] as? [[String: Any]], !todos.isEmpty else { return nil }
        return todos.compactMap { todo -> String? in
            guard let content = todo["content"] as? String else { return nil }
            let mark = todo["status"] as? String == "completed" ? "[x]" : "[ ]"
            return mark + " " + content
        }.joined(separator: "\n")
    }
}
