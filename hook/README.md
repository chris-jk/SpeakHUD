# Claude Code integration

`read-summary.py` is a [Claude Code](https://www.claude.com/product/claude-code) `Stop`
hook. When Claude finishes a turn it reads the transcript, extracts the latest assistant
message, strips code blocks / markdown, and pipes the text to `speak-hud`.

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

The script prefers the floating HUD at `~/.claude/bin/speak-hud` (refreshed by
`build.sh`) and falls back to plain `say` if it isn't present.
