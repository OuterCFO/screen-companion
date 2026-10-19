# Setup

## Requirements

- macOS 26 or later, as specified by the current Xcode project.
- Xcode 27 is the version used for verification, with its developer tools installed.
- Python 3, Git, and Internet access for setup.
- Your own ChatGPT account with usable Codex access, for the default backend.
- An Apple development signing team available in Xcode.
- OpenSuperWhisper installed, with a key-combination recording shortcut and Hold to record disabled.

Apple Silicon is the verified hardware path.
Intel runtime download support exists but has not been validated end to end.
The source repository is not a notarized installer.

## Quick setup

From the repository root, run `scripts/setup.sh`.
It does the steps below for you: checks requirements, writes `Config/Local.xcconfig`, and prepares the Codex runtime.
Options: `--team TEAM_ID`, `--bundle-prefix com.yourname`, `--no-codex` (Claude-only setups), `--no-open`.
The rest of this guide explains each step.

## Prepare the runtime

From the repository root:

```sh
python3 scripts/prepare-codex-runtime.py
```

The script downloads Codex 0.160.0 from the official `@openai/codex` npm package.
It checks a pinned SHA-512 digest, then extracts only `codex` and `codex-code-mode-host`.
Both binaries are required; omitting the tool host can break screenshot inspection.
The generated `AppResources/OpenClicky/CodexRuntime/` directory is ignored by Git.
No authentication files are read or copied by this script.

Run the prepared client to sign in if needed:

```sh
AppResources/OpenClicky/CodexRuntime/bin/codex login
AppResources/OpenClicky/CodexRuntime/bin/codex login status
```

Complete the browser sign-in yourself.
OpenClicky can reuse the default local Codex login at `~/.codex/auth.json` through a symbolic link in its own application-support directory.
If no usable login is available, its Codex authentication flow can request sign-in.
Never commit or share that authentication file.

## Configure signing and build

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig
open cursor-buddy.xcodeproj
```

Set `OPENCLICKY_DEVELOPMENT_TEAM` to your development team identifier and `OPENCLICKY_BUNDLE_ID_PREFIX` to a reverse-DNS prefix you own, such as `com.yourname`.
The app's bundle ID becomes `<prefix>.openclicky`.
That file is ignored by Git; shared project settings contain no personal signing team or bundle ID.
Choose the `cursor-buddy` scheme, **My Mac**, and automatic signing in Xcode.
Keep the prefix stable: macOS ties Screen Recording and Accessibility permissions to the bundle ID, so changing it means granting them again.

Use Xcode's Product → Build.
Locate the built `OpenClicky.app` in Products and copy it to `/Applications`.
Quit an existing copy before replacing it.
Use that installed copy for permission and shortcut testing.
Do not alternate between differently signed temporary copies; macOS ties permissions to app identity.

## Permissions

Enable **OpenClicky** in System Settings → Privacy & Security → Screen & System Audio Recording and Accessibility.
Restart the same installed app if macOS requests it.
OpenSuperWhisper requires its own microphone and Accessibility permissions.
OpenClicky's compact text/external dictation path checks Screen Recording and Accessibility; direct native voice features can require additional microphone permission.
Enable only the features you intend to use.

## First-use check

1. Launch the installed app and confirm one OpenClicky pointer appears in the menu bar, without a fake notch or side dock.
2. Press and release Command + Option without another key.
3. Dictate several sentences, or type if local dictation is unavailable.
4. Confirm the editor wraps and grows, and a long prompt can be scrolled before submission.
5. Submit a harmless public-page question and confirm input closes and the reply appears beside the AI pointer.
6. Open Tasks in the compact panel, or right-click the menu bar icon, and review the saved exchanges in the same panel.
7. Send a follow-up and check it continues that session.
8. Press Escape to dismiss the answer and highlights.

## Configuration

OpenClicky's Settings control its own response and agent models.
Changing the selected model in the Codex desktop app does not change OpenClicky's preferences.
New installs default to the Codex model `gpt-6-luna` with medium reasoning effort, muted playback, and no idle observation.
Existing local preferences are preserved.

The default ChatGPT-backed route requires no OpenAI API key.
Do not configure provider keys unless you intend to use their separately billed routes.
There is no shared Kun curriculum or personal context bundled with this repository.

## External local dictation

Command + Option focuses the compact input and triggers the recording shortcut configured in OpenSuperWhisper.
Turn off Hold to record in OpenSuperWhisper and use a key combination such as Control + Option + R.
Press Command + Option again, or use the OpenSuperWhisper shortcut, to stop recording and paste its transcript.
Then press Return to submit to the selected cursor conversation.
The configured shortcut is read from OpenSuperWhisper preferences; no Wispr URL or cloud account is used.
If OpenSuperWhisper is unavailable or misconfigured, OpenClicky reports the error rather than launching a paid alternative.
