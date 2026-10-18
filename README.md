# OpenClicky

**A screen-aware AI companion for your Mac.**
Ask about what you are working on, get an answer beside an AI pointer, and keep using your app.
Use it for navigation, troubleshooting, learning software, understanding unfamiliar interfaces, and ongoing computer work.

This standalone project builds on [Jason Kneen's MIT-licensed OpenClicky](https://github.com/jasonkneen/openclicky) and adds a compact, no-notch workflow with OpenSuperWhisper local dictation and ChatGPT-backed Codex sessions.
It is independent of the commercial Clicky product and of OpenAI.

## What this project adds

- **Command + Option** opens a focused input and starts OpenSuperWhisper.
- **Control + Command** asks without a screenshot, for faster text-only answers.
- **Fn + Command** writes text for the field you are in (an email reply, a form, a chat message) from the screenshot and your request, then pastes it there.
- The model decides when a request needs a background agent; you do not have to ask for one.
- The pointer bubble renders Markdown: emphasis, code, headings, lists, quotes, and code blocks.
- Multiline prompts wrap and grow; longer drafts scroll.
- New task, Tasks, and Remove task controls live in the compact panel; independent screen conversations persist across restarts.
- Connect links a cursor task to a live shared-server Codex terminal conversation, preserving its thread, settings, and history.
  See [shared-session setup and limits](docs/SHARED-SESSIONS.md).
- Connect can also continue a saved Claude Code session in place with `--resume`, and Claude response models run through your signed-in `claude` CLI.
  See [Claude Code setup and limits](docs/CLAUDE-CODE.md).
- A task's menu bar icon opens its conversation history in the same panel.
- Follow-ups stay with the selected session; separate tasks have separate transcripts.
- Answers appear beside the moving AI pointer, with optional screen highlights.
- **Escape or ×** dismisses answers and highlights without deleting history.
- No persistent fake-notch pill or side cursor dock.
- Answers appear in the pointer bubble rather than being spoken, and idle observation is off.
- Answers can run on Claude Code, Codex, Apple On-Device, or any command-line tool you configure; see [AI providers](docs/PROVIDERS.md).

The interface runs locally; AI inference on the default route runs remotely through your ChatGPT-backed Codex account.
No local LLM is required.
The code is free under the MIT license, but provider access, subscription limits still apply.

## Use it with a Codex conversation

Read the [short session handoff guide](docs/SESSION-HANDOFF.md).
It explains what context is shared, what is not, and how to transfer a brief in both directions today.

## Planned work

[Bidirectional session connection](docs/ROADMAP.md): connect an active Codex session with its Cursor Task Manager conversation, preserving context and progress in both directions.
Terminal attachment through the shared server is implemented; attachment to desktop chats on a separate server is still pending.

## Get started

This is a **source distribution**, not a notarized one-click installer.
The current project targets **macOS 26 or later** and was built with **Xcode 27** on Apple Silicon.
The runtime preparation script also supports Intel macOS archives; that hardware has not been validated for this project.

```sh
git clone https://github.com/OuterCFO/openclicky.git
cd openclicky
python3 scripts/prepare-codex-runtime.py
cp Config/Local.xcconfig.example Config/Local.xcconfig
open cursor-buddy.xcodeproj
```

1. Put your own Apple development team ID in `Config/Local.xcconfig`.
2. In Xcode, choose the `cursor-buddy` scheme and **My Mac**, then build.
3. Copy the signed `OpenClicky.app` build product to `/Applications` and launch that copy.
4. Sign in to Codex with your own ChatGPT account, or let OpenClicky's sign-in flow complete.
5. Grant Screen Recording and Accessibility to the installed OpenClicky app.
6. Install [OpenSuperWhisper](https://github.com/Starmel/OpenSuperWhisper), set its recording shortcut, and turn off Hold to record.

See [the complete setup guide](docs/SETUP.md), including sign-in, permissions, signing, and a first-use checklist.
You can type instead of using local dictation.

## Everyday use

| Action | Result |
| --- | --- |
| Press and release Command + Option | Open input and start local dictation |
| Press and release Control + Command | Same, but ask without sending a screenshot |
| Press and release Fn + Command | Write text and paste it into the field that was focused |
| Return or Send | Submit and close the input |
| Shift + Return | Insert a newline |
| History or a task menu bar icon | Review that conversation in the compact panel |
| Escape or × | Close the input, or dismiss the current answer and highlights |
| Tools → New Agent Task | Start a separate background task on the agent model (Codex or Claude Code) |

Try: “Explain this page and point at the settings button.”
Work that needs files, commands, or several steps starts a background agent automatically; the bubble says when it does.

## How it works

Your prompt + requested screen snapshots + the current session's recent exchanges + OpenClicky's local instructions/memory are sent to the selected backend.
OpenClicky renders the returned answer and pointing/highlight instructions on your desktop.

**Sharing your ChatGPT login does not import your other ChatGPT or Codex chats.**
OpenClicky has its own context and sessions.
Its account, provider, context, and execution boundaries are explained in [the architecture guide](docs/ARCHITECTURE.md).
An [interactive visual explainer](docs/interactive/OpenClicky-explained.html) is included; download it and open it locally.
That explainer describes the inspected development setup, not every future user's configuration.

The app includes OpenAI/Codex, Claude, Apple, and other upstream adapters.
This project's verified setup uses ChatGPT-backed Codex.
Other providers need their own access and are not covered by a ChatGPT subscription.
Screen guidance requires a backend capable of understanding the supplied images.

## Privacy and authority

Screen content and prompts are sent to the selected model service.
OpenSuperWhisper handles dictation locally and independently of the connected LLM.
Local conversation, memory, logs, and screenshot files can contain private information.
Explicit agent tasks can have broader tool access than the screen-answer path.
Read [SECURITY.md](SECURITY.md) before enabling optional automation or exposing the local control bridge.
No personal credentials, history, screen captures, or development runtime binaries belong in this repository.

## Development and project structure

| Location | Purpose |
| --- | --- |
| `cursor-buddy/` | Native macOS application |
| `Packages/` | Local Swift modules |
| `cursor-buddyTests/` | App regression tests |
| `AppResources/OpenClicky/` | Bundled instructions, skills, and upstream resources |
| `scripts/prepare-codex-runtime.py` | Download and verify the pinned official Codex runtime |
| `scripts/run-source-checks.sh` | Non-invasive source and regression checks |
| `Config/` | Shared configuration and ignored local signing overrides |
| `docs/` | Setup, architecture, troubleshooting, and project evidence |

```sh
scripts/run-source-checks.sh
```

Build and run the native application in Xcode.
See [CONTRIBUTING.md](CONTRIBUTING.md) for checks and review requirements.
The repository retains the legacy `cursor-buddy` target/folder names for compatibility.

## Status and attribution

The app has compiled and run in the maintainer's setup.
The newest adaptive prompt/history UI still requires live user acceptance testing; successful compilation is not a visual sign-off.
Provider alternatives, Intel hardware, and a fresh independent user's full setup have not yet been certified.
Known limitations and test steps are recorded in [docs/VERIFICATION.md](docs/VERIFICATION.md).

Original OpenClicky is by **Jason Kneen**, under the [MIT license](LICENSE).
This standalone project is maintained by **OuterCFO**.
Third-party components retain their own licenses; see [NOTICE.md](NOTICE.md).
