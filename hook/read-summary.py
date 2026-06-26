#!/usr/bin/env python3
"""
Stop hook: read Claude's CURRENT response aloud via macOS `say`.

Targets the turn that just finished (not a stale prior one) by anchoring on the
last user entry in the transcript and only reading assistant text that comes
AFTER it. If the transcript hasn't been flushed with the final message yet
(the classic Stop-hook race), it retries briefly until it appears.
"""
import sys, json, os, re, glob, time, subprocess

WAIT_SECONDS = 3.0      # max time to wait for the final message to be flushed
POLL_SECONDS = 0.1


def find_transcript(data):
    tp = data.get("transcript_path")
    if tp:
        tp = os.path.expanduser(tp)
        if os.path.exists(tp):
            return tp
    session_id = data.get("session_id", "")
    if session_id:
        hits = glob.glob(
            os.path.expanduser(f"~/.claude/projects/**/{session_id}.jsonl"),
            recursive=True,
        )
        if hits:
            return hits[0]
    return None


def current_response_text(path):
    """Assistant text that appears after the last user entry, or None if not yet present."""
    try:
        with open(path) as f:
            lines = f.readlines()
    except OSError:
        return None

    last_user = -1
    entries = []
    for line in lines:
        try:
            entries.append(json.loads(line))
        except ValueError:
            entries.append(None)
    for i, entry in enumerate(entries):
        if entry and entry.get("type") == "user":
            last_user = i

    texts = []
    for entry in entries[last_user + 1:]:
        if not entry or entry.get("type") != "assistant":
            continue
        content = entry.get("message", {}).get("content", [])
        if isinstance(content, str):
            texts.append(content)
            continue
        for c in content:
            if isinstance(c, dict) and c.get("type") == "text":
                texts.append(c.get("text", ""))
    text = " ".join(t for t in texts if t).strip()
    return text or None


def clean(text):
    # Drop fenced code blocks entirely — reading code aloud is useless.
    text = re.sub(r"```.*?```", " ", text, flags=re.DOTALL)
    text = re.sub(r"`[^`]*`", "", text)          # inline code
    text = re.sub(r"\[([^\]]*)\]\([^\)]*\)", r"\1", text)  # links -> label
    text = re.sub(r"[*_#>]+", "", text)          # emphasis / headers / quotes
    text = re.sub(r"^\s*[-+]\s+", "", text, flags=re.MULTILINE)  # list bullets
    text = re.sub(r"\s+", " ", text).strip()
    return text


def main():
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return
    path = find_transcript(data)
    if not path:
        return

    deadline = time.time() + WAIT_SECONDS
    text = current_response_text(path)
    while not text and time.time() < deadline:
        time.sleep(POLL_SECONDS)
        text = current_response_text(path)
    if not text:
        return

    text = clean(text)
    if not text:
        return

    # Stop anything already playing so turns don't pile up.
    subprocess.run(["pkill", "-x", "speak-hud"], stderr=subprocess.DEVNULL)
    subprocess.run(["pkill", "-x", "say"], stderr=subprocess.DEVNULL)

    # Prefer the floating HUD (Stop / Replay buttons); fall back to plain `say`.
    hud = os.path.expanduser("~/.claude/bin/speak-hud")
    if os.path.exists(hud):
        p = subprocess.Popen([hud], stdin=subprocess.PIPE)
        p.stdin.write(text.encode("utf-8"))
        p.stdin.close()
    else:
        subprocess.Popen(["say", text])


if __name__ == "__main__":
    main()
