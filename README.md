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
- **Remembers your speed** across launches via `UserDefaults`.
- **Pause / Resume anywhere** with a system-wide `⌃⌥P` hotkey (Carbon hotkey, no
  Accessibility permission needed).

## How it picks what to read

In priority order:

1. A command-line argument: `speak-hud "hello world"`
2. Text piped on stdin: `echo "hello" | speak-hud` — this is how the Claude Code hook feeds it.
3. **The clipboard** — when launched on its own (double-click / Spotlight / a hotkey),
   it reads whatever text you've copied.

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

- `speak-hud.swift` — the whole app.
- `make-icon.swift` — renders the app icon.
- `build.sh` — compile, bundle, sign, install.
