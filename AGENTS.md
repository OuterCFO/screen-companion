# OpenClicky Agent Instructions

## Non-Negotiable Rules

1. Check model validity before making assumptions about current model releases or identifiers.
2. Never use emoji unless the user explicitly asks for them.
3. Do not run `xcodebuild` from the terminal. Use Xcode for app builds and permission testing.
4. Do not rename the legacy `cursor-buddy` project folder or scheme unless the user explicitly asks.

## Overview

OpenClicky is a macOS menu-bar companion app by Jason Kneen. It uses SwiftUI with AppKit bridging for a custom floating panel, cursor overlay, Agent Mode dashboard, and macOS permission flows.

The product identity is OpenClicky:

- Bundle identifier: `com.jkneen.openclicky`
- Display name: `OpenClicky`
- Copyright: Jason Kneen

## Architecture

- App type: menu-bar app using `LSUIElement=true`
- Frameworks: SwiftUI, AppKit, AVFoundation, ScreenCaptureKit
- Pattern: `@MainActor` state orchestration with observable SwiftUI views
- Voice input: push-to-talk via a global CGEvent tap and pluggable transcription providers
- Answers: shown in the pointer bubble; spoken replies, realtime voice, wake word, and cloud speech services were removed in October 2026
- Input: typed text, OpenSuperWhisper dictation, or built-in push-to-talk with Apple Speech or local Parakeet
- Screen context: ScreenCaptureKit screenshots when the user invokes help
- Agent Mode: bundled Codex runtime and OpenClicky resource pack in `AppResources/OpenClicky`

## Key Files

- `cursor-buddy/cursor_buddyApp.swift`: app entry point and delegate hookup.
- `cursor-buddy/CompanionManager.swift`: central app state machine for input, screen capture, answers, overlay, settings, and Agent Mode.
- `cursor-buddy/MenuBarPanelManager.swift`: menu-bar item and floating panel lifecycle.
- `cursor-buddy/CompactInputWindowManager.swift` and `MenuBarPromptWindowManager.swift`: the compact panel (input, tasks, History, Connect).
- `cursor-buddy/OverlayWindow.swift`: cursor overlay, agent dock icons, captions, and response cards.
- `cursor-buddy/CodexHUDWindowManager.swift`: Agent Mode dashboard window.
- `cursor-buddy/CodexHomeManager.swift`: prepares the local Codex home using OpenClicky bundled resources.
- `cursor-buddy/ClickyCodexConfigTemplate.swift`: renders Codex configuration for OpenClicky Agent Mode.
- `cursor-buddy/ClickyNextStageParityModels.swift`: knowledge index, permission guide, response-card, and handoff support models.
- `AppResources/OpenClicky/`: bundled Agent Mode instructions, skills, wiki seed, runtime, and completion sound.

## Configuration

OpenClicky should use local keys and user configuration. Do not add Google login or hosted key sync:

- `ANTHROPIC_API_KEY` for Claude responses
- `OPENAI_API_KEY` for Codex/Agent Mode where needed

Do not introduce a hard dependency on a Cloudflare Worker for the final app.

## Inference Routing

Two independent layers — keep them straight:

1. **Provider selection (driven by Settings + bubble selector).** Every model in `OpenClickyModelCatalog` carries a `provider` (`.apple` / `.anthropic` / `.openAI` / `.codex` / `.deepgram` / `.commandLine`). Text answers and Anthropic pointing go through `AnswerProviderRegistry` (`AnswerProvider.swift`, `AnswerProviders.swift`), which maps each family to an ordered provider chain; do not add new `switch` statements on the provider. Connect goes through `SessionLink` sources (`SessionLink.swift`). Agent tasks on Claude models run through `ClaudeCodeAgentEvents.swift` inside `CodexAgentSession`; Codex config only ever receives Codex models. See `docs/PROVIDERS.md`.
   Coarse family chips (Apple / Codex / Claude) live on the response bubble via `OpenClickyVoiceBackendSelector` + `OpenClickyProviderDiscovery` (auto-detect installed CLI / on-device availability — do not package runtimes).
2. **Within-provider ordering (money rule).** For the Claude branch, the Claude Code CLI is the PRIMARY path because it uses the local Claude Code sign-in already paid for. Direct `ClaudeAPI` HTTP is FALLBACK ONLY (CLI missing or throws); `AnswerProviderRegistry.register` rejects chains that put a per-token provider first. Never short-circuit to direct REST for latency or capability reasons — direct REST bills per token. The OpenAI/Codex branch follows the same shape: Codex app server first, OpenAI key fallback. Apple is always free/local. EXEMPTION: realtime speech models (`gpt-realtime-2.1-mini` default, `gpt-realtime-2.1`, `gpt-realtime-1.5`; legacy `gpt-realtime-2` aliases to mini) use the direct Realtime API path only.

Do not delete `ClaudeAPI.swift` or the HTTP path — it is the deliberate fallback. Before editing any Claude/OpenAI call site, confirm the order is CLI/app-server -> key fallback. See `docs/CLAUDE-CODE.md`.


## Development Rules

- Prefer existing design-system tokens and local view patterns.
- Keep UI state updates on the main actor.
- Use async/await for asynchronous work.
- Use AppKit only where SwiftUI cannot provide the needed macOS behavior.
- Keep changes scoped to the requested behavior.
- Preserve user or generated changes in the worktree unless explicitly told to revert them.
- User-facing copy should use the OpenClicky product name.

## Verification

Use lightweight checks that do not disturb macOS permissions:

```sh
swiftc -parse <relevant Swift source files>
```

Do not launch unsigned or throwaway builds for TCC permission testing.

## Session context and user testing

Read `docs/SESSION-HANDOFF.md` first when asked to use the cursor or transfer Codex context.
Authentication does not synchronize conversations; the current supported procedure is an explicit message handoff.
Automatic bidirectional synchronization remains planned in `docs/ROADMAP.md`.
The user performs live UI, shortcut, dictation, and pointer tests; do not inject demos into their task.
