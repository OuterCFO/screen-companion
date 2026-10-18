# Use Claude Code with OpenClicky

OpenClicky drives your installed `claude` CLI directly over its stream-json protocol.
No Node.js runtime, npm package, or Anthropic API key is required.
Turns use the CLI's own sign-in, so they count against your Claude plan rather than per-token API billing.

## Set up

1. Install Claude Code and sign in once from Terminal: run `claude`, then `/login`.
2. Check the sign-in with `claude auth status`; it should report `"loggedIn": true`.
3. In OpenClicky settings, choose a Claude response model: Fable 5.1, Sonnet 5.5, or Opus 5.5.

OpenClicky finds `claude` in `~/.local/bin`, `~/.claude/local`, Homebrew, `/usr/local/bin`, and Nix profiles, then the inherited PATH.
Set `OPENCLICKY_CLAUDE_EXECUTABLE` to override that search.

## Standalone answers

Each screen question runs in its own `claude -p` process with the selected model and a fixed OpenClicky system prompt.
The process ignores your Claude Code settings, hooks, MCP servers, and project instruction files, and saves no transcript.
Only WebSearch and WebFetch are available, so it can answer current-information questions inline.
OpenClicky starts the next process ahead of time, so a question does not wait for CLI startup.
Without a custom provider, OpenClicky removes `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, and `ANTHROPIC_BASE_URL` from the child environment so the CLI uses your plan sign-in.
A custom `AnthropicBaseURL` configured in OpenClicky is still passed through with its key.
If the CLI fails and an Anthropic API key is configured, the direct API fallback applies, as before.

Earlier builds saved `fable-5`, `sonnet-5`, and `opus-5`, which neither the CLI nor the API resolves.
Those saved choices now migrate to the full model IDs automatically.

## Connect to a Claude Code session

1. Press Command + Option, then click Connect.
2. Choose an entry labeled `Claude Code: <title> · <folder> · <last activity>`.
3. Ask questions as usual; the cursor task is labeled `Claude Code: <title>`.
4. Later, run `claude --resume <session>` in that folder, or pick the session in `/resume`, to see the cursor's questions and answers in its history.

Each question runs `claude -p --resume <session-id>` in the session's own folder.
The turn is appended to the same session; it is not forked or copied.
The session keeps its model, settings, CLAUDE.md, and MCP servers.
OpenClicky adds its pointing and summary format for that turn only with `--append-system-prompt`; the instruction is not saved in the transcript.
Cursor turns may use Read, Grep, Glob, WebSearch, and WebFetch; edits and shell commands are denied.
History reloads the transcript from the session file.

## Limits

A Claude Code window that already has the session open keeps its own in-memory context.
It does not show cursor turns until you resume the session again, and its next turn continues from its own last message.
If that window is running a turn, OpenClicky refuses the question and asks you to retry when it finishes.
Closing the bubble does not stop a linked turn; it finishes and is saved in the session.
Standalone answers stop when dismissed.
The list shows the 30 most recently active sessions in `~/.claude/projects`, or under `CLAUDE_CONFIG_DIR` when set.
