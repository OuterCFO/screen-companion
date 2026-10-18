#!/usr/bin/env bash
# Compile and run pure catalog, discovery, placement and dismissal contract tests against
# SHIPPED sources (OpenClickyModelCatalog, OpenClickyProviderDiscovery,
# CodexRuntimeLocator, ReplyVisibilityPolicy).
# Avoids xcodebuild (forbidden for day-to-day agent work per AGENTS.md).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/openclicky-provider-catalog-tests-$$"
mkdir -p "$OUT"
trap 'rm -rf "$OUT"' EXIT

SDK="$(xcrun --show-sdk-path --sdk macosx)"
TARGET="$(uname -m)-apple-macos26.0"

# Minimal AppBundleConfiguration surface used only by discovery key probes.
cat > "$OUT/AppBundleConfigurationStub.swift" <<'SWIFT'
import Foundation

nonisolated enum AppBundleConfiguration {
    static func openAIAPIKey() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let v = env["OPENAI_API_KEY"], !v.isEmpty { return v }
        return UserDefaults.standard.string(forKey: "openClickyCodexAgentAPIKey")
    }

    static func anthropicAPIKey() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let v = env["ANTHROPIC_API_KEY"], !v.isEmpty {
            return v.hasPrefix("sk-ant-api") ? v : nil
        }
        if let v = UserDefaults.standard.string(forKey: "openClickyAnthropicAPIKey"), !v.isEmpty {
            return v.hasPrefix("sk-ant-api") ? v : nil
        }
        return nil
    }
}
SWIFT

cat > "$OUT/main.swift" <<'SWIFT'
import Foundation

var failures = 0
func expect(_ cond: @autoclosure () -> Bool, _ msg: String) {
    if !cond() {
        print("FAIL: \(msg)")
        failures += 1
    } else {
        print("PASS: \(msg)")
    }
}

// --- Requested defaults ---
expect(OpenClickyModelCatalog.defaultCodexActionsModelID == "gpt-6-luna", "GPT-6 Luna default")
expect(OpenClickyModelCatalog.voiceResponseModel(withID: "gpt-6-luna").id == "gpt-6-luna", "Luna response resolves")
expect(OpenClickyModelCatalog.computerUseModels.contains { $0.id == "gpt-6-luna" }, "Luna computer-use option")
expect(OpenClickyModelCatalog.codexActionsModels.contains { $0.id == "gpt-6-luna" }, "Luna agent option")

// --- Claude IDs resolve in both the Claude CLI and the Messages API ---
for option in OpenClickyModelCatalog.voiceResponseModels + OpenClickyModelCatalog.computerUseModels where option.provider == .anthropic {
    expect(option.id.hasPrefix("claude-"), "\(option.id) is a full Claude model ID")
}
expect(OpenClickyModelCatalog.voiceResponseModel(withID: "fable-5").id == "claude-fable-5-1", "saved legacy fable-5 migrates")
expect(OpenClickyModelCatalog.voiceResponseModel(withID: "sonnet-5").id == "claude-sonnet-5-5", "saved legacy sonnet-5 migrates")
expect(OpenClickyModelCatalog.computerUseModel(withID: "opus-5").id == "claude-opus-5-5", "saved legacy opus-5 migrates")
expect(OpenClickyModelCatalog.delegationModel(withID: nil).id == "claude-sonnet-5-5", "delegation default is a real ID")
expect(OpenClickyModelCatalog.defaultAnthropicResponseModelID == "claude-sonnet-5-5", "Claude default is on every plan")
expect(OpenClickyModelCatalog.voiceResponseModel(withID: "claude-fable-5-1").id == "claude-fable-5-1", "Fable stays selectable")
expect(OpenClickyModelCatalog.agentModel(withID: "claude-opus-5-5").provider == .anthropic, "Claude agent models resolve")
expect(OpenClickyModelCatalog.agentModel(withID: "gpt-6-luna").id == "gpt-6-luna", "Codex agent models resolve")
expect(OpenClickyModelCatalog.codexActionsModel(withID: "claude-opus-5-5").id == OpenClickyModelCatalog.defaultCodexActionsModelID, "Codex config never receives a Claude model")
expect(!OpenClickyModelCatalog.codexActionsModels.contains { $0.provider == .anthropic }, "Codex model list stays Codex-only")

// --- Catalog family mapping ---
let apple = OpenClickyModelCatalog.voiceResponseModel(withID: OpenClickyModelCatalog.appleFoundationModelID)
expect(apple.id == OpenClickyModelCatalog.appleFoundationModelID, "apple model id resolves")
expect(apple.provider == .apple, "apple model has provider .apple")
expect(apple.provider.voiceBackendFamily == .apple, "apple maps to apple family")
expect(apple.maxOutputTokens >= 64_000, "apple has non-short TTS budget")

