# Claude Code integration

`read-summary.py` is a [Claude Code](https://www.claude.com/product/claude-code) `Stop`
hook. When Claude finishes a turn it reads the transcript, extracts the latest assistant
message, strips code blocks / markdown, and hands the text to SpeakHUD.

Wire it up in `~/.claude/settings.json`:

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
{"text": "…", "source": "SpeakHUD", "key": "<session_id>", "created": 1783642610.69}
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

## Fallback

If no agent is running there's nothing to queue behind, so the hook falls back to
speaking directly: `~/.claude/bin/speak-hud --source <project>` if that binary exists,
otherwise plain `say`.
