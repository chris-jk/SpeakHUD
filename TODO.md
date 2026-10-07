# TODO — SpeakHUD

Running tab. Current state at top, then next up, waiting-on, recently shipped. Prune every session.

## Where things stand (2026-10-07)
- main (pushed 2026-10-07) holds click-to-terminal, clickable text, code blocks, the desktop-switch fix, the question reader, the pill's terminal color, the click highlight, the pill's session name, the ring fix and Listen After Reading; the installed build matches it (binary built 10-07 4:58 PM, after the last source change; `--claude-status` says `installed`; checked 10-07 4:58 PM against /Applications and the agent's log). LaunchAgent running.
- **Listen After Reading** (hands-free replies, Chris 10-07): built, installed, **off** until ticked in the menu bar. After an answerable turn is read the mic opens (tink); what's said is shown, then pasted into that terminal's prompt and sent after a 1.5 s pause plus 1.5 s of "Sending…"; 8 s of silence closes it. Said alone, "say that again" / "put it off" / "no reply" / "scratch that" are for the HUD. Pieces: the hook marks a finished turn `reply: "prompt"`; `Playback`'s reply window holds the rules (fake mic and hand-fired timers in tests); `MicEar` is the mic plus the Mac's own transcriber (`SpeechAnalyzer`, macOS 26, on-device); `Reply` talks to iTerm2. README has the user's view.
- Why a reply is pasted, never typed (checked 10-07 about 4:35 PM in a hook-free Claude Code 2.1.293 inside tmux): a typed "2" picked the second option of a question box at once; a pasted "2" and pasted words did nothing to it, nor to the folder-trust box. So `Reply.send` reads the pane's screen, pastes only where Claude's prompt box shows and no such box does, presses Return only once the words show at the start of the prompt, and says sent once they have left it. **Not checked: a permission box** (auto mode refused that test in the nested session).
- Checked live 10-07 4:50 to 4:57 PM, from a test program built on the app's own source and run in iTerm2: the real mic reached the transcriber (71 buffers, 12 updates, a reply settled; words never printed); a marker pasted into this session's own prompt showed on the first look and was erased; the whole `Reply.send`, Return included, arrived in this session as a message. **Not checked: SpeakHUD.app's own microphone grant** (the test ran under iTerm2's; macOS asks the first time the menu item is ticked) **and a person answering a real turn.**
- Tests: `./tests/run.sh`, 640 checks + 13 Python tests for the question hook, all passing (10-07 4:56 PM). The Ear suite plays a `say` recording (no sound) into the real transcriber and takes about 8 s; it skips itself where there is none. No CI; run them before committing. `test_chime_waits_for_whatever_is_being_read` timed out once on a busy Mac and passed on the rerun.
- Pill name: the session's title from the transcript (`ai-title`, or `custom-title` from /rename), i.e. what the window's title bar says; folder name only until a title exists (`source_name()` in read-summary.py, used by both hooks). It was the folder Claude was in, which changed with every `cd`: one window went by three names and four home-folder windows all said "chris". A long title is cut off but keeps its `↗` (drawn separately).
- Ring on the right window: the reveal scripts used the loop's `w` ("window N" from the front) after bringing it forward, so the bounds they replied with, and the tab and session they selected, belonged to the window that had been in front; the right window got focus and the last one got the ring. They now take the window's id first and go by id (`holdWindow`). Proved live 10-05 with the app's own script text run from a small accessory app: old script replied the previous window's bounds, new one the target's, same desktop and across desktops (the desktop switched and came back).
- Pill matches the terminal: the hook adds `origin.color`, asked of claude-launcher's `~/.claude/hooks/terminal-project.py` (`session_frame_color()`, added there the same day); the pill is then filled solid with that frame color, and the `next:` names use it too. No color for a session started in the home folder until its first project edit; those keep the hashed tint.
- Click highlight (`Spotlight`): the reveal scripts reply with the window's bounds, and after the jump every screen dims 40% for 0.9 s (fades over 0.4 s) with a ring in the pill's color around that window; clicks pass through, and a desktop switch restarts the 0.9 s. Checked 10-05: drawing rendered offscreen, one live flash, the real script's reply for a live iTerm2 window, and the pill clicked live with four terminals up.
- Speech rules live in `Playback` (fake voice in tests); AVSpeech sits behind `SpeechVoice`.
- Mic hold: speech pauses while any other process records (macOS 14+), resumes 0.6s after release. Menu toggle **Pause While Recording** (shared prefs, on by default) turns it off.
- Spool contract (hook ↔ agent) pinned by a test that runs the real Python `enqueue()`; items carry `v: 1`, other versions are dropped with a logged reason.
- Click-to-terminal: the hook writes `origin` (TERM_PROGRAM, iTerm2 session UUID, tty, host app pid) into each spool item; clicking the HUD's source pill runs an AppleScript that activates the terminal *then* selects that iTerm2 pane / Terminal.app tab (activating after selecting stays on the current desktop whenever the terminal has a window there), else activates the app. Pill clicks are caught in `HUDPanel.sendEvent` because the pill sits under the transparent title bar. Needs the `apple-events` entitlement (build.sh) and the Automation grant for iTerm2 (already given).
- Clickable text: the hook marks inline-code commands and paths (plus bare existing `/…`, `~/…` paths) as `links` + `cwd` in the spool item; the HUD makes them links. Folder → shown selected in its parent; file → default app (Finder if that app would run it); gone → nearest folder; command → new iTerm2 window in cwd, typed with `newline no`, never run. Clicked live: reveal and iTerm load both logged OK.
- Code blocks: the hook turns each fenced block into an anchor paragraph; shell blocks with commands go in the spool as `blocks` and `Transcript` puts them back in the HUD (never spoken), mapping the voice's word ranges past them. Unit-tested; not yet seen on screen (live test turn was stopped).
- Questions: `hook/read-question.py`, a PreToolUse hook on AskUserQuestion (plus `--answered` on PostToolUse), installed by hand in `~/.claude/hooks` + settings.json. Once the spool is empty it chimes (Glass), queues the question under `<session>:question`, waits for the agent to let it go, pauses 2s, queues the options. Stops on an answer, a newer question, or Stop (read from the agent log). Claude asks one question per call (global CLAUDE.md, grilling-extras). Heard live 10-01.
- Agent liveness is a heartbeat: the agent touches `agent.heartbeat` in the spool every 3s; the hook queues only if it's <10s old (waiting up to 4s for a fresh one, e.g. after wake), else speaks directly (HUD binary, then `say -f -`). tests/HookTests.swift runs the real hook against a stub `say`.

