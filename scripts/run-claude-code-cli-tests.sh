#!/usr/bin/env bash
# Pure contract tests for the direct Claude Code CLI integration (no CLI, network, or sign-in needed).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

cat > "$OUT/main.swift" <<'SWIFT'
import Foundation
typealias P = ClaudeCodeCLIProtocol

// Linked session identity
let id = "820bb75b-2469-4aca-821f-a06ede2c7f2b"
precondition(P.sessionID(fromLinkedThreadID: P.linkedThreadID(sessionID: id)) == id)
precondition(P.sessionID(fromLinkedThreadID: "019a-codex-thread") == nil)
precondition(P.sessionID(fromLinkedThreadID: "claude:../../etc/passwd") == nil)
print("PASS: linked Claude sessions are distinguished from Codex threads and validated")

// Discovery covers GUI-launch PATHs, including Nix profiles, with an explicit override first
let candidates = P.executableCandidates(home: "/Users/u", user: "u",
    environment: ["PATH": "/custom/bin", "OPENCLICKY_CLAUDE_EXECUTABLE": "/opt/claude"])
precondition(candidates.first == "/opt/claude")
precondition(candidates.contains("/Users/u/.local/bin/claude") && candidates.contains("/etc/profiles/per-user/u/bin/claude"))
precondition(candidates.last == "/custom/bin/claude")
print("PASS: executable discovery order")

// Standalone turns are isolated and stateless
let standalone = P.standaloneArguments(model: "claude-fable-5-1", systemPrompt: "SYS")
func value(_ args: [String], _ flag: String) -> String? { args.firstIndex(of: flag).map { args[$0 + 1] } }
precondition(value(standalone, "--model") == "claude-fable-5-1" && value(standalone, "--system-prompt") == "SYS")
precondition(value(standalone, "--setting-sources") == "" && standalone.contains("--no-session-persistence"))
precondition(standalone.contains("--strict-mcp-config") && value(standalone, "--tools") == "WebSearch,WebFetch")
precondition(value(standalone, "--input-format") == "stream-json" && standalone.contains("--include-partial-messages"))
// Linked turns keep the session's own model and settings, and stay read-only
let resume = P.resumeArguments(sessionID: id, appendedSystemPrompt: "CONTRACT")
precondition(value(resume, "--resume") == id && value(resume, "--append-system-prompt") == "CONTRACT")
precondition(!resume.contains("--model") && !resume.contains("--system-prompt") && !resume.contains("--no-session-persistence"))
precondition(!resume.contains("--setting-sources") && !resume.contains("--fork-session"))
let allowed = value(resume, "--allowedTools")!.split(separator: ",").map(String.init)
precondition(Set(allowed) == ["Read", "Grep", "Glob", "WebSearch", "WebFetch"])
print("PASS: standalone isolation and read-only in-place resume arguments")

// Subscription sign-in is used unless a custom provider is configured
let exe = URL(fileURLWithPath: "/nix/bin/claude")
let base = ["PATH": "/usr/bin", "ANTHROPIC_API_KEY": "sk-ant-api-x", "ANTHROPIC_AUTH_TOKEN": "t", "HOME": "/Users/u"]
let plan = P.environment(base: base, executable: exe, maxOutputTokens: 64_000, customBaseURL: nil, customAPIKey: "k")
precondition(plan["ANTHROPIC_API_KEY"] == nil && plan["ANTHROPIC_AUTH_TOKEN"] == nil && plan["ANTHROPIC_BASE_URL"] == nil)
precondition(plan["PATH"]!.hasPrefix("/nix/bin:") && plan["CLAUDE_CODE_MAX_OUTPUT_TOKENS"] == "64000" && plan["HOME"] == "/Users/u")
let custom = P.environment(base: base, executable: exe, maxOutputTokens: nil, customBaseURL: "https://proxy.example", customAPIKey: "k")
precondition(custom["ANTHROPIC_BASE_URL"] == "https://proxy.example" && custom["ANTHROPIC_API_KEY"] == "k")
precondition(custom["CLAUDE_CODE_MAX_OUTPUT_TOKENS"] == nil)
print("PASS: credentials are stripped for plan sign-in and kept only for a custom provider")

// stream-json input
let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2])
let line = try P.userMessageLine(textBlocks: ["policy", "", "question"], images: [(png, "screen0"), (Data([0xFF, 0xD8]), "screen1")])
precondition(line.last == 0x0A && !line.dropLast().contains(0x0A))
let message = try JSONSerialization.jsonObject(with: line) as! [String: Any]
let content = (message["message"] as! [String: Any])["content"] as! [[String: Any]]
precondition(message["type"] as? String == "user" && content.count == 4)
precondition(content.map { $0["type"] as! String } == ["text", "text", "image", "image"])
precondition(((content[2]["source"] as! [String: Any])["media_type"] as? String) == "image/png")
precondition(((content[3]["source"] as! [String: Any])["media_type"] as? String) == "image/jpeg")
let blocks = P.standaloneTextBlocks(systemPrompt: "rules", history: [("hi", "hello")], imageLabels: ["screen0 1280x800"], prompt: "where?")
precondition(blocks.count == 4 && blocks[1] == "Recent conversation:\nUser: hi\nOpenClicky: hello" && blocks.last == "where?")
precondition(P.linkedUserText("Where is it?", screenLabels: []) == "Where is it?")
precondition(P.linkedUserText("Where is it?", screenLabels: ["screen0 1280x800"]) == "Where is it?\n\n[OpenClicky current screenshots: screen0 1280x800]")
print("PASS: user message, image media types, and per-turn context blocks")

