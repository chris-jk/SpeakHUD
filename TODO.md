# TODO — SpeakHUD

Running tab. Current state at top, then next up, waiting-on, recently shipped. Prune every session.

## Where things stand (2026-09-24)
- main @ cbceccf, pushed. Installed at /Applications/SpeakHUD.app; LaunchAgent running; Claude Code hook `installed`.
- Tests: `./tests/run.sh`, 221 checks, all passing. No CI; run them before committing.
- Speech rules live in `Playback` (fake voice in tests); AVSpeech sits behind `SpeechVoice`.
- Mic hold: speech pauses while any other process records (macOS 14+), resumes 0.6s after release.
- Spool contract (hook ↔ agent) pinned by a test that runs the real Python `enqueue()`; items carry `v: 1`, other versions are dropped with a logged reason.
- Agent liveness is a heartbeat: the agent touches `agent.heartbeat` in the spool every 3s; the hook queues only if it's <10s old, else speaks directly (HUD binary, then `say -f -`). tests/HookTests.swift runs the real hook against a stub `say`.

## ⏭️ Next session — start here
- (none pinned — see 🧊 Later)

## 🚨 Blocking
- (none)

## 🙋 Owner only
- [ ] After merging `fix-hook`, run `./build.sh`: the installed hook and agent must switch to the heartbeat together
- [ ] Delete the merged branches? Local `hud-visibility-and-readability`, `queue-speech-and-read-selection`, and `origin/hud-visibility-and-readability`

## 🟡 Next up
- (none)

## 🧊 Later
- [ ] `--set-hotkey` prints "hotkey set" even when the agent restart fails (`try? kick.run()`)
- [ ] An invalid ~/.config/speakhud/config.json silently falls back to the default hotkey; say so in the log/menu
- [ ] Menu toggle to turn the mic hold off (for anyone who wants speech during calls)

## ⏳ Waiting on others
- (none)

## ✅ Recently shipped (trim as it ages)
- 2026-09-24 — Hook hardening: heartbeat replaces `pgrep` for agent liveness; direct fallback pipes text to `say -f -` and falls back past a broken HUD binary without raising; spool schema version `v`
- 2026-09-24 — Architecture batch: Playback module, spool contract test, one hook install path, test harness; fixed 5 defects (mic hold dropping items, Speed un-pausing, setup deleting its own binary, stale HUD after Stop, held items not shown)
- 2026-09-24 — Hold speech while anything else is recording (Claude Code hold-space dictation)
- 2026-09-24 — HUD can be dismissed and brought back; no zoom
