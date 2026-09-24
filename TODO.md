# TODO — SpeakHUD

Running tab. Current state at top, then next up, waiting-on, recently shipped. Prune every session.

## Where things stand (2026-09-24)
- main @ cbceccf, pushed. Installed at /Applications/SpeakHUD.app; LaunchAgent running; Claude Code hook `installed`.
- Tests: `./tests/run.sh`, 178 checks, all passing. No CI; run them before committing.
- Speech rules live in `Playback` (fake voice in tests); AVSpeech sits behind `SpeechVoice`.
- Mic hold: speech pauses while any other process records (macOS 14+), resumes 0.6s after release.
- Spool contract (hook ↔ agent) pinned by a test that runs the real Python `enqueue()`.

## ⏭️ Next session — start here
- [ ] Harden the hook's no-agent fallback: `speak_directly` in hook/read-summary.py

## 🚨 Blocking
- (none)

## 🙋 Owner only
- [ ] Delete the merged branches? Local `hud-visibility-and-readability`, `queue-speech-and-read-selection`, and `origin/hud-visibility-and-readability`

## 🟡 Next up
- [ ] `speak_directly` passes text to `say` as argv (text starting with `-` is read as a flag) and has no error handling (a broken binary raises into the hook) — hook/read-summary.py
- [ ] `agent_running()` is `pgrep -f "speak-hud --agent"`: a hung agent, or any command line containing that string, makes the hook queue into a spool nobody drains, silently

## 🧊 Later
- [ ] `--set-hotkey` prints "hotkey set" even when the agent restart fails (`try? kick.run()`)
- [ ] An invalid ~/.config/speakhud/config.json silently falls back to the default hotkey; say so in the log/menu
- [ ] Menu toggle to turn the mic hold off (for anyone who wants speech during calls)
- [ ] Spool files carry no schema version; add one if the fields ever change

## ⏳ Waiting on others
- (none)

## ✅ Recently shipped (trim as it ages)
- 2026-09-24 — Architecture batch: Playback module, spool contract test, one hook install path, test harness; fixed 5 defects (mic hold dropping items, Speed un-pausing, setup deleting its own binary, stale HUD after Stop, held items not shown)
- 2026-09-24 — Hold speech while anything else is recording (Claude Code hold-space dictation)
- 2026-09-24 — HUD can be dismissed and brought back; no zoom
