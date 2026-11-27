# Antigravity CLI

OpenClicky can answer through Google's Antigravity CLI (`agy`), using the Google account you sign in with.
This replaced Gemini CLI for personal Google accounts on 18 June 2026.

## Setup

1. Install the CLI: `curl -fsSL https://antigravity.google/cli/install.sh | bash`.
   It installs `agy` to `~/.local/bin/agy`.
2. Run `agy` once, sign in with your Google account in the browser, then quit.
3. Quit and reopen OpenClicky, then choose a Gemini 4 model marked "(Antigravity)" in Settings.

The models appear only when `agy` is found.
To use a copy somewhere else, set `OPENCLICKY_AGY_EXECUTABLE` to its path.

## How a turn runs

Each question is one `agy -p` run in a new temporary folder that holds the current screenshots.
The prompt asks the model to open each screenshot with its file tool, then answer in OpenClicky's `[POINT:...]` and `<cursor_reply>` format.
The reply streams into the bubble as it is written, and the folder is deleted afterwards.

Turns are stateless: recent history is sent in the prompt, as with standalone Claude Code turns.
OpenClicky's turns are stored by the CLI in `~/.gemini/antigravity-cli`, apart from the Antigravity app's conversations.
`GEMINI_API_KEY` and `GOOGLE_API_KEY` are removed from the CLI's environment, so answers always use the Google sign-in.

## Read-only

In print mode `agy` refuses every tool that needs approval, so the model can read files but cannot edit them or run commands.
OpenClicky never passes `--dangerously-skip-permissions`, and passes `--disable-slash-commands` so a question that starts with `/` is not run as a command.
The prompt also tells the model to only read.

## Project context folder

The model can read one project folder for context, such as your Antigravity workspace.
Set it with:

```bash
defaults write <your bundle ID> openClickyAntigravityContextFolder "/path/to/project"
```

Your bundle ID is `OPENCLICKY_BUNDLE_ID_PREFIX` plus `.openclicky`, from `Config/Local.xcconfig`.
The folder is added with `--add-dir`, and the prompt points the model at its `GEMINI.md` when that helps.
Put a short `GEMINI.md` there that says what you are working on and how you like answers.

## Limits

- A turn takes about 10 to 15 seconds on Gemini 4 Neon Low, slower on larger models.
- Screenshots go through the model's file tool, not as direct image input.
- Antigravity models answer questions only; pointing and background agent tasks stay on Claude or Codex.
- Each turn has a 120 second limit.

## Tests

`scripts/run-antigravity-cli-tests.sh` checks discovery, arguments, prompt layout, the environment, and stream parsing against output recorded from `agy` 1.5.18.
It runs as part of `scripts/run-source-checks.sh`.