let claudeDefault = OpenClickyModelCatalog.voiceResponseModel(withID: OpenClickyVoiceBackendFamily.claude.defaultModelID)
expect(claudeDefault.provider == .anthropic, "claude family default is anthropic")
expect(claudeDefault.provider.voiceBackendFamily == .claude, "claude family maps")

let codexDefault = OpenClickyModelCatalog.voiceResponseModel(withID: OpenClickyVoiceBackendFamily.codex.defaultModelID)
expect(codexDefault.provider.voiceBackendFamily == .codex, "codex family default maps to codex family")
expect(OpenClickyVoiceBackendFamily.apple.defaultModelID == OpenClickyModelCatalog.appleFoundationModelID, "apple default model id")
expect(claudeDefault.provider == .anthropic, "claude default is a text response model")
expect(OpenClickyVoiceBackendFamily.codex.defaultModelID == OpenClickyModelCatalog.defaultCodexActionsModelID, "codex default model id")
expect(OpenClickyVoiceBackendFamily.allCases.count == 3, "exactly three families")
expect(Set(OpenClickyVoiceBackendFamily.allCases.map(\.rawValue)) == Set(["apple", "codex", "claude"]), "family raw values")

expect(OpenClickyModelCatalog.voiceResponseModel(withID: "gpt-realtime-2.1-mini").id == OpenClickyModelCatalog.defaultVoiceResponseModelID, "removed realtime model migrates to the text default")

// --- Discovery ---
let rows = OpenClickyProviderDiscovery.availability()
expect(rows.count == 3, "discovery returns 3 rows")
expect(rows.map(\.family) == [.apple, .codex, .claude], "discovery order apple,codex,claude")
for row in rows {
    expect(!row.statusLabel.isEmpty, "\(row.family) has status label")
    expect(!row.detail.isEmpty, "\(row.family) has detail")
    print("  discovery \(row.family.rawValue): available=\(row.isAvailable) status=\(row.statusLabel)")
}

for family in OpenClickyVoiceBackendFamily.allCases {
    let fromRows = rows.first { $0.family == family }?.isAvailable ?? false
    expect(OpenClickyProviderDiscovery.isAvailable(family) == fromRows, "isAvailable(\(family)) matches row")
}

// --- Auto-hide cancel-before-reschedule (response bubble lifetime) ---
let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
let size = CGSize(width: 300, height: 80)
let right = ReplyBubblePlacement.origin(anchor: CGPoint(x: 990, y: 300), size: size, visibleFrame: visible)
expect(right.x + size.width <= visible.maxX, "reply flips away from right display edge")
let bottom = ReplyBubblePlacement.origin(anchor: CGPoint(x: 200, y: 5), size: size, visibleFrame: visible)
expect(bottom.y >= visible.minY, "reply stays above bottom display edge")
let negativeDisplay = CGRect(x: -1000, y: -200, width: 1000, height: 800)
let negative = ReplyBubblePlacement.origin(anchor: CGPoint(x: -990, y: -195), size: size, visibleFrame: negativeDisplay)
expect(negative.x >= negativeDisplay.minX && negative.y >= negativeDisplay.minY, "reply respects negative-origin display")
expect(ScreenTutorRoutingPolicy.shouldStayInTutor("Point to the heading on my screen"), "screen pointing remains a direct answer")
expect(!ScreenTutorRoutingPolicy.shouldStayInTutor("Run an agent to delete the page"), "explicit agent work keeps its route")
for (text, expected) in [
    ("start an agent to tell me which macOS version I'm running", "tell me which macOS version I'm running"),
    ("Start an agent to tell me which macOS version I'm running.", "tell me which macOS version I'm running"),
    ("please run a background agent that cleans my Downloads folder", "cleans my Downloads folder"),
    ("can you spin up an agent to summarize the logs?", "summarize the logs"),
    ("have an agent check the build", "check the build"),
    ("agent: rename the screenshots", "rename the screenshots"),
    ("New task - draft the email", "draft the email"),
    ("start a new task: plan my week", "plan my week"),
    ("Go and run an agent and tell me uh which version of Mac OS I am running and also go and tell me if I have received any new emails",
     "tell me uh which version of Mac OS I am running and also go and tell me if I have received any new emails"),
    ("okay so run an agent to check my disk space", "check my disk space"),
    ("uh, start agent tell me the weather", "tell me the weather"),
    ("can you kick off a background task that tidies my desktop", "tidies my desktop")] {
    expect(ScreenTutorRoutingPolicy.explicitAgentInstruction(text) == expected, "explicit agent request: \(text)")
}
for text in ["what is the agent framework on my screen?", "open the settings menu", "how do agents work in this app",
             "start an agent", "the agent result never came back", "use the menu to start",
             "start an agent framework", "go and open the settings"] {
    expect(ScreenTutorRoutingPolicy.explicitAgentInstruction(text) == nil, "not an agent request: \(text)")
}
expect(ScreenTutorRoutingPolicy.agentHandoffNote.contains("[AGENT:"), "handoff note teaches the directive")
let handoffAnswer = "[POINT:none]\n[AGENT: Check the macOS version and count today's unread emails]\n<cursor_reply>\nStarted a background task.\n</cursor_reply>"
expect(ScreenTutorRoutingPolicy.agentHandoffInstruction(fromAnswer: handoffAnswer) == "Check the macOS version and count today's unread emails", "handoff instruction parsed after POINT")
expect(ScreenTutorRoutingPolicy.agentHandoffInstruction(fromAnswer: "[POINT:none]\nYou're on macOS 27.") == nil, "plain answers do not hand off")
expect(ScreenTutorRoutingPolicy.agentHandoffInstruction(fromAnswer: "```\n[AGENT: example only here]\n```") == nil, "fenced examples are ignored")
expect(ScreenTutorRoutingPolicy.agentHandoffInstruction(fromAnswer: "[AGENT: go]") == nil, "one-word instructions are rejected")
expect(!ScreenTutorRoutingPolicy.removingAgentHandoff("Sure\n[AGENT: partial dire").contains("AGENT"), "streaming directive is hidden")
expect(ScreenTutorRoutingPolicy.handoffStartedMessage(instruction: String(repeating: "word ", count: 40)).contains("…"), "long instructions are shortened")
var visibility = ReplyVisibilityPolicy()
expect(visibility.canPresent, "new reply can present")
visibility.dismiss()
expect(!visibility.canPresent, "dismissed reply suppresses late chunks")
visibility.dismiss()
expect(!visibility.canPresent, "repeated dismissal stays dismissed")
visibility.beginNewReply()
expect(visibility.canPresent, "new question resets dismissal")