// stream-json output, including a web search between two assistant messages
func json(_ object: [String: Any]) -> String { String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)! }
func delta(_ text: String) -> String { json(["type": "stream_event", "event": ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": text]]]) }
let start = json(["type": "stream_event", "event": ["type": "message_start"]])
var state = P.StreamState()
var events: [P.StreamEvent] = []
for raw in [json(["type": "system", "subtype": "hook_started", "session_id": id]),
            json(["type": "system", "subtype": "init", "session_id": id]), start, delta("Let me "), delta("check."),
            json(["type": "assistant", "message": ["content": [["type": "text", "text": "Let me check."]]]]), "not json", start,
            delta("[POINT:none]"), json(["type": "result", "subtype": "success", "is_error": false, "result": "[POINT:none]"]),
            delta("late")] {
    if let event = state.consume(line: raw) { events.append(event) }
}
precondition(events == [.started(sessionID: id), .text("Let me "), .text("Let me check."),
                        .text("Let me check.\n\n[POINT:none]"), .finished("[POINT:none]")])
var failed = P.StreamState()
precondition(failed.consume(line: json(["type": "result", "subtype": "success", "is_error": true, "result": "Not logged in · Please run /login"]))
             == .failed("Claude Code: Not logged in · Please run /login"))
var empty = P.StreamState()
_ = empty.consume(line: delta("streamed"))
precondition(empty.consume(line: json(["type": "result", "is_error": false, "result": ""])) == .finished("streamed"))
print("PASS: streaming accumulation, message separation, final result, sign-in error, and late events")

// Session files
let records: [[String: Any]] = [
    ["type": "queue-operation", "sessionId": id],
    ["type": "user", "cwd": "/Users/u/project", "uuid": "u1", "timestamp": "2026-10-18T10:00:00.000Z",
     "message": ["role": "user", "content": "Fix the login bug"]],
    ["type": "user", "cwd": "/Users/u/project", "isMeta": true, "message": ["role": "user", "content": "meta"]],
    ["type": "user", "cwd": "/Users/u/project", "message": ["role": "user", "content": "<command-name>/model</command-name>"]],
    ["type": "assistant", "uuid": "a1", "message": ["role": "assistant", "content": [["type": "text", "text": "Looking."]]]],
    ["type": "assistant", "uuid": "a2", "message": ["role": "assistant", "content": [["type": "tool_use", "name": "Read"]]]],
    ["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "content": "file"]]]],
    ["type": "assistant", "uuid": "a3", "message": ["role": "assistant", "content": [["type": "text", "text": "Fixed it."]]]],
    ["type": "assistant", "isSidechain": true, "message": ["role": "assistant", "content": [["type": "text", "text": "subagent"]]]],
    ["type": "custom-title", "customTitle": "Login fix", "sessionId": id]
]
let lines = records.map { Substring(json($0)) } + ["{broken"]
let parsed = P.parseSession(lines: lines, id: id, modifiedAt: Date(timeIntervalSince1970: 0))
precondition(parsed.summary == P.SessionSummary(id: id, title: "Login fix", cwd: "/Users/u/project", modifiedAt: Date(timeIntervalSince1970: 0)))
precondition(parsed.messages.map(\.text) == ["Fix the login bug", "Looking.\n\nFixed it."])
precondition(parsed.messages.map(\.isUser) == [true, false])
let untitled = P.parseSession(lines: Array(lines.prefix(2)), id: id, modifiedAt: Date())
precondition(untitled.summary?.title == "Fix the login bug")
precondition(P.parseSession(lines: [], id: id, modifiedAt: Date()).summary == nil)
print("PASS: session title, folder, visible transcript, and skipped meta/tool/sidechain records")

// Live interactive owners
let owners = P.liveOwners(registryRecords: [["pid": 10, "sessionId": "a", "status": "busy"], ["pid": 11, "sessionId": "b"],
                                            ["pid": 12, "sessionId": "dead", "status": "idle"], ["sessionId": "nopid"]]) { $0 != 12 }
precondition(owners == ["a": "busy", "b": "running"])
precondition(P.configDirectory(home: "/Users/u", environment: [:]).path == "/Users/u/.claude")
precondition(P.configDirectory(home: "/Users/u", environment: ["CLAUDE_CONFIG_DIR": "/tmp/cfg"]).path == "/tmp/cfg")
print("PASS: live-owner registry and config directory")
SWIFT

xcrun swiftc -O -target "$(uname -m)-apple-macos26.0" -o "$OUT/claude_cli_tests" \
  "$ROOT/cursor-buddy/ClaudeCodeCLIProtocol.swift" "$OUT/main.swift"
"$OUT/claude_cli_tests"
