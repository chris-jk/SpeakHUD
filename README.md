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
  a moment after the mic is released (macOS 14+). Want speech during calls? Untick
  **Pause While Recording** in the menu bar.
- **Answer out loud, hands-free** (macOS 26+, off until you turn it on). With **Listen
  After Reading** ticked, the mic opens when a Claude Code turn has been read; what you
  say is typed into that terminal and sent when you stop. See
  [Listen After Reading](#listen-after-reading).
- **Talk over it** (macOS 26+, off until you turn it on). With **Listen While Reading**
  ticked, say *"skip"*, *"later"*, *"again"*, *"pause"* or *"go on"* while a turn is being
  read. The Mac's own voice is cancelled out of the mic, so it doesn't obey itself. See
  [Listen While Reading](#listen-while-reading).
- **Answer from your phone** (off until you set it up). A page on your own tailnet shows
  each terminal's last turn in a window the colour of that terminal, takes your answer,
  and answers question boxes with a tap. Switch **Away** on and finished turns are pushed
  to your phone instead of read to an empty room. See [The phone](#the-phone).
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

- **Whoever is speaking is named in a colored pill**, by the session's title, the same
  words Claude Code puts in that terminal's title bar (the folder name until the session
  has one). Each name keeps the same color every time (a stable hash of the name, not
  Swift's per-process `hashValue`), so four terminals become four colors you recognize
  rather than four names you read. The `next:` line colors each waiting one the same way.
- **A terminal that has its own color gives it to the pill.** Where a hook colors each
  terminal's window frame by project (claude-launcher's `terminal-project.py`), the pill
  is filled with that same color, so it looks like the window it belongs to. Anything
  else keeps the tinted, hashed color above.
- **Click the pill to go to that terminal.** A `↗` after the name means SpeakHUD knows
  where it came from: clicking switches to that iTerm2 pane or Terminal.app tab, on
  whatever desktop it's on. The rest of the screen dims for a second and that window
  gets a ring in the pill's color, so in a group of terminals you see which one came
  forward. Other terminals (VS Code, Ghostty, …) get their app brought
  forward; a hotkey read goes back to the app you read it from. The first click asks
  for permission to control iTerm2 (System Settings › Privacy & Security › Automation).
- **Paths, commands and URLs in the text are links.** A folder is shown selected in the
  folder above it; a file opens in its default app (shown in Finder instead if that app
  would run it, e.g. a script); a path that's gone opens the nearest folder still there.
  A command (inline code whose first word is on Claude's PATH, `./script`, or `! cmd`)
  is typed into a new iTerm2 window in the turn's directory and left there — never run.
  URLs open in your browser. Relative paths resolve against the turn's directory.
- **Shell code blocks are shown, not spoken.** A fenced `bash`/`sh`/`zsh`/`console`
  (or unlabeled) block with commands in it appears where it was, in a code font, with
  each command line clickable; other code blocks stay hidden.
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

## Listen After Reading

Off by default; tick it in the menu bar (macOS 26 or later, iTerm2). The first time, macOS
asks for the microphone.

When a Claude Code turn has been read to its end, the mic opens for that turn and a
*tink* says it's listening. The HUD says who you'd be answering and shows the words as they're heard.

- **Say your reply.** After a pause of 1.5 s it shows as *Sending…* for another 1.5 s (say
  more and it goes back to listening; **Skip** or `⌃⌥P` takes it back), then it's pasted
  into the prompt of the terminal that spoke and sent. A *pop* means it went.
- **Say nothing** and the mic closes after 8 s; the next turn in the queue is read.
- **Clear.** Once it has heard something the HUD's Pause button reads **✕ Clear**: it (or
  `⌃⌥P` from anywhere) throws that away, right up until it's sent, and listens again for
  5 s. With nothing heard the button reads **✕ Close** and shuts the mic, so Clear twice
  is "not now".
- **Say one of these**, alone, and it's for the HUD instead of Claude:
  - *"say that again"*, *"repeat that"*, *"remind me again"*: reads the turn again, then asks again
  - *"put it off"*, *"put it off to the end"*, *"ask me later"*: the turn goes to the back
    of the queue (or, with nothing queued, waits for the next turn to arrive) and you're
    asked then
  - *"skip"* or *"no reply"*: closes the mic now and moves on
  - *"clear that"*, *"scratch that"*, *"never mind"*, *"don't send that"* (also at the end
    of whatever was heard): throws it away and listens again for 5 s, in case you want to
    say it properly; say nothing and it closes. For when it heard something that wasn't
    meant for it

  Apart from "skip" they're whole phrases you wouldn't say to Claude, on purpose: plain
  "later" or "again" is a reply, and is sent.
- Nothing else is read while the mic is open, and holding Claude Code's own dictation
  key closes it (you're answering that way instead).

Everything is transcribed on the Mac by the system's own transcriber (`SpeechAnalyzer`);
no audio or text leaves it. With only this setting on, the mic is open from the end of a
turn to your reply and at no other time.

**What it will and won't type into.** A question or permission box in Claude Code takes
a typed digit as its answer on the spot, so a reply is never typed: it goes in as a
paste, which those boxes ignore (tried against Claude Code 2.1.293 with a question box
and the folder-trust box; a permission box was not tried). Before pasting, SpeakHUD reads
the terminal's screen and only goes on if Claude's prompt box is there and no such box is;
Return is pressed only once the words show at the start of the prompt, and it counts as
sent once they've left it. Otherwise the HUD says *Not sent* and why, and what you said
stays on screen to copy. If you'd already typed something at that prompt, your reply is
pasted after it and Return is left to you.

**It hears whatever is said.** A video, a call or someone else talking during those few
seconds is heard as your reply. That's what the *Sending…* pause is for; keep it off
when the room isn't yours.

Not yet: answering a Claude Code question box by voice, Terminal.app.

## Listen While Reading

Off by default; tick it in the menu bar (macOS 26 or later). While turns are being read
the mic is open, the status line ends in `🎙 again · later · skip · pause`, and a short
phrase said on its own is a command. A *bottle* sound means it heard one.

| Say | It does |
| --- | --- |
| *"skip"*, *"next"*, *"move on"* | drops this turn and reads the next |
| *"later"*, *"not now"*, *"put it off"* | sends this turn to the back of the queue, to be read from the top then (with nothing else queued, it waits for the next turn to arrive) |
| *"again"*, *"repeat"*, *"start over"*, *"say that again"* | reads this turn from the top |
| *"pause"*, *"stop"*, *"wait"*, *"hold on"* | pauses; the mic stays open for a minute for… |
| *"go on"*, *"continue"*, *"keep going"* | …carrying on from where it was |
| *"stop everything"*, *"clear the queue"* | what the Stop button does: silence, queue thrown away |

- **On its own** means with a breath (0.6 s) after it, and nothing before it but an
  "okay" or "um": *"skip the tests"* said to someone else in the room is not a command.
- **It doesn't obey itself.** The mic is opened with the system's voice processing, which
  cancels whatever the Mac is playing out of what the mic hears. Tried on a MacBook's own
  speakers and mic: with a plain mic the transcriber caught 20 of 24 words the voice said;
  with voice processing, none, and a text made of *"Skip. Next. Later. Pause."* was read to
  its end. As a second line of defence, a command that matches words the voice has just
  said (or is about to) is ignored.
- **Your dictation is left alone.** The moment another app records (Claude Code's
  dictation key, a call), the mic shuts until it's done.
- **Paused by key or button, the mic shuts.** Only a pause you asked for by voice keeps it
  open, and only for a minute.
- The mic is open the whole time something is being read, so macOS shows its orange dot
  for that long. Nothing is recorded or kept, and it's all on the Mac. Voice processing
  also turns other sound down a little while it's on; it's set to the least it allows.
- Bluetooth headsets drop to call quality while their mic is open. This is for speakers,
  or wired headphones with the Mac's own mic.

## The phone

Walk away from the Mac and keep answering. SpeakHUD serves one page, on this Mac only
(`127.0.0.1`); your tailnet carries it to your phone, so nothing here listens on a
network and nothing leaves your own devices.

What's on the page:

- **A window per terminal**, newest first, with a bar in that terminal's own frame
  colour, its last finished turn, and a box to answer in. Every iTerm2 pane running
  Claude Code gets one, whether or not it has finished a turn yet, and a closed
  terminal's window goes. An answer is pasted into that
  terminal's prompt and sent, by the same guarded paste as a spoken reply: only into
  Claude Code's prompt box, never into a question or permission box.
- **Whatever it's asking, as buttons.** A question, a permission prompt, the
  folder-trust check: the box is read off the terminal's own screen, so its choices show
  as they stand, ticks and all, and a tap picks one (its number, or arrows and Enter
  for a choice without one). The choice that takes your own words is a field. The Mac
  reads the box again before it presses anything, so a box that has moved on is never
  answered blind.
- **Working, asking, or waiting on you.** A window in full colour is waiting on you; one
  that has stepped back to a stripe says "working", and its Send becomes Queue; one
  with a box up says "asking". A working window also runs a bar down by its answer
  buttons, where your thumb is, for as long as its terminal is at work. Under the bar
  at the top is the terminal's own status line, which is where your model and context
  figure show if your status line has them.
- **Say it instead of typing it.** A mic button by each answer box. Tap it and talk:
  your words show in the box as you say them, after anything already there, and it
  stops by itself two seconds after you do (or tap it again), leaving them for you to
  read over and send. The phone only records; your Mac's own transcriber turns the
  sound into words, so it goes from your phone to your Mac and no further. See
  [Dictation from the phone](#dictation-from-the-phone).
- **What the turn made.** Pictures, video and sound a turn made or named show under it:
  a picture as a lighter copy (tap it for the real one), a video or a recording to play
  right there, a PDF as its name to open. A tap on a picture opens the turn's pictures
  over the page, one to a screen: swipe to the next, Save the one you're on, and the
  phone's own back (or the ✕) closes it. **Save** beside each one puts the file itself
  on the phone: through the share sheet where the phone has one for files (on an iPhone
  that's Save Image, Save Video, Save to Files, AirDrop), as a plain download otherwise. They come straight from the Mac over your
  tailnet; nothing is uploaded anywhere. A question brings what its turn has made so
  far, so "which of these?" comes with them. See [What the turn made](#what-the-turn-made).
- **Send a picture.** The picture button by the answer box picks photos or screenshots
  from the phone (up to six). They wait as chips above the box, a tap takes one off,
  and they go with the answer: the page shrinks each to a JPEG no more than 2000 pixels
  a side, the Mac keeps it in `~/.local/state/speakhud/from-phone` for a week, and the
  answer that reaches the terminal ends with where the pictures are, which is how a
  terminal's Claude reads one.
- **Quick answers.** The things you always send ("Wrap up") as one-tap buttons on every
  window. Add and remove your own under **Quick answers** at the top; they're kept on
  the Mac.
- **Resume an old session**, at the foot of the page: recent sessions by name, folder
  and age. Resume opens a new iTerm2 window on the Mac in the folder the session was
  started in and runs `claude --resume` for it.
- **Its screen**: the foot of the terminal as text, with keys (1 to 4, up, down, Enter,
  Esc) for anything that wants a key, or Esc to stop a turn. At Claude's prompt only
  Enter and Esc are pressed; a number there would just type into your message.
  **Close this terminal** is under there too, and takes two taps: Claude is asked to
  exit if it's at its prompt, then the pane is closed.
- **Read aloud.** A **Read** button on each window has the phone read that turn in its
  own voice. The paragraph being read is tinted, a block glides from word to word
  behind the text, and the page eases along to keep that word a little above the middle
  of the screen. While it reads the button is **Pause**; **Resume** carries on from the
  word it had reached (leaving the page pauses it too). Start over (↻) and stop (■) sit
  beside it in the bar, and the bar stays at the top of the screen while its turn
  scrolls under it. Only the newest open tab of the page speaks: each push you tap opens another. With the **Read aloud** switch on, turns are read as they arrive while the
  page is open; the switch is remembered, and after reopening the page one tap anywhere
  lets it speak again (phones only let a page talk after a tap). **Speed** steps through
  1×, 1.25×, 1.5×, 1.75×, 2× and 0.75×, and is remembered too. A locked phone or a
  closed page reads nothing: that's what the push is for.
- **Away.** On: finished turns are pushed to your phone and not read aloud, no mic opens
  for a reply nobody is there to give, and the Mac is kept from idling to sleep (the
  screen can still lock). The menu bar icon turns into a phone while it's on. Off: the
  Mac reads aloud as usual, and the page still works.

Set it up once (the names below are examples: use your own):

```sh
SPEAKHUD=/Applications/SpeakHUD.app/Contents/MacOS/speak-hud
tailscale serve --bg http://127.0.0.1:4778        # tailnet only; says the address it gave you
$SPEAKHUD --setup-phone --url https://my-mac.my-tailnet.ts.net \
          --ntfy https://ntfy.example.com/terminals
launchctl kickstart -k gui/$(id -u)/com.chris.speakhud.agent
```

- `--url` is the address your phone reaches the page at. `--ntfy` is an
  [ntfy](https://ntfy.sh) topic for the pushes; subscribe to it in the ntfy app. If the
  topic needs a token, pass `--ntfy-token`, or set `$SPEAKHUD_NTFY_TOKEN` to keep it out
  of your shell history. Without `--ntfy` the page works and Away pushes nothing.
- Then **Phone ▸ Pair a Phone…** in the menu bar shows a QR code. Open it with the
  phone's camera while the phone is on your tailnet. That link is the key to your
  terminals: it leaves a cookie on the phone, and without the cookie the page shows
  nothing. A pushed notification opens the page at the terminal it's about.
- Lost the phone, or the link got out? `speak-hud --setup-phone --new-token`, restart the
  agent, and pair again: the old key opens nothing.

Settings live in `~/.config/speakhud/phone.json` (yours alone, mode 600). Delete it and
restart the agent to turn the page off; `tailscale serve --https=443 off` stops the
tailnet carrying it.

### Dictation from the phone

The page records through the phone's microphone as plain sound (16-bit, one channel,
16,000 samples a second, about two megabytes a minute) and sends it to the Mac a piece
at a time while you talk, about three pieces a second. The Mac keeps the same on-device
transcriber Listen After Reading uses (macOS 26) open for the length of the dictation,
feeds it each piece, and answers each with the words so far; the newest of them are
still a guess and can change as more is heard, as they do in any dictation. The piece
sent when you stop is answered with the words as they finally stand. Nothing is sent
anywhere else or kept, and the agent's log says how many words were heard and how long
it took, never what they were.

If a piece doesn't get through (a bad patch of signal), the page stops sending pieces
and sends the whole recording when you stop instead, so nothing you said is lost: the
words then arrive all at once. That is also how it goes on a Mac whose transcriber
can't be kept open.

- It stops two seconds after you go quiet, eight seconds in if nothing was said at
  all, and at two minutes whatever happens. A tap on the mic stops it at once.
- On a slow line the words fall behind what you're saying and catch up: each piece
  waits for the one before, so they only get longer.
- The words are never sent for you: they go in the box, and Send is yours to tap.
- While it listens the phone's own reading is paused, and the other windows' mics are
  out of reach: one dictation at a time.
- The button shows only where it can work: the page has to be open over `https` (a
  phone won't give a plain `http` page its microphone), the browser has to allow the
  microphone for the site (it asks the first time), and the Mac has to have the
  transcriber. A microphone that won't start says why on the page and in the Mac's log.
- It hears the language your Mac is set to.

### What the turn made

The hook that queues a turn looks through that turn in Claude Code's transcript, from
the last thing you said to the end, for files of these kinds: `png jpg jpeg gif webp
heic svg`, `mp4 m4v mov webm`, `mp3 m4a wav aac`, `pdf`. A file counts if a tool call or
its output names it and it was written after the turn began, or if the turn's own words
name it (then its age doesn't matter). The newest twelve go with the turn.

The page never names a path. It asks the Mac for a turn's first, second, third file,
and the Mac sends only what is on that turn's list, is still there, and is still one of
those kinds (a link is followed, and what it leads to is what's judged). A video is sent
in the parts the phone asks for, never read whole into memory. A picture over 300 KB
goes as a copy no more than 1200 pixels a side; a tap on it, or on any file's name,
opens the real file. The agent's log says what the phone was shown, by name.

Not found: a file a command names only through a shell variable (`$OUT/clip.mp4`)
whose output doesn't print the path either; a bare name with spaces in it; a file moved
into place with its old dates. Saying the path in the turn's words always works.

Limits:

- A sleeping Mac answers nothing. Away holds off idle sleep, but a closed lid still
  sleeps.
- A window shows what its last finished turn made: the next turn replaces it.
- Whether a video plays is up to the phone: iPhones play H.264 and HEVC in `mp4` and
  `mov`; one it can't play says so and offers its name to open or save.
- Only iTerm2 panes can be answered, as with a spoken reply.
- A terminal that hasn't finished a turn since SpeakHUD first saw it shows an empty
  window (its screen and the answer box still work), in a colour picked from its name
  rather than its frame's.
- Away pushes a box coming up (a question, a permission prompt) as well as a finished
  turn, because the Mac keeps reading the terminals' screens while you're away.

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

This writes `~/.config/speakhud/config.json` and restarts the agent, and says which
happened: restarted, or saved but the agent isn't running (it takes effect when it
starts). A failed save or restart exits non-zero with the reason. Invalid combos
(no modifier, unknown key) are rejected and leave the current setting untouched.

If you edit `config.json` by hand and break it (bad JSON, no `"hotkey"`, a combo that
doesn't parse), SpeakHUD falls back to `⌃⌥S`, logs why, and shows
**⚠ config.json invalid** in the menu's Global Hotkey submenu. Your file is left alone
for you to fix.

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
than SpeakHUD's. It also names whichever app took the mic when speech holds
(`mic taken by …`). The log keeps the last 30 days: older lines are dropped when the
agent starts and once a day after.

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
- **Pause While Recording** — on by default: speech holds while another app uses the
  mic. Turning it off releases a hold at once. Shared with the standalone reader.
- **Listen After Reading** — off by default: answer a Claude Code turn out loud
  (see [Listen After Reading](#listen-after-reading)). Needs macOS 26.
- **Listen While Reading** — off by default: say "skip", "later", "again", "pause" while
  a turn is read (see [Listen While Reading](#listen-while-reading)). Needs macOS 26.
- **Phone** — **Away: Turns Go to My Phone** and **Pair a Phone…** (see
  [The phone](#the-phone)); a note instead, until `--setup-phone` has been run.
- **Global Hotkey** — pick a preset or open the config file (a warning line appears
  here if the file is invalid).
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
- `phone/` — the phone page (`index.html`, `app.css`, `app.js`, and `mic.js`, its microphone), copied into the app's
  resources by `build.sh` and served by `Phone` in `speak-hud.swift`.
- `make-icon.swift` — build-time tool that renders `AppIcon.icns`; not part of the app.
- `build.sh` — compile, bundle, sign, install the app + the LaunchAgent.
