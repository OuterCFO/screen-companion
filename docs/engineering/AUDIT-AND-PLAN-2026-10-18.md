# Audit and rebuild plan

Date: 18 October 2026.
Revision audited: 8152597 plus the older uncommitted shared-contract and dashboard changes.
Method: code reading, a full-target typecheck against Xcode's built modules, the project's source checks, and the app's own logs from 5 to 18 October 2026.
The June reviews (now in `docs/history/`) were re-checked; many of their findings were fixed on 23 June and are not repeated here.

## Goal

Keep today's daily workflow working at every step: Command + Option, OpenSuperWhisper dictation, the compact panel, the AI pointer and bubble, tasks, History, and Connect.
Make the answer path smooth and fast.
Make the AI provider a plug-in: adding a model or CLI should mean one new file and one registry line.
Publish a clean, documented, MIT-licensed project that anyone can build, under a new name chosen later.

## What the evidence shows

### Speed

Claude Code answers took 2.9 to 5.1 seconds end to end on 18 October.
Of that, screen capture took 70 to 480 ms, and the model took the rest.
Earlier GPT-6 Luna turns through Codex had a median of about 18 seconds (see `DECISIONS-API-ASSESSMENT.md`).
The provider is the dominant factor, so the provider layer is the first priority.

### Reliability

From 12 days of logs:

- 43 turns logged `voice.response_failure_silent` because the speech model is set to OpenAI Realtime, which needs an API key that is not configured.
  Playback is muted, so the user saw nothing, but every turn does failing work.
- Codex failures surfaced as answers failing: bundled executable missing (5), app-server exited or not running (4), and a ChatGPT usage limit (4).
- Logged errors from the Claude Code path: none.

### Structure

- The app is about 79,000 lines of Swift in 130 files, plus 11,000 lines in local packages.
- `CompanionManager.swift` alone is 16,750 lines; one class owns voice, routing, providers, computer use, agents, and settings.
- Provider choice is a `switch` repeated in 10 places, so a new provider means editing all of them.
- Two "Connect" backends now exist (Codex, Claude Code) without a shared interface.
- Background agent tasks can only run on Codex.

### Features actually used (logs, 5 to 18 October)

Used: compact questions (about 1,000 requests), dictation, the pointer and bubble, circle select, tasks and History, a few agent tasks (7 created).
Not seen in logs: the notch pill, desktop pet, 3D model generation, the built-in Browser Workspace, widgets, camera input, wake word, voice playback (muted), realtime speech, Deepgram and AssemblyAI transcription.
Together those unused areas are roughly 20,000 lines.
The compact panel shares `OpenClickyNotchCaptureWindowManager.swift` with the notch, so it must be separated before the notch can go.

### Smaller defects found

- `response_panel.geometry` is logged on every streamed chunk (about 25 disk writes per answer).
- The log redactor hides any field containing "token", including latency fields such as `firstTokenLatencyMs`.
- The app sleeps the main thread for 300 ms during duplicate-instance startup (`cursor_buddyApp.swift`).
- Developer paths from the original author remain (`/Users/jkneen/...` in `OpenClickyComputerUseRuntime.swift` and `CompanionManager+Onboarding.swift`), and queue labels still use `com.jkneen.openclicky`.
- The default Claude model, Fable 5.1, is not available on the current Claude plan ("out of usage credits"); Sonnet 5.5 works.

## Decisions (18 October 2026)

- Keep the existing app and workflow; refactor in phases rather than starting over.
- Temporary repository name: `screen-companion`; the final name is chosen in Phase 7.
- Remove all four unused areas: the notch bar and desktop pet; 3D models and the built-in browser; spoken replies, wake word, and extra speech services; widgets and camera input.
  OpenSuperWhisper dictation and the compact panel stay.
- Start with Phases 0 and 1.

## Plan

Each phase ends in a working build that the user installs and tests before the next phase starts.
Checks per phase: source checks, the full-target typecheck, a native Xcode build, install, and a short live test.

