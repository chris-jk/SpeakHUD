# Claude Code integration

`read-summary.py` is a [Claude Code](https://www.claude.com/product/claude-code) `Stop`
hook. When Claude finishes a turn it reads the transcript, extracts the latest assistant
message, strips code blocks / markdown, and hands the text to SpeakHUD.

The app installs it for you (menu bar, or `speak-hud --setup-claude` from the app
bundle), copying this script to `~/.claude/read-summary.py`. To wire it up by hand, copy
the script there and add this to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command", "command": "python3 ~/.claude/read-summary.py", "async": true } ] }
    ]
  }
}
```

## Why it queues instead of speaking

The hook does **not** speak directly. If it did, every terminal running Claude would
start its own reader the moment its turn finished — and since audio is a single shared
resource, whichever finished last would have to kill whatever you were listening to.
(That's precisely what an earlier version did, with a `pkill -x speak-hud`.)

Instead the hook writes one JSON file per finished turn into
`~/.local/state/speakhud/queue/`:

```json
{"v": 1, "text": "…", "source": "SpeakHUD", "key": "<session_id>", "created": 1783642610.69}
```

- Files are written as `<name>.tmp` and then `rename`d to `<name>.json`. Rename is atomic
  within a filesystem, so the agent never reads a half-written item.
- The agent claims an item by renaming it again, to `<name>.taken`, and only deletes it
  once it has actually been spoken (or been skipped, stopped, or superseded). A crash or
  a rebuild mid-queue therefore leaves the pending items on disk, and the next agent
  re-adopts them on startup rather than swallowing the queue.
- The name is a zero-padded nanosecond timestamp plus a random tail, so a plain filename
  sort is arrival order and two terminals finishing at the same instant can't clobber
  each other.
- `key` is the **session id**, not the project path: the agent keeps only the newest
  pending item per key, and two terminals in the same repo are two conversations that
  both deserve to be heard. A file with no `key` gets its own filename as the key, so it
  is never merged with anything.
- `v` is the schema version. An item with no `v` is read as version 1 (files from
  before it existed); any other value is dropped (`unsupported schema version`) rather
  than misread, so a newer hook can't feed an older agent fields it doesn't understand.
  Bump it on both sides (`SPOOL_VERSION` here, `Spool.version` in the app) when the
  fields change meaning.
- `created` is epoch seconds. If it's missing the agent uses the file's modification
  time instead; if it's there but not a number, the item is dropped. Blank `text` is
  dropped too, and so is anything older than 10 minutes. A missing `source` shows as
  "Claude Code".
- Nothing is dropped silently: each dropped item gets a `spool: dropped <file> — <reason>`
  line in `~/Library/Logs/speakhud-agent.log`. The agent also deletes any `.tmp` older
  than 10 minutes, which is what a hook killed mid-write leaves behind.
- `SPEAKHUD_QUEUE_DIR` moves the queue for both the hook and the agent. It exists for
  tests. Set it for only one side and the hook writes somewhere the agent never reads,
  so the agent logs `spool: watching <dir>` at startup to show which one it chose.
- `tests/SpoolTests.swift` pins this format. It runs the real `enqueue()` from this
  hook and the real Swift drain on the same temp directory.

The `--agent` process (installed by `build.sh` as a LaunchAgent) watches that directory
and drains it one item at a time into the single HUD.

## Is the agent there?

The hook queues a turn only if the agent has shown recently that it's draining. The
agent touches `agent.heartbeat` in the queue directory when it starts and then every 3
seconds, from the same main-thread timer that polls the queue (App Nap is off for it, and
it keeps running while a menu is open). The hook treats the agent as alive only if that
file's modification time is less than 10 seconds old, which allows two missed beats plus
some timer slack.

The name is deliberately not `.json`, `.tmp` or `.taken`, so the agent's drain and
recovery never touch it. This replaced `pgrep -f "speak-hud --agent"`, which was also
true for a hung agent or any unrelated command line containing that string, so turns
were queued where nothing would read them. If the agent dies within 10 seconds of its
last beat, a turn can still be queued. It then waits for the restarted agent, which reads
it if that happens within 10 minutes.

## Fallback

If the heartbeat is missing or stale there's nothing to queue behind, so the hook falls
back to speaking directly. It pipes the text to `~/.claude/bin/speak-hud --source
<project>` if that binary exists. Otherwise, or if that binary won't start or exits
without reading the text, it pipes the text to `say -f -`. The text always goes in on
stdin, never as an argument, so a turn that starts with `-` can't be read as an option.
If nothing can speak, the hook logs `speakhud: …` to stderr and exits normally.
`tests/HookTests.swift` runs the real hook against a stub `say` to pin this.