## ⏭️ Next session — start here
- [ ] How Chris's first spoken replies went (first item under Owner only): fix what he trips on before adding more
- [ ] Commands while a turn is being read (first item under Next up)
- [ ] Move the question pause into `Playback`

## 🚨 Blocking
- (none)

## 🙋 Owner only
- [ ] Tick **Listen After Reading** in the menu bar (macOS asks for the mic once), then answer one turn out loud: after the tink, speak, stop, and watch it show as Sending and land in that terminal. Try "say that again" once. `tail -f ~/Library/Logs/speakhud-agent.log` shows `listening for a reply`, `mic shut after N buffers` and `reply to … : sent`
- [ ] Click the pill for a terminal on another desktop and watch the ring: it should land on that window after the switch (`Spotlight` restarts its 0.9 s on a desktop change). The switch itself and the bounds it rings are confirmed (10-05, real script from an accessory app); only the look of it is left
- [ ] Glance at the first real turn with a ```bash block in the HUD (layout of the indented code)

## 🟡 Next up
- [ ] Commands while a turn is still being read ("again", "later", "skip", "stop"; Chris, 10-07): the mic has to be open while it talks, so it hears itself. Try the input node's voice processing (echo cancelling) first; headphones are the fallback. While reading, anything short it hears is a command, so single words are safe there (they aren't in the reply window, where "later" may be meant for Claude)
- [ ] Answer a question box by voice: after `read-question.py` has read the options, listen and turn "one" / "the second" / a label into the typed digit (a typed digit picks the option at once: checked 10-07 4:34 PM, tmux, Claude Code 2.1.293). Needs its own `reply` kind in the spool with the options
- [ ] Try a paste against a permission box by hand (expected: ignored, like the question box). Until then `Reply.promptText` is the only thing keeping a reply out of one
- [ ] The question hook chimes and queues during a reply window: it only waits for the spool to empty, and a turn's file is gone once it's read. The question then waits for the window, which is right; the chime arriving while you're talking isn't
- [ ] Listen After Reading hears anything said in the room (a video, a call). Voice processing would at least cancel the Mac's own sound; same work as the first item
- [ ] A hosted voice model to talk with freely, on top of this (Chris, 10-07): per-minute cost, audio leaves the Mac, goes through the gateway. Only if the on-device loop turns out not to be enough
- [ ] Move the question pause into `Playback` (one spool item with the options and a pause): another session's turn can land in the 2s gap today, and Stop/skip would act on the whole question natively (review 10-01)
- [ ] Split panes in one iTerm2 window (the tile-terminals skill's layout): the ring goes around the whole window. Ring the pane instead; its frame is the Accessibility frame of the focused text area's scroll area (the text area itself is as tall as the scrollback)
- [ ] Have `ClaudeHook` (--setup-claude) install read-question.py and both its hook entries, and bundle it in build.sh, so it stops being a hand install
- [ ] Terminal.app path is untested live (no Terminal windows open), including its copy of the 10-05 by-id fix; iTerm2 verified
- [ ] The reveal script brings the terminal app forward even when the pane is gone (it activates before it searches)

## 🧊 Later
- (none)

## ⏳ Waiting on others
- (none)

## ✅ Recently shipped (trim as it ages)
- 2026-10-07 — Listen After Reading: answer a Claude Code turn out loud. The mic opens when the turn has been read, the Mac transcribes it, and the reply is pasted into that terminal's prompt and sent; "say that again", "put it off", "no reply", "scratch that". Off until ticked in the menu bar
- 2026-10-07 — Committed the 10-05 evening work: the pill goes by the session's title (what the window's title bar says), the ring lands on the window the click went to (the scripts hold the window by id), and a long name keeps its `↗`
- 2026-10-05 — The pill takes the terminal's window frame color; clicking it dims the screen and rings the window it went to
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
