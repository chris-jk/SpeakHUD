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

## Claude Code integration

A `Stop` hook runs a small script that grabs the latest assistant response, strips code
blocks/markdown, and pipes it to `speak-hud`. See `hook/` for the reference script.

## Files

- `speak-hud.swift` — the whole app: reader HUD, `--agent` (hotkey listener), and
  `--set-hotkey`.
- `make-icon.swift` — renders the app icon.
- `build.sh` — compile, bundle, sign, install the app + the LaunchAgent.
