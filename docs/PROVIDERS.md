# AI providers

Every text answer goes through one `AnswerProviderRegistry`.
Each model family has an ordered chain of providers; the first available provider answers, and a failure falls through to the next one.
Cancellation never falls through, so an interrupted answer cannot start a paid fallback.

| Family | Chain, in order | Billing |
| --- | --- | --- |
| Claude models | Claude Code CLI, then Anthropic API key | Claude plan, then per token |
| OpenAI text models | Codex app-server, then OpenAI API key | ChatGPT plan, then per token |
| Codex models | Codex app-server | ChatGPT plan |
| Apple On-Device | Apple Foundation Models | Free, on this Mac |
| Command-line tools | Your configured command | Set by the tool |

Realtime speech models and the Deepgram voice agent are speech-to-speech paths outside the registry.

Background agent tasks follow the agent model: GPT models run in the bundled Codex runtime, and Claude models run in the Claude Code CLI.
See [Claude Code](CLAUDE-CODE.md#background-agent-tasks).

## Money rule

Registration rejects a chain where a per-token provider comes before a free or plan provider.
This keeps plan sign-ins first and API keys as fallbacks only.

## Add a command-line tool without code

Any tool that takes a prompt and prints an answer can be added.

1. Create `~/Library/Application Support/OpenClicky/command-line-providers.json`.
2. Add one entry per tool, for example:

```json
[
  {
    "id": "gemini",
    "label": "Gemini CLI",
    "executable": "gemini",
    "arguments": ["-p", "{prompt}"]
  },
  {
    "id": "llava",
    "label": "Ollama LLaVA",
    "executable": "ollama",
    "arguments": ["run", "llava", "{images}"],
    "timeoutSeconds": 180
  }
]
```

3. Quit and reopen the app, then choose the tool in the response model list.

`{prompt}` is replaced by the full prompt; without it, the prompt is sent on standard input.
`{images}` expands to one file path per screenshot; without it, screenshots are not sent and the tool is told so.
`executable` is an absolute path or a name found in `~/.local/bin`, Homebrew, `/usr/local/bin`, Nix profiles, or PATH.
The tool runs in a temporary folder that is deleted after each answer, and standard output is shown as it streams.
The default timeout is 120 seconds.

## Add a provider in Swift

1. Write a class that conforms to `AnswerProvider` in `AnswerProvider.swift`: an `id`, its `billing`, `isAvailable`, and `answer(_:onText:)`.
   `onText` receives the accumulated answer so far.
2. Register it in `AnswerProviderRegistry.standard` in `AnswerProviders.swift`, in money-rule order.
3. Add its models to `OpenClickyModelCatalog`.
4. Add a contract test in `scripts/run-answer-provider-tests.sh`.

## Add a Connect source

Connect continues a session that lives in another tool.
Conform to `SessionLink` in `SessionLink.swift` (list, transcript, submit), give its thread IDs a unique prefix, and add it to `CompanionManager.sessionLinks`.
Codex and Claude Code are the two shipped sources; see [Claude Code](CLAUDE-CODE.md) and [shared sessions](SHARED-SESSIONS.md).
