# SpeakHUD

A tiny macOS app that reads text aloud in a floating HUD with **Replay**, **Pause**,
**Speed**, **Skip**, and **Stop** controls. Built with `AVSpeechSynthesizer` — no
dependencies, no Dock icon (it's an agent app), and the entire runtime in a single Swift
file. (`make-icon.swift` is a build-time icon generator; it never ships in the app.)

It started life as a Claude Code "read my last response out loud" hook and grew into
a standalone app.

![icon](AppIcon.icns)

## Features

- **Floating HUD** with karaoke-style word highlighting that follows along.
- **One speech queue.** Run Claude in four terminals and they take turns instead of
  cutting each other off — you only have one pair of ears.
- **Speed control** — cycle `0.75× → 2×`. Changing speed mid-read resumes from the
  current word at the new rate (AVSpeech can't change rate live, so it restarts cleanly
  on a fresh synthesizer — reusing one after `stopSpeaking(.immediate)` silently drops
  audio).
- **Remembers your speed** across launches (shared `UserDefaults` suite, so the app,
  the hook, and the hotkey all agree).
- **Pause / Resume anywhere** with a system-wide `⌃⌥P` hotkey.
- **Shuts up while you talk.** When anything else opens the mic — Claude Code's
  hold-space dictation, a call, system dictation — speech pauses, and picks back up
  a moment after the mic is released (macOS 14+).
- **Global hotkey to read your highlighted text** from any app (default `⌃⌥S`), with
  play / pause / speed controls in the HUD. The combo is **user-configurable**.
- **Menu-bar settings** (a small speaker icon) to read the clipboard, pick the hotkey,
  and **one-click enable "read my Claude Code responses aloud"** — no manual JSON editing.

## The queue

Only one thing speaks at a time. Anything that arrives while the HUD is busy waits
its turn, and the HUD shows what's behind it:

```
 ●  grow_guide_app                       ▸ 3 queued
🔊 Speaking…  1.25×
┌──────────────────────────────────────────┐
│ Yes, I understand — and I found the      │
│ exact line causing it…                   │
└──────────────────────────────────────────┘
 next: SpeakHUD, StrainGuide, cloudflare-dns

 ↻ Replay   ❚❚ Pause   ⏩ 1×   ⏭ Skip   ■ Stop
```

- **Whoever is speaking is named in a colored pill**, and each project keeps the same
  color every time (a stable hash of the name, not Swift's per-process `hashValue`),
  so four terminals become four colors you recognize rather than four names you read.
  The `next:` line colors each waiting project the same way.
- **Claude Code turns queue.** Each finished turn is written to a spool directory
  (`~/.local/state/speakhud/queue/`) and drained one at a time by the background agent.
- **Newest per session wins.** If one terminal finishes two turns while you're still
  listening to something else, only the newer one is kept — you want the latest answer,
  not a stale one. Sessions are tracked separately, so two terminals in the same repo
  are both heard.
- **Hotkey reads jump the queue.** You highlighted that text and asked for it *now*,
  so it preempts whatever was speaking.
- **Skip** moves to the next item. **Stop** — and closing the window — discards
  everything that was waiting.
- **The queue survives a restart.** A taken item stays on disk (renamed `.taken`) until
  it has actually been spoken, so killing or rebuilding the agent mid-queue replays what
  was pending instead of swallowing it.
- Items that have waited more than 10 minutes are dropped unspoken, so an agent that
  was stopped for a while doesn't come back and read you the whole morning. Every
  dropped item (too old, blank, malformed, or written by a newer hook) is logged with its reason. The file
  format is described in [hook/README.md](hook/README.md).

## How it picks what to read

In priority order:

1. A command-line argument: `speak-hud "hello world"`
2. Text piped on stdin: `echo "hello" | speak-hud`
3. **Your highlighted text** in the frontmost app (global hotkey).
4. **The clipboard** — the fallback when nothing is selected, and when launched on its
   own (double-click / Spotlight).

## Global hotkey (read your selection from anywhere)

`build.sh` installs a background **LaunchAgent** (`com.chris.speakhud.agent`) that
registers a system-wide hotkey. Highlight text in any app, press it, and SpeakHUD reads
the selection in a HUD you can pause, stop, and re-speed. Default combo: **`⌃⌥S`**.

Set your own combo (one or more of `cmd`/`ctrl`/`opt`/`shift` plus a key):

```sh
/Applications/SpeakHUD.app/Contents/MacOS/speak-hud --set-hotkey "ctrl+opt+r"
```

This writes `~/.config/speakhud/config.json` and restarts the agent. Invalid combos
(no modifier, unknown key) are rejected and leave the current setting untouched.

> **If you pick `⌘⌥S`,** know that macOS's own **Accessibility → Spoken Content → Speak
> selection** claims that combo by default. Both will then read your selection at once,
> and the system one has no HUD and no speed control. Turn it off first:
>
> ```sh
> defaults write com.apple.speech.synthesis.general.prefs SpokenUIUseSpeakingHotKeyFlag -bool false
> ```
>
> If a stray voice persists, untick it once in System Settings — the pref is read by a
> system service that may not notice a `defaults write` until then.

Manage the agent directly if needed:

```sh
launchctl kickstart -k gui/$(id -u)/com.chris.speakhud.agent   # restart
launchctl bootout   gui/$(id -u)/com.chris.speakhud.agent       # stop/unload (until next login)
tail -f ~/Library/Logs/speakhud-agent.log                       # what it's doing
```

The log records whether Accessibility was granted, which hotkey it bound, and each
item it picks up off the queue. It's the only place to see the permission state, since
running `speak-hud` from a terminal reports *the terminal's* Accessibility grant rather
than SpeakHUD's.

### Accessibility permission

Reading *highlighted* text out of another app requires macOS **Accessibility** access —
there's no way around it. Grant it from the menu bar (**Grant Accessibility Access…**,
which only appears while the permission is missing).

Until you do, the hotkey falls back to reading the **clipboard**, so nothing breaks.

Two strategies are used, in order: the Accessibility API's selected-text attribute
(clean, doesn't touch your clipboard), and — for apps that don't implement it, like
Chrome and some terminals — a synthesized `⌘C` with your clipboard restored afterwards.

## Build & install

```sh
./build.sh
```

Installs `SpeakHUD.app` to `/Applications` (falls back to `~/Applications` when it isn't
writable). If the Claude Code hook is installed (even partly), it then runs the new
app's `--setup-claude` to refresh `~/.claude/read-summary.py` and `~/.claude/bin/speak-hud`,
so a rebuild never leaves a stale copy behind. Stock-macOS tools only (`swiftc`, `codesign`, `sips`, `iconutil`).

Tests: `./tests/run.sh`. It compiles `speak-hud.swift` with `-D TESTING` (the entry
point drops out) alongside `tests/*.swift` — no XCTest, so bare Command Line Tools are enough.

`build.sh` prints the path it installed to (`installed -> …`). If it fell back to
`~/Applications`, use that prefix in the `speak-hud` commands on this page — for example
`~/Applications/SpeakHUD.app/Contents/MacOS/speak-hud --claude-status`.

**Signing matters here.** macOS keys the Accessibility grant to the app's code signature,
and an ad-hoc signature gets a new hash on every build — so a rebuild would silently
revoke the permission. `build.sh` therefore signs with the first **Developer ID
Application** identity in your keychain, falling back to ad-hoc (with a warning) if you
don't have one. Override with `SPEAKHUD_SIGN_ID=<hash-or-name> ./build.sh`; a self-signed
certificate works fine, since all that matters is that it's stable.

## Optional: voice & rate via environment

- `SPEAK_VOICE` — a voice name or identifier (e.g. `Samantha`).
- `SPEAK_RATE` — an initial AVSpeech rate `0.0–1.0` (snaps to the nearest speed step;
  overrides the saved preference for that launch).

## Menu bar & settings

The background agent shows a small **speaker icon** in the menu bar:

- **Read Clipboard Aloud**
- **Read Claude Code Responses Aloud** — a checkbox that installs/removes the Claude
  Code `Stop` hook for you (see below). If the hook is registered but its script or
  binary is missing or out of date, it shows a dash and "— Repair"; clicking reinstalls.
- **Global Hotkey** — pick a preset or open the config file.
- **Grant Accessibility Access…** — shown only until the permission is granted.
- **SpeakHUD on GitHub** / **Quit**.

## Claude Code integration

SpeakHUD can read each Claude Code response aloud the moment a turn finishes. Enable it
the easy way from the menu bar (**Read Claude Code Responses Aloud**), or from the CLI:

```sh
/Applications/SpeakHUD.app/Contents/MacOS/speak-hud --setup-claude    # install or repair
/Applications/SpeakHUD.app/Contents/MacOS/speak-hud --remove-claude   # uninstall
/Applications/SpeakHUD.app/Contents/MacOS/speak-hud --claude-status   # check
```

Setup is a safe, idempotent merge into `~/.claude/settings.json`: it copies
`read-summary.py` and the reader binary into `~/.claude`, then adds a `Stop` hook that
grabs the latest assistant response, strips code blocks/markdown, and hands it to the
agent's queue. Your other settings and hooks are preserved; removing it deletes only the
SpeakHUD entry, keeping any other hooks in the same group. If `settings.json` isn't valid
JSON, setup and removal leave it untouched and say so. Each step that fails is named in
the output, and `--setup-claude` exits non-zero.

`--claude-status` prints one of `installed`, `stale: <what's wrong>` (the hook is
registered but the script or binary is missing or differs from this build — run
`--setup-claude` to repair), or `not installed` (with the reason if `settings.json` won't
parse). Run it from the app bundle: that's where the reference copy of `read-summary.py`
lives. See `hook/` for the reference script.

`build.sh` refreshes the hook through the app: `--setup-claude` when it's registered, and
otherwise `--refresh-claude-files`, which updates any existing script or binary copy in
`~/.claude` (say, for a hook registered in `settings.local.json`) without registering
anything. A symlinked copy is written through, not replaced.

**If the agent isn't running** — or the spool can't be written — the hook doesn't go
silent: it speaks the response directly, the way it did before the queue existed.
"Running" means the agent has touched its heartbeat file in the queue directory within
the last 10 seconds (it does so every 3), so a hung agent counts as not running. The
hook pipes the text to `~/.claude/bin/speak-hud` (a one-shot HUD). If that binary is
missing, won't start, or stops reading, it pipes the text to the system `say` command
instead. You lose the queue in that mode, so simultaneous turns can talk over each other.

## Files

- `speak-hud.swift` — the whole app: the queue-owning HUD, `--agent` (hotkey listener,
  spool watcher, menu bar), and `--set-hotkey`.
- `hook/read-summary.py` — the Claude Code `Stop` hook; enqueues a finished turn, or
  speaks it directly when the agent isn't running.
- `make-icon.swift` — build-time tool that renders `AppIcon.icns`; not part of the app.
- `build.sh` — compile, bundle, sign, install the app + the LaunchAgent.
