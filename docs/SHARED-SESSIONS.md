# Connect the cursor to an existing Codex terminal session

For Claude Code sessions, see [Use Claude Code with OpenClicky](CLAUDE-CODE.md).

This first version supports live sessions owned by the shared local Codex app-server.
Your desktop app may own its chats in a separate server; those chats are shown as unavailable and are not copied or resumed in another worker.
Desktop integration remains a separate step.

## Use it

1. Open Terminal and run `codex resume --remote unix://$HOME/.codex/app-server-control/app-server-control.sock` to explicitly use the same server as OpenClicky.
2. Select the terminal conversation you want the cursor to use and leave that terminal open.
3. Press Command + Option to open OpenClicky, then click Connect.
4. Select that live conversation and click Connect in the picker.
5. The cursor task is labeled `Codex: <conversation title>`.
   Submit questions through the existing input and local dictation workflow.
6. Open History to refresh the original Codex transcript in the same compact panel.
   The terminal contains the complete turn and tool history.

The cursor sends text and screenshot attachments to the same thread ID.
The existing thread owns its context, model, effort, working directory, tools, sandbox, and approvals.
OpenClicky's standalone GPT-6 Luna default does not override a connected thread's model.
Busy sessions wait for the current turn to finish before submitting cursor input.
A connection or submission failure is reported; OpenClicky does not fall back to a separate voice thread or API key.
After an uncertain submission, check the terminal before retrying to avoid duplicates.

## Disconnect and remove

New task starts a separate standalone cursor conversation.
Selecting another task detaches the previous cursor connection.
Remove task archives the local cursor link and its cached history; the original Codex session is kept.
Closing the input or dismissing the reply does not interrupt a connected Codex turn.
A successfully submitted turn continues in the terminal after the cursor stops displaying it.
Reopening a saved linked cursor task reconnects only if its original thread is still live in the shared server.

## Approvals and limits

Actual command and file approvals are displayed when the shared server requests them.
Additional permissions are granted only after the user chooses Allow once and only for that turn.
Questions from Codex are displayed with a text response field.
A tool implemented exclusively inside another client cannot automatically run inside OpenClicky; its call is explicitly failed with an explanation.
Unsupported elicitation requests are declined rather than guessed.
Do not assume every desktop-only plugin, screen-control tool, or connector is available in a terminal session.
The standalone screen-answer lane remains a separate read-only conversation until connected.

This source build requires the standard-library Python 3 available with the Xcode command-line tools.
The bridge talks only to the existing local Unix socket; it opens no network listener and copies no credentials.
Screenshot files are retained until turn completion.
If the cursor disconnects during a turn or a submission is uncertain, its temporary `openclicky-shared-*` screenshot directory can remain on disk.
That avoids deleting files before the original session consumes them; inspect these app-owned temporary directories before cleaning them up.

## User acceptance test

1. In the terminal, give the session a unique check phrase, then wait until it is idle.
2. Connect OpenClicky to that session and ask it to repeat the phrase.
3. Confirm that your cursor prompt and reply appear in that exact terminal conversation.
4. With a public page in front, ask it to identify and point at a visible heading.
5. Ask it to read a harmless file in the session's workspace and verify the actual tool event in Terminal.
6. Ask for an agent action only if that terminal session supports it; verify the launch event, not just a claim in its answer.
7. Switch back to Terminal, continue the topic, and verify it knows what happened through the cursor.
8. Remove the cursor link and confirm the original terminal conversation is still present.

No inference prompt or live action was injected into the user's session by the implementing agent.
Automated verification covers the transport handshake and framing, live-only selection policy, preserved turn settings, persistence, and source compilation.
The above live tests remain user-led.

## Reply formatting

The pointer reply preserves bold, italics, inline code, links, strikethrough, and paragraph breaks.
Explicit `==highlighted text==` uses a yellow background; Markdown emphasis inside a highlight is preserved.
The reply uses measured native text height and grows with the rendered text.
Long replies scroll within a bounded panel rather than being clipped.
The cursor bubble displays only concise replies; detailed responses are available in task History.
Connected sessions are asked to append a short `<cursor_reply>` summary while retaining their detailed answer.
Only a complete dedicated cursor_reply block outside code examples is accepted for linked sessions.
Quoted tag mentions, unfinished streamed blocks, and pointing metadata cannot become cursor text.
If no summary is supplied, a short History notice appears instead of exposing the full response.
The full response remains in the original session and task History.
Cursor display is hard-limited to 60 words and 600 characters.
Formatting is rendered locally and does not change the connected conversation or model.

## Cursor delivery and task identity

A connected Codex thread has one active local cursor task.
Reconnect reuses that task; legacy duplicate links are archived automatically while retaining their cached history.
Command + Option continues the selected task; only New task starts an independent conversation.
Each submitted cursor request restores the app-owned pointer and reply display immediately.
Linked requests capture screen context regardless of prompt phrasing.
The reply stays visible until manual dismissal or another question.
The pointer holds at a target for at least three seconds after arrival, then resumes following when you move your mouse.
The reply follows the AI pointer continuously, including during hover.
Display windows reassert visibility after a macOS Space switch.
A valid model-provided screenshot coordinate moves the pointer to that target.
Without a valid coordinate, the reply stays at a neutral nearby position and says No verified screen target.
Out-of-range or non-finite coordinates are rejected instead of being clamped to an unrelated screen edge.
These rules guarantee app presentation, not perfect visual target identification by a model.

Pointing directives are parsed independently of concise summaries.
A dedicated POINT line may precede or follow the cursor_reply block; quoted or fenced examples do not trigger movement.

## Mandatory response order

Every OpenClicky request supplies one shared output contract: a complete POINT directive on its own first line, then the full answer, then the concise summary as the last block.
The cursor_reply opening and closing tags each occupy a separate line above and below that summary.
Nothing follows the closing tag.
If a target cannot be verified, the first directive is POINT:none; coordinates must never be invented.
The app dispatches a valid point during streaming and avoids dispatching it again at final completion.
Presentation parsing tolerates misplaced inline tags without executing backtick or fenced examples; the canonical session text remains unchanged.
