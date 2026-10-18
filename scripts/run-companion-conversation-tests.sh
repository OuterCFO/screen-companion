#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
python3 - "$ROOT" "$OUT" <<'PYTEST'
from pathlib import Path
import sys
s=(Path(sys.argv[1])/'cursor-buddy/CodexAgentSession.swift').read_text()
a=s.index('struct CodexTranscriptEntry:')
b=s.index('struct CodexAgentScreenContextAttachment:', a)
(Path(sys.argv[2])/'Transcript.swift').write_text('import Foundation\n'+s[a:b])
PYTEST
cat > "$OUT/main.swift" <<'SWIFT'
import Foundation
let defaults = UserDefaults(suiteName: "openclicky-tests-" + UUID().uuidString)!
let first = CodexTranscriptEntry(role: .user, text: "Keep the first task context")
var store = CompanionConversationStore(legacyEntries: [first], summary: "first summary")
let firstID = store.activeID
store.startNew()
let secondID = store.activeID
precondition(firstID != secondID && store.active.entries.isEmpty && store.active.summary == nil)
store.update(entries: [CodexTranscriptEntry(role: .assistant, text: "Second task only")], summary: "second summary")
store.save(to: defaults)
store = CompanionConversationStore.load(from: defaults)
precondition(store.activeID == secondID && store.active.entries.first?.text == "Second task only")
precondition(store.select(firstID) && store.active.entries == [first] && store.active.summary == "first summary")
store.removeActive()
precondition(store.activeID == secondID && !store.select(firstID))
precondition(store.conversations.first(where: { $0.id == firstID })?.entries == [first])
store.removeActive()
precondition(store.active.entries.isEmpty && store.activeID != secondID)
store.save(to: defaults)
precondition(CompanionConversationStore.load(from: defaults).activeID == store.activeID)
defaults.set(Data("invalid".utf8), forKey: CompanionConversationStore.defaultsKey)
precondition(CompanionConversationStore.load(from: defaults, legacyEntries: [first]).active.entries == [first])
precondition(SharedCodexSessionContract.isLive("idle") && SharedCodexSessionContract.isLive("active"))
precondition(!SharedCodexSessionContract.isLive("notLoaded") && !SharedCodexSessionContract.isLive("systemError"))
let input: [[String: Any]] = [["type": "text", "text": "same thread"], ["type": "localImage", "path": "/tmp/screen.png"]]
let params = SharedCodexSessionContract.turnParameters(threadID: "existing-thread", input: input)
precondition(Set(params.keys) == ["threadId", "input"])
precondition(params["threadId"] as? String == "existing-thread")
precondition((params["input"] as? [[String: Any]])?.count == 2)
let instructionParams = SharedCodexSessionContract.instructionParameters(threadID: "existing-thread")
precondition(Set(instructionParams.keys) == ["threadId", "items"])
let instruction = (instructionParams["items"] as! [[String: Any]])[0]
precondition(instruction["role"] as? String == "developer")
precondition(((instruction["content"] as! [[String: Any]])[0]["text"] as? String) == SharedCodexSessionContract.responseInstructions)
precondition(SharedCodexSessionContract.needsInstructions(threadID: "existing-thread", defaults: defaults))
SharedCodexSessionContract.acknowledgeInstructions(threadID: "existing-thread", defaults: defaults)
precondition(!SharedCodexSessionContract.needsInstructions(threadID: "existing-thread", defaults: defaults))
precondition(SharedCodexSessionContract.needsInstructions(threadID: "another-thread", defaults: defaults))
defaults.set(["existing-thread": 0], forKey: SharedCodexSessionContract.responseContractDefaultsKey)
precondition(SharedCodexSessionContract.needsInstructions(threadID: "existing-thread", defaults: defaults))
precondition(SharedCodexSessionContract.userText("Okay, I found it.", screenLabels: []) == "Okay, I found it.")
let screenshotPrompt = SharedCodexSessionContract.userText("Okay, I found it.", screenLabels: ["screen0 1280x800"])
precondition(screenshotPrompt.contains("screen0 1280x800") && !screenshotPrompt.contains("cursor_reply") && !screenshotPrompt.contains("POINT:"))
print("PASS: separate developer contract, acknowledged registration, version migration, and compact user input")
store.conversations[store.conversations.count - 1].boundThreadID = "existing-thread"
store.conversations[store.conversations.count - 1].boundThreadTitle = "Codex: original"
store.save(to: defaults)
let reloaded = CompanionConversationStore.load(from: defaults)
precondition(reloaded.active.boundThreadID == "existing-thread" && reloaded.active.title == "Codex: original")
var linked = CompanionConversationStore()
linked.bind(threadID: "same-thread", title: "Same session", entries: [first])
let linkedID = linked.activeID
linked.bind(threadID: "same-thread", title: "Updated title", entries: [first])
precondition(linked.activeID == linkedID && linked.conversations.filter { !$0.archived && $0.boundThreadID == "same-thread" }.count == 1)
linked.conversations.append(.init(id: UUID(), entries: [first], summary: nil, boundThreadID: "same-thread", boundThreadTitle: "Duplicate"))
linked.save(to: defaults)
let repaired = CompanionConversationStore.load(from: defaults)
precondition(repaired.activeID == linkedID)
precondition(repaired.conversations.filter { !$0.archived && $0.boundThreadID == "same-thread" }.count == 1)
precondition(repaired.conversations.filter { $0.boundThreadID == "same-thread" }.allSatisfy { $0.entries == [first] })
linked.bind(threadID: "other-thread", title: "Other session", entries: [])
precondition(linked.activeID != linkedID)
precondition(SharedCodexSessionContract.isValidScreenshotPoint(CGPoint(x: 727, y: 360), width: 1280, height: 800))
precondition(!SharedCodexSessionContract.isValidScreenshotPoint(CGPoint(x: -1, y: 360), width: 1280, height: 800))
precondition(!SharedCodexSessionContract.isValidScreenshotPoint(CGPoint(x: CGFloat.infinity, y: 360), width: 1280, height: 800))
precondition(!SharedCodexSessionContract.isValidScreenshotPoint(CGPoint(x: 2000, y: 360), width: 1280, height: 800))
precondition(!SharedCodexSessionContract.isValidScreenshotPoint(CGPoint(x: 1, y: 1), width: 0, height: 800))
print("PASS: verified screenshot target and invalid/out-of-range coordinate rejection")
print("PASS: reconnect identity, duplicate-link repair, active selection, history preservation, and distinct sessions")
print("PASS: live-only binding, unchanged session settings, screenshot input, and reconnect metadata")
print("PASS: independent tasks, selection, persistence, archive, final-task removal, and legacy fallback")
SWIFT
swiftc "$OUT/Transcript.swift" "$ROOT/cursor-buddy/CompanionConversationStore.swift" "$ROOT/cursor-buddy/SharedCodexSessionContract.swift" "$OUT/main.swift" -o "$OUT/check"
"$OUT/check"
