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
- The name is a zero-padded nanosecond timestamp plus a random tail, so a plain filename
  sort is arrival order and two terminals finishing at the same instant can't clobber
  each other.
- `key` is the **session id**, not the project path: the agent keeps only the newest
  pending item per key, and two terminals in the same repo are two conversations that
  both deserve to be heard.

The `--agent` process (installed by `build.sh` as a LaunchAgent) watches that directory
and drains it one item at a time into the single HUD.

## Fallback

If no agent is running there's nothing to queue behind, so the hook falls back to
speaking directly: `~/.claude/bin/speak-hud --source <project>` if that binary exists,
otherwise plain `say`.
