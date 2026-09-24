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
# Must match Spool.dir in speak-hud.swift, override included (tests/SpoolTests.swift
# pins both). The variable is for tests: set it on one side only and turns go unheard.
QUEUE_DIR = os.path.expanduser(
    os.environ.get("SPEAKHUD_QUEUE_DIR") or "~/.local/state/speakhud/queue"
)


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
    # Blank line between blocks: they're separate thoughts, not one sentence.
    text = "\n\n".join(t for t in texts if t).strip()
    return text or None


BULLET = re.compile(r"^\s*(?:[-+*]|\d+[.)])\s+")


def clean(text):
    """Strip markdown to speakable prose, keeping the shape of the response.

    Flattening every newline turns a structured answer into one unreadable run-on in
    the HUD, and robs the synthesizer of the pauses that paragraph breaks give it.
    So: paragraphs stay paragraphs, list items stay one-per-line, and only the runs
    of spaces *within* a line get collapsed.
    """
    # Drop fenced code blocks entirely — reading code aloud is useless.
    text = re.sub(r"```.*?```", " ", text, flags=re.DOTALL)
    # Keep what's *inside* inline code. Deleting it leaves "it called , which…" —
    # a broken sentence on screen and a stumble when spoken. Fenced blocks are the
    # genuinely unreadable ones, and those are already gone.
    text = re.sub(r"`([^`]*)`", r"\1", text)
    text = re.sub(r"\[([^\]]*)\]\([^\)]*\)", r"\1", text)  # links -> label

    blocks = []
    for block in re.split(r"\n\s*\n", text):     # blank line = paragraph break
        lines = [l for l in (l.strip() for l in block.splitlines()) if l]
        # Detect bullets before stripping emphasis, or "*" markers vanish first.
        listy = any(BULLET.match(l) for l in lines)
        out = []
        for line in lines:
            line = BULLET.sub("", line)          # the marker itself isn't speakable
            line = re.sub(r"[*_#>]+", "", line)  # emphasis / headers / quotes
            line = re.sub(r"[ \t]+", " ", line).strip()
            if line:
                out.append(line)
        if out:
            # One item per line reads as a list; a wrapped paragraph reads as prose.
            blocks.append("\n".join(out) if listy else " ".join(out))
    return "\n\n".join(blocks).strip()


def agent_running():
    return subprocess.run(
        ["pgrep", "-f", "speak-hud --agent"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    ).returncode == 0


def enqueue(text, source, key):
    """Hand the turn to the agent. Write-then-rename so it never reads a partial file.

    The four fields are the contract with Spool.drain in speak-hud.swift, pinned by
    tests/SpoolTests.swift: rename one here and that test fails.
    """
    os.makedirs(QUEUE_DIR, exist_ok=True)
    # Zero-padded nanosecond prefix so a plain filename sort is arrival order; the
    # random tail keeps a same-instant tie between two terminals from clobbering.
    stem = f"{time.time_ns():019d}-{os.urandom(4).hex()}"
    tmp = os.path.join(QUEUE_DIR, stem + ".tmp")
    try:
        with open(tmp, "w") as f:
            json.dump({"text": text, "source": source, "key": key, "created": time.time()}, f)
        os.rename(tmp, os.path.join(QUEUE_DIR, stem + ".json"))
    except OSError:
        # Don't leave a partial .tmp behind to accumulate; the agent ignores them,
        # but nothing else would ever clean them up.
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


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
    # two independent conversations and both deserve to be heard. The transcript is
    # per-session too, so it's the right fallback; `cwd` would merge those terminals
    # back together. `path` is non-empty here — main() returned early otherwise.
    key = data.get("session_id") or path

    if agent_running():
        try:
            enqueue(text, source, key)
            return
        except OSError as e:
            # A full disk or an unwritable spool shouldn't mean silence.
            print(f"speakhud: could not queue turn ({e}); speaking directly", file=sys.stderr)
    speak_directly(text, source)


if __name__ == "__main__":
    main()
