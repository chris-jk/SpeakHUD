#!/usr/bin/env python3
"""
Stop hook: read Claude's CURRENT response aloud via SpeakHUD.

Targets the turn that just finished (not a stale prior one) by anchoring on the
last user entry in the transcript and only reading assistant text that comes
AFTER it. If the transcript hasn't been flushed with the final message yet
(the classic Stop-hook race), it retries briefly until it appears.

The finished turn is *queued*, never spoken directly: several terminals running
Claude at once would otherwise each kill whatever was already playing. The
SpeakHUD agent owns the one HUD and drains this queue one item at a time.
"""
import sys, json, os, re, glob, time, subprocess

WAIT_SECONDS = 3.0      # max time to wait for the final message to be flushed
POLL_SECONDS = 0.1
QUEUE_DIR = os.path.expanduser("~/.local/state/speakhud/queue")


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


def agent_running():
    return subprocess.run(
        ["pgrep", "-f", "speak-hud --agent"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    ).returncode == 0


def enqueue(text, source, key):
    """Hand the turn to the agent. Write-then-rename so it never reads a partial file."""
    os.makedirs(QUEUE_DIR, exist_ok=True)
    # Zero-padded nanosecond prefix so a plain filename sort is arrival order; the
    # random tail keeps a same-instant tie between two terminals from clobbering.
    stem = f"{time.time_ns():019d}-{os.urandom(4).hex()}"
    tmp = os.path.join(QUEUE_DIR, stem + ".tmp")
    with open(tmp, "w") as f:
        json.dump({"text": text, "source": source, "key": key, "created": time.time()}, f)
    os.rename(tmp, os.path.join(QUEUE_DIR, stem + ".json"))


def speak_directly(text, source):
    """No agent to queue behind: read it here, as this hook used to."""
    hud = os.path.expanduser("~/.claude/bin/speak-hud")
    if os.path.exists(hud):
        p = subprocess.Popen([hud, "--source", source], stdin=subprocess.PIPE)
        p.stdin.write(text.encode("utf-8"))
        p.stdin.close()
    else:
        subprocess.Popen(["say", text])


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

    cwd = data.get("cwd") or ""
    source = os.path.basename(cwd.rstrip("/")) or "Claude Code"
    # Coalesce on the session, not the project: two terminals in the same repo are
    # two independent conversations and both deserve to be heard.
    key = data.get("session_id") or cwd or source

    if agent_running():
        enqueue(text, source, key)
    else:
        speak_directly(text, source)


if __name__ == "__main__":
    main()
