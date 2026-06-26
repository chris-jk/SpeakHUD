# SpeakHUD

A tiny macOS app that reads text aloud in a floating HUD with **Replay**, **Pause**,
**Speed**, and **Stop** controls. Built with `AVSpeechSynthesizer` — no dependencies,
no menu-bar clutter (it's an agent app), single Swift file.

It started life as a Claude Code "read my last response out loud" hook and grew into
a standalone app.

![icon](AppIcon.icns)

## Features

- **Floating HUD** with karaoke-style word highlighting that follows along.
- **Speed control** — cycle `0.75× → 2×`. Changing speed mid-read resumes from the
  current word at the new rate (AVSpeech can't change rate live, so it restarts cleanly
  on a fresh synthesizer — reusing one after `stopSpeaking(.immediate)` silently drops
  audio).
- **Remembers your speed** across launches (shared `UserDefaults` suite, so the app,
  the hook, and the hotkey all agree).
- **Pause / Resume anywhere** with a system-wide `⌃⌥P` hotkey (Carbon hotkey, no
  Accessibility permission needed).
- **Global hotkey to read the clipboard** from anywhere (default `⌃⌥S`), served by a
  tiny background agent. The combo is **user-configurable**.
- **Menu-bar settings** (a small speaker icon) to read the clipboard, pick the hotkey,
  and **one-click enable "read my Claude Code responses aloud"** — no manual JSON editing.

## How it picks what to read

In priority order:

1. A command-line argument: `speak-hud "hello world"`
2. Text piped on stdin: `echo "hello" | speak-hud` — this is how the Claude Code hook feeds it.
3. **The clipboard** — when launched on its own (double-click / Spotlight / a hotkey),
   it reads whatever text you've copied.

## Global hotkey (read clipboard from anywhere)

`build.sh` installs a background **LaunchAgent** (`com.chris.speakhud.agent`) that
registers a system-wide hotkey. Press it and SpeakHUD reads whatever text is on your
clipboard — no need to open the app first. Default combo: **`⌃⌥S`**.

Set your own combo (one or more of `cmd`/`ctrl`/`opt`/`shift` plus a key):

```sh
/Applications/SpeakHUD.app/Contents/MacOS/speak-hud --set-hotkey "ctrl+opt+r"
```

This writes `~/.config/speakhud/config.json` and restarts the agent. Invalid combos
(no modifier, unknown key) are rejected and leave the current setting untouched.

Manage the agent directly if needed:

```sh
launchctl kickstart -k gui/$(id -u)/com.chris.speakhud.agent   # restart
launchctl bootout   gui/$(id -u)/com.chris.speakhud.agent       # stop/disable
```

## Build & install

```sh
./build.sh
```

Installs `SpeakHUD.app` to `/Applications` (falls back to `~/Applications`) and refreshes
`~/.claude/bin/speak-hud` for the Claude Code hook. Stock-macOS tools only (`swiftc`,
`codesign`, `sips`, `iconutil`).

## Optional: voice & rate via environment

- `SPEAK_VOICE` — a voice name or identifier (e.g. `Samantha`).
- `SPEAK_RATE` — an initial AVSpeech rate `0.0–1.0` (snaps to the nearest speed step;
  overrides the saved preference for that launch).

## Menu bar & settings

The background agent shows a small **speaker icon** in the menu bar:

- **Read Clipboard Aloud**
- **Read Claude Code Responses Aloud** — a checkbox that installs/removes the Claude
  Code `Stop` hook for you (see below).
- **Global Hotkey** — pick a preset or open the config file.
- **SpeakHUD on GitHub** / **Quit**.

## Claude Code integration

SpeakHUD can read each Claude Code response aloud the moment a turn finishes. Enable it
the easy way from the menu bar (**Read Claude Code Responses Aloud**), or from the CLI:

```sh
/Applications/SpeakHUD.app/Contents/MacOS/speak-hud --setup-claude    # install
/Applications/SpeakHUD.app/Contents/MacOS/speak-hud --remove-claude   # uninstall
/Applications/SpeakHUD.app/Contents/MacOS/speak-hud --claude-status   # check
```

Setup is a safe, idempotent merge into `~/.claude/settings.json`: it copies
`read-summary.py` and the reader binary into `~/.claude`, then adds a `Stop` hook that
grabs the latest assistant response, strips code blocks/markdown, and pipes it to
`speak-hud`. Your other settings and hooks are preserved; removing it touches only the
SpeakHUD entry. See `hook/` for the reference script.

## Files

- `speak-hud.swift` — the whole app: reader HUD, `--agent` (hotkey listener), and
  `--set-hotkey`.
- `make-icon.swift` — renders the app icon.
- `build.sh` — compile, bundle, sign, install the app + the LaunchAgent.
