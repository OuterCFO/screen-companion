#!/usr/bin/env bash
# Pure contract tests for the Antigravity CLI (agy) integration (no CLI, network, or sign-in needed).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

cat > "$OUT/main.swift" <<'SWIFT'
import Foundation
typealias P = AntigravityCLIProtocol

// Discovery: explicit override first, the installer's ~/.local/bin next, PATH last
let candidates = P.executableCandidates(home: "/Users/u", user: "u",
    environment: ["PATH": "/custom/bin", "OPENCLICKY_AGY_EXECUTABLE": "/opt/agy"])
precondition(candidates.first == "/opt/agy" && candidates[1] == "/Users/u/.local/bin/agy")
precondition(candidates.contains("/etc/profiles/per-user/u/bin/agy") && candidates.last == "/custom/bin/agy")
print("PASS: executable discovery order")

// Arguments: headless, streamed, no slash commands, bounded, optional read context
func value(_ args: [String], _ flag: String) -> String? { args.firstIndex(of: flag).map { args[$0 + 1] } }
let args = P.arguments(model: "gemini-4-neon-low", prompt: "/plan PROMPT", contextFolders: ["/ctx", ""])
precondition(value(args, "-p") == "/plan PROMPT" && value(args, "--model") == "gemini-4-neon-low")
precondition(value(args, "--output-format") == "stream-json" && args.contains("--disable-slash-commands"))
precondition(value(args, "--add-dir") == "/ctx" && args.filter { $0 == "--add-dir" }.count == 1)
precondition(!args.contains("--dangerously-skip-permissions") && !args.contains("--mode"))
print("PASS: arguments stay headless and never auto-approve tools")

// Prompt: policy first, screenshot paths and read-only rule before the question, question last
let prompt = P.prompt(systemPrompt: "SYS", history: [("q1", "a1")],
                      screenshots: [("/tmp/t/screen-1.png", "main display")], contextFolder: "/ctx", prompt: "QUESTION")
precondition(prompt.hasPrefix("OpenClicky current voice policy") && prompt.hasSuffix("QUESTION"))
precondition(prompt.contains("1. /tmp/t/screen-1.png (main display)") && prompt.contains("never edit files"))
precondition(prompt.contains("User: q1") && prompt.contains("/ctx"))
let bare = P.prompt(systemPrompt: "", history: [], screenshots: [], contextFolder: nil, prompt: "Q")
precondition(!bare.contains("screenshot") && !bare.contains("project") && bare.hasSuffix("Q"))
print("PASS: prompt layout")

// Environment: Google sign-in only, CLI folder on PATH
let env = P.environment(base: ["PATH": "/usr/bin", "GEMINI_API_KEY": "k", "GOOGLE_API_KEY": "k", "HOME": "/Users/u"],
                        executable: URL(fileURLWithPath: "/Users/u/.local/bin/agy"))
precondition(env["GEMINI_API_KEY"] == nil && env["GOOGLE_API_KEY"] == nil && env["HOME"] == "/Users/u")
precondition(env["PATH"]!.hasPrefix("/Users/u/.local/bin:/usr/bin"))
print("PASS: environment removes API keys")

// Stream parsing, with lines recorded from agy 1.5.18
func json(_ object: [String: Any]) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
}
func step(_ index: Int, _ type: String, delta: String? = nil) -> String {
    var update: [String: Any] = ["conversation_id": "c", "step_index": index, "state": "ACTIVE", "step_type": type]
    if let delta { update["text_delta"] = delta }
    return json(["event": "step_update", "step_update": update])
}
var state = P.StreamState()
state.consume(line: #"{"event":"init","conversation_id":"c","init":{"cwd":"/tmp/x","tools":["view_file"]}}"#)
state.consume(line: step(1, "agent_response", delta: "Let me look."))
precondition(state.text == "Let me look.")
state.consume(line: step(2, "tool"))
state.consume(line: step(3, "agent_response", delta: "[POINT:none]\n<cursor_"))
state.consume(line: step(3, "agent_response", delta: "reply>Hi</cursor_reply>"))
precondition(state.text == "[POINT:none]\n<cursor_reply>Hi</cursor_reply>" && state.finalText == nil)
state.consume(line: json(["event": "result", "result": ["status": "SUCCESS", "response": "FINAL\n"]]))
precondition(state.finalText == "FINAL" && state.failure == nil)
state.consume(line: step(4, "agent_response", delta: "late"))
precondition(state.text == "[POINT:none]\n<cursor_reply>Hi</cursor_reply>")
print("PASS: streams the latest answer step and keeps the final result")

let failed = P.StreamState.parse(Data((json(["event": "result", "result": ["conversation_id": "", "status": "ERROR", "response": "",
    "error": "invalid model selection (--model \"x\"): model x is not recognized\nAvailable models:\n  Gemini 4 Neon (Low)"]]) + "\n").utf8))
precondition(failed.failure == "Antigravity: invalid model selection (--model \"x\"): model x is not recognized")
let partial = P.StreamState.parse(Data((step(1, "agent_response", delta: "par") + "\n{\"event\":\"res").utf8))
precondition(partial.text == "par" && partial.finalText == nil && partial.failure == nil)
print("PASS: failures keep the first error line; a half-written line is ignored")

precondition(Set(P.models.map(\.id)).count == P.models.count && P.models.first?.id == "gemini-4-neon-low")
print("PASS: model list")
SWIFT

xcrun swiftc -O -target "$(uname -m)-apple-macos26.0" -o "$OUT/agy_tests" \
  "$ROOT/cursor-buddy/AntigravityCLIProtocol.swift" "$ROOT/cursor-buddy/ClaudeCodeCLIProtocol.swift" "$OUT/main.swift"
"$OUT/agy_tests"
