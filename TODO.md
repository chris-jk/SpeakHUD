# TODO — SpeakHUD

Running tab. Current state at top, then next up, waiting-on, recently shipped. Prune every session.

## Where things stand (2026-10-01)
- main (pushed 2026-10-01) holds click-to-terminal, clickable text, code blocks, the desktop-switch fix and the question reader; the installed build matches it. LaunchAgent running; Claude Code hook `installed`.
- Tests: `./tests/run.sh`, 417 checks + 13 Python tests for the question hook, all passing. No CI; run them before committing.
- Speech rules live in `Playback` (fake voice in tests); AVSpeech sits behind `SpeechVoice`.
- Mic hold: speech pauses while any other process records (macOS 14+), resumes 0.6s after release. Menu toggle **Pause While Recording** (shared prefs, on by default) turns it off.
- Spool contract (hook ↔ agent) pinned by a test that runs the real Python `enqueue()`; items carry `v: 1`, other versions are dropped with a logged reason.
- Click-to-terminal: the hook writes `origin` (TERM_PROGRAM, iTerm2 session UUID, tty, host app pid) into each spool item; clicking the HUD's source pill runs an AppleScript that activates the terminal *then* selects that iTerm2 pane / Terminal.app tab (activating after selecting stays on the current desktop whenever the terminal has a window there), else activates the app. Pill clicks are caught in `HUDPanel.sendEvent` because the pill sits under the transparent title bar. Needs the `apple-events` entitlement (build.sh) and the Automation grant for iTerm2 (already given).
- Clickable text: the hook marks inline-code commands and paths (plus bare existing `/…`, `~/…` paths) as `links` + `cwd` in the spool item; the HUD makes them links. Folder → shown selected in its parent; file → default app (Finder if that app would run it); gone → nearest folder; command → new iTerm2 window in cwd, typed with `newline no`, never run. Clicked live: reveal and iTerm load both logged OK.
- Code blocks: the hook turns each fenced block into an anchor paragraph; shell blocks with commands go in the spool as `blocks` and `Transcript` puts them back in the HUD (never spoken), mapping the voice's word ranges past them. Unit-tested; not yet seen on screen (live test turn was stopped).
- Questions: `hook/read-question.py`, a PreToolUse hook on AskUserQuestion (plus `--answered` on PostToolUse), installed by hand in `~/.claude/hooks` + settings.json. Once the spool is empty it chimes (Glass), queues the question under `<session>:question`, waits for the agent to let it go, pauses 2s, queues the options. Stops on an answer, a newer question, or Stop (read from the agent log). Claude asks one question per call (global CLAUDE.md, grilling-extras). Heard live 10-01.
- Agent liveness is a heartbeat: the agent touches `agent.heartbeat` in the spool every 3s; the hook queues only if it's <10s old (waiting up to 4s for a fresh one, e.g. after wake), else speaks directly (HUD binary, then `say -f -`). tests/HookTests.swift runs the real hook against a stub `say`.

## ⏭️ Next session — start here
- (nothing open)

## 🚨 Blocking
- (none)

## 🙋 Owner only
- (none)

## 🟡 Next up
- [ ] Move the question pause into `Playback` (one spool item with the options and a pause): another session's turn can land in the 2s gap today, and Stop/skip would act on the whole question natively (review 10-01)
- [ ] Have `ClaudeHook` (--setup-claude) install read-question.py and both its hook entries, and bundle it in build.sh, so it stops being a hand install
- [ ] Click the pill on a turn from another desktop once, to see the fix live (reproduced and fixed by hand with osascript; the pill click itself not yet). Review 10-01: if it still stays put, the after-"ok" `app.activate` in `Reveal.go` is the suspect; activate through NSRunningApplication *before* the script instead. Also: the script now brings the terminal forward even when the pane is gone
- [ ] Glance at the first real turn with a ```bash block in the HUD (layout of the indented code)
- [ ] Terminal.app path is untested live (no Terminal windows open); iTerm2 verified

## 🧊 Later
- (none)

## ⏳ Waiting on others
- (none)

## ✅ Recently shipped (trim as it ages)
- 2026-10-01 — AskUserQuestion read aloud: chime, question, 2s pause, options; review fixes (own spool key, stops on answer/Stop/newer question, gives up on a long wait). A command link alone on a line no longer leaves a bare "-" or "[ ]"
- 2026-10-01 — Source pill switches desktops again: activate before selecting the pane (it had stayed put when iTerm2 had a window on the current desktop). Hook's `typecmd:` link skip folded back into the repo
- 2026-10-01 — Slash commands like `/chrome` in inline code no longer link to / (seen in the log)
- 2026-10-01 — Shell code blocks show in the HUD (silent) with each command line clickable
- 2026-10-01 — Paths, commands and URLs in the HUD text are clickable: folder shown in its parent, file opens, command typed into a new iTerm2 window (never run)
- 2026-10-01 — Click the source pill to jump to the terminal that's talking (iTerm2 pane / Terminal.app tab, across desktops); hotkey reads go back to their app
- 2026-09-24 — Deleted merged branches; checked the ⚠ config.json menu line live
- 2026-09-24 — Review fixes: HUD that dies at launch falls back to `say`; heartbeat recreates a removed spool dir; hook waits up to 4s for a fresh beat; build.sh refreshes the hook after the new agent is up; ⚠ line names the live hotkey
- 2026-09-24 — Settings fixes: `--set-hotkey` reports save + restart truthfully (not-running agent is a non-error); invalid config.json is logged and flagged in the menu, file left alone; Pause While Recording toggle
- 2026-09-24 — Hook hardening: heartbeat replaces `pgrep` for agent liveness; direct fallback pipes text to `say -f -` and falls back past a broken HUD binary without raising; spool schema version `v`
- 2026-09-24 — Architecture batch: Playback module, spool contract test, one hook install path, test harness; fixed 5 defects (mic hold dropping items, Speed un-pausing, setup deleting its own binary, stale HUD after Stop, held items not shown)
- 2026-09-24 — Hold speech while anything else is recording (Claude Code hold-space dictation)
- 2026-09-24 — HUD can be dismissed and brought back; no zoom