precondition(!ReplyVisibilityPolicy.shouldResumeFollowing(isPinned: true, mouseTravel: 0, timeSinceArrival: 3))
precondition(!ReplyVisibilityPolicy.shouldResumeFollowing(isPinned: true, mouseTravel: 12, timeSinceArrival: 3))
precondition(ReplyVisibilityPolicy.shouldResumeFollowing(isPinned: true, mouseTravel: 25, timeSinceArrival: 3))
precondition(!ReplyVisibilityPolicy.shouldResumeFollowing(isPinned: false, mouseTravel: 100, timeSinceArrival: 3))
precondition(!ReplyVisibilityPolicy.shouldResumeFollowing(isPinned: true, mouseTravel: .nan, timeSinceArrival: 3))
precondition(!ReplyVisibilityPolicy.shouldResumeFollowing(isPinned: true, mouseTravel: 100, timeSinceArrival: 0))
precondition(!ReplyVisibilityPolicy.shouldResumeFollowing(isPinned: true, mouseTravel: 100, timeSinceArrival: 2.999))
precondition(ReplyVisibilityPolicy.shouldResumeFollowing(isPinned: true, mouseTravel: 100, timeSinceArrival: 3))
precondition(!ReplyVisibilityPolicy.shouldResumeFollowing(isPinned: true, mouseTravel: 100, timeSinceArrival: .nan))
print("PASS: pointing hold blocks movement until three seconds after arrival")
print("PASS: reply persists at rest but intentional mouse movement resumes following")

if failures == 0 {
    print("\nALL PASSED")
    exit(0)
} else {
    print("\n\(failures) FAILURE(S)")
    exit(1)
}
SWIFT

xcrun swiftc -O -sdk "$SDK" -target "$TARGET" \
  -o "$OUT/provider_tests" \
  "$ROOT/cursor-buddy/OpenClickyModelCatalog.swift" \
  "$ROOT/cursor-buddy/CodexRuntimeLocator.swift" \
  "$ROOT/cursor-buddy/OpenClickyProviderDiscovery.swift" \
  "$ROOT/cursor-buddy/ClaudeCodeCLIProtocol.swift" \
  "$ROOT/cursor-buddy/CommandLineProviderConfig.swift" \
  "$ROOT/cursor-buddy/ReplyVisibilityPolicy.swift" \
  "$ROOT/cursor-buddy/ReplyBubblePlacement.swift" \
  "$ROOT/cursor-buddy/ScreenTutorRoutingPolicy.swift" \
  "$OUT/AppBundleConfigurationStub.swift" \
  "$OUT/main.swift"

"$OUT/provider_tests"