### Phase 0: New home (done 18 October)

1. Create a new public GitHub repository under a temporary name, with the full OpenClicky history, MIT license, and credit to Jason Kneen's OpenClicky.
2. Point all further work there; OuterCFO/openclicky stays as it is.

### Phase 1: Provider plug-ins (done 18 October; native build installed and live-tested)

1. Define one `AnswerProvider` interface: stream an answer from a prompt, screenshots, and recent history, and report capabilities (images, web search, sign-in source, cost model).
2. Move the existing providers behind it: Claude Code CLI, Codex app-server, Apple on-device, OpenAI API, Anthropic API.
3. Replace the 10 provider switches with one registry lookup.
4. Define one `SessionLink` interface for Connect, implemented by Codex and Claude Code.
5. Add a generic command-line provider so any CLI that reads a prompt and prints an answer can be added by configuration.
6. Done when: adding a provider touches one new file and one registry line, and all existing providers pass the same contract tests.

### Phase 2: Smooth daily flow (done 18 October; live-tested, geometry sampler trimmed after test)

1. Stop the failing realtime speech work when playback is muted or no key exists.
2. Log panel geometry once per answer, and fix the redaction of latency fields.
3. Remove the startup main-thread sleep.
4. Default to a Claude model the plan supports, with a clear message when a model is unavailable instead of a failed bubble.
5. Done when: no silent failure events in a normal session, and median time to first text stays under 2 seconds on Claude.

### Phase 3: Background tasks on any provider (done 18 October; live-tested: 4 Claude Code agent tasks, 8.5 to 12.6 seconds, results shown in the bubble)

1. Keep `CodexAgentSession` as the task model and give it a second runtime: Claude models run `claude -p` turns whose stream events map onto the same transcript, status, and completion helpers as Codex events.
2. Claude agents use the user's Claude Code settings, `auto` permission mode (`acceptEdits` in the browser sandbox), and resume their session on follow-ups.
3. Done when: an agent task can be started on Claude Code or Codex from the same menu.

### Phase 4: Slim down (done 18 October; live-tested)

1. Remove the four unused areas listed under Decisions, separating the compact panel from the notch first.
2. Done when: the app builds without them and the daily workflow is unchanged.

### Phase 5: Split the central class (implemented 19 October; awaiting native build and live test)

1. Move code out of `CompanionManager.swift` into focused coordinators: answer routing, tasks and sessions, computer use, agents, startup and permissions.
2. Moves only, no behavior change, one coordinator per step with a typecheck after each.
3. Done when: no file is over about 3,000 lines and the routing logic has unit tests.
4. Result: `CompanionManager.swift` went from 14,219 to about 1,500 lines; behavior moved into 16 new extension files, the largest being `CompanionManager+ComputerUse.swift` at about 2,700 lines.
   A line-by-line comparison against e7fc134 shows the same code apart from dropped `private` modifiers and one stale comment.
   `VoiceRouter` and `SpokenText` moved to their own files, and `scripts/run-voice-routing-tests.sh` covers them with the compact-panel chords and write mode.
5. Not done: the coordinators are still extensions of one class, not separate types with their own state.
   The transcript parsers depend on the folder-shortcut memory in `CompanionManager+Onboarding.swift`, so turning them into a standalone type needs that dependency injected first.

### Phase 6: Open-source readiness

1. Remove personal and original-author paths, bundle IDs, and queue labels.
2. Rewrite the README and setup guide for someone who has never seen the project, with a one-command setup script.
3. Add CI that runs the source checks on every push.
4. Done when: a clean Mac can follow the README to a working build.

### Phase 7: Final name

1. Choose a unique name and check it against existing products.
2. Rename the display name, bundle ID, and repository; GitHub keeps redirects from the old repository URL.

## Not changing

- The Command + Option shortcut and the OpenSuperWhisper integration.
- The pointer and bubble behavior, the response format, and the three-second pointing hold.
- Tasks, History, and Connect behavior.
- No terminal `xcodebuild`; native builds stay in Xcode.
