# TODO — SpeakHUD

Running tab. Current state at top, then next up, waiting-on, recently shipped. Prune every session.

## Where things stand (2026-09-24)
- main pushed; installed build matches it (build.sh run 2026-09-24). LaunchAgent running; Claude Code hook `installed`.
- Tests: `./tests/run.sh`, 283 checks, all passing. No CI; run them before committing.
- Speech rules live in `Playback` (fake voice in tests); AVSpeech sits behind `SpeechVoice`.
- Mic hold: speech pauses while any other process records (macOS 14+), resumes 0.6s after release. Menu toggle **Pause While Recording** (shared prefs, on by default) turns it off.
- Spool contract (hook ↔ agent) pinned by a test that runs the real Python `enqueue()`; items carry `v: 1`, other versions are dropped with a logged reason.
- Agent liveness is a heartbeat: the agent touches `agent.heartbeat` in the spool every 3s; the hook queues only if it's <10s old (waiting up to 4s for a fresh one, e.g. after wake), else speaks directly (HUD binary, then `say -f -`). tests/HookTests.swift runs the real hook against a stub `say`.

## ⏭️ Next session — start here
- (nothing open)

## 🚨 Blocking
- (none)

## 🙋 Owner only
- (none)

## 🟡 Next up
- (none)

## 🧊 Later
- (none)

## ⏳ Waiting on others
- (none)

## ✅ Recently shipped (trim as it ages)
- 2026-09-24 — Deleted merged branches; checked the ⚠ config.json menu line live
- 2026-09-24 — Review fixes: HUD that dies at launch falls back to `say`; heartbeat recreates a removed spool dir; hook waits up to 4s for a fresh beat; build.sh refreshes the hook after the new agent is up; ⚠ line names the live hotkey
- 2026-09-24 — Settings fixes: `--set-hotkey` reports save + restart truthfully (not-running agent is a non-error); invalid config.json is logged and flagged in the menu, file left alone; Pause While Recording toggle
- 2026-09-24 — Hook hardening: heartbeat replaces `pgrep` for agent liveness; direct fallback pipes text to `say -f -` and falls back past a broken HUD binary without raising; spool schema version `v`
- 2026-09-24 — Architecture batch: Playback module, spool contract test, one hook install path, test harness; fixed 5 defects (mic hold dropping items, Speed un-pausing, setup deleting its own binary, stale HUD after Stop, held items not shown)
- 2026-09-24 — Hold speech while anything else is recording (Claude Code hold-space dictation)
- 2026-09-24 — HUD can be dismissed and brought back; no zoom
