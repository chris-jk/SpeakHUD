#!/usr/bin/env python3
"""
Claude Code hook for AskUserQuestion: a chime, the question, a pause, then its options,
read through SpeakHUD.

    PreToolUse   python3 read-question.py             (async: it waits on the HUD)
    PostToolUse  python3 read-question.py --answered  (sync: it only drops a marker)

The Stop hook (read-summary.py) only fires when a turn ends, and a turn that asks with
AskUserQuestion hasn't ended: it waits on the answer. So questions went unheard.

SpeakHUD plays queued items back to back with no gap, so the pause lives here: once the
spool is empty the hook chimes and queues the question (with any text Claude wrote
before asking), waits for the agent to let go of it, pauses PAUSE_SECONDS, then queues
the options. Each hook holds a marker; it stops queueing once the question is answered
(PostToolUse removes the marker), a newer question from the session arrives, or you
press Stop. No hook fires between answers inside one multi-question call, so Claude
asks one question per call and those are read in a row. Previews aren't spoken.

Known gap: the spool is empty during the pause, so another session's turn can be read
between a question and its options. Doing the pause in Playback would close it.
"""
import hashlib, importlib.util, json, os, re, subprocess, sys, time
from datetime import datetime

# The Stop hook's cleaning and spool code: beside this file in the repo, and in
# ~/.claude where the app installs it (this one goes in ~/.claude/hooks).
_here = os.path.join(os.path.dirname(os.path.abspath(__file__)), "read-summary.py")
spec = importlib.util.spec_from_file_location(
    "read_summary", _here if os.path.exists(_here) else os.path.expanduser("~/.claude/read-summary.py"))
rs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rs)

PAUSE_SECONDS = float(os.environ.get("READQ_PAUSE") or 2.0)
# "none" turns it off. READQ_PLAYER is for tests.
CHIME = os.environ.get("READQ_CHIME") or "/System/Library/Sounds/Glass.aiff"
PLAYER = os.environ.get("READQ_PLAYER") or "/usr/bin/afplay"
# A paused HUD or a busy mic holds an item. A wait that runs out gives up rather than
# queue a question that's likely answered by now; the budget keeps the whole hook
# inside the 600s timeout settings.json gives it.
MAX_WAIT = float(os.environ.get("READQ_MAX_WAIT") or 120.0)
BUDGET = 540.0
MARKERS = os.path.join(os.path.dirname(rs.QUEUE_DIR), "questions")
# Stop deletes the item's file just as finishing does; only the agent's log tells them
# apart ("stop: discarded …", written by Playback.stop()).
AGENT_LOG = os.path.expanduser(os.environ.get("READQ_AGENT_LOG") or "~/Library/Logs/speakhud-agent.log")
STOP_LINE = re.compile(r"^\[([^\]]+)\] stop: ", re.M)
# Another PreToolUse hook can turn a question down before you see it (an "ask gate").
# Hooks on one event start together, so it leaves a verdict named after the call,
# `<tool_use_id>.block` or `.allow`, and this hook waits a moment for it. No such
# folder means no gate: nothing waits.
GATE_DIR = os.path.expanduser(os.environ.get("READQ_GATE_DIR") or "~/.claude/state/ask-gate")
GATE_WAIT = float(os.environ.get("READQ_GATE_WAIT") or 3.0)


def segments(questions):
    """[(markdown, pause_before)]: each question, then its options after a pause."""
    out = []
    many = len(questions) > 1
    for n, q in enumerate(questions, 1):
        head = f"Question {n} of {len(questions)}. " if many else ""
        out.append((head + q.get("question", "").strip(), n > 1))
        lines = ["Pick any that apply."] if q.get("multiSelect") else []
        for i, opt in enumerate(q.get("options", []), 1):
            label = opt.get("label", "").strip()
            desc = opt.get("description", "").strip()
            lines.append(f"- {i}. {label}." + (f" {desc}" if desc else ""))
        out.append(("\n".join(lines), True))
    return out


def session_key(data):
    return data.get("session_id") or data.get("transcript_path") or "question"


def tag(key):
    """Marker-safe stand-in for the key (a transcript path has slashes)."""
    return hashlib.sha1(key.encode()).hexdigest()[:16]


def uid(data):
    return re.sub(r"[^A-Za-z0-9_-]", "", data.get("tool_use_id") or "")


class Marker:
    """This hook's claim on the session's voice: `<tag>.<ns>.<uid>` in MARKERS.
    Names sort by time within a tag, so the newest question is the greatest name."""

    def __init__(self, key, tool_id):
        os.makedirs(MARKERS, exist_ok=True)
        self.tag = tag(key)
        self.name = f"{self.tag}.{time.time_ns():019d}.{tool_id or 'pid' + str(os.getpid())}"
        open(os.path.join(MARKERS, self.name), "w").close()
        old = f"{time.time_ns() - 3600 * 10**9:019d}"  # a killed hook's leftovers
        for n in os.listdir(MARKERS):
            parts = n.split(".")
            if len(parts) == 3 and parts[1] < old:
                self.drop(n)

    def superseded(self):
        """Answered (PostToolUse took the marker) or a newer question arrived."""
        try:
            names = os.listdir(MARKERS)
        except OSError:
            return True
        return self.name not in names or any(
            n.startswith(self.tag + ".") and n > self.name for n in names)

    def release(self):
        self.drop(self.name)    # only ever our own: a newer hook's marker isn't ours to take

    @staticmethod
    def drop(name):
        try:
            os.unlink(os.path.join(MARKERS, name))
        except OSError:
            pass


def answered(data):
    """PostToolUse: the question is answered; its hook queues nothing more."""
    t, u = tag(session_key(data)), uid(data)
    try:
        names = os.listdir(MARKERS)
    except OSError:
        return
    for n in names:
        if n.startswith(t + ".") and (not u or n.endswith("." + u)):
            Marker.drop(n)


def turned_down(tool_id):
    """A gate hook blocked this call, so the question never opens: read nothing.
    No verdict in time reads as allowed; a gate that broke must not mute questions."""
    if not tool_id or not os.path.isdir(GATE_DIR):
        return False
    end = time.time() + GATE_WAIT
    while True:
        if os.path.exists(os.path.join(GATE_DIR, tool_id + ".block")):
            return True
        if os.path.exists(os.path.join(GATE_DIR, tool_id + ".allow")) or time.time() >= end:
            return False
        time.sleep(0.05)


def done(stem):
    """Spoken, skipped, stopped or superseded: the agent deletes the file as it lets go."""
    return not any(os.path.exists(os.path.join(rs.QUEUE_DIR, stem + ext))
                   for ext in (".json", ".taken"))


def withdraw(stem):
    """Take back an item the agent hasn't picked up. Losing the race to it is fine."""
    try:
        os.unlink(os.path.join(rs.QUEUE_DIR, stem + ".json"))
    except OSError:
        pass


def idle():
    """Nothing queued or playing: every spool item keeps its file until it's let go."""
    return not any(n.endswith((".json", ".taken")) for n in os.listdir(rs.QUEUE_DIR))


def stopped_since(t):
    """Did you press Stop after `t`? The log's timestamps are whole seconds."""
    try:
        with open(AGENT_LOG, "rb") as f:
            f.seek(0, os.SEEK_END)
            f.seek(max(0, f.tell() - 16384))
            tail = f.read().decode("utf-8", "replace")
    except OSError:
        return False
    for m in STOP_LINE.finditer(tail):
        try:
            when = datetime.fromisoformat(m.group(1).replace("Z", "+00:00")).timestamp()
        except ValueError:
            continue
        if when >= int(t):
            return True
    return False


def wait_for(ready, deadline):
    end = min(time.time() + MAX_WAIT, deadline)
    while not ready():
        if time.time() >= end:
            return False
        time.sleep(0.2)
    return True


def chime():
    if CHIME.lower() == "none":
        return
    try:
        subprocess.run([PLAYER, CHIME], timeout=5,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError):
        pass


def intro_text(path, tool_id):
    """Text Claude wrote before asking. The Stop hook never reads it: the answer lands
    in the transcript as a user entry, and the turn's later text is read after it. Waits
    (like the Stop hook) for this call's entry to be flushed, so the text is in too."""
    if not path:
        return None
    deadline = time.time() + rs.WAIT_SECONDS
    while tool_id and time.time() < deadline:
        try:
            with open(path, "rb") as f:
                f.seek(0, os.SEEK_END)
                f.seek(max(0, f.tell() - 262144))
                if tool_id.encode() in f.read():
                    break
        except OSError:
            break
        time.sleep(rs.POLL_SECONDS)
    return rs.current_response_text(path)


def main():
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return
    if "--answered" in sys.argv[1:]:
        answered(data)
        return
    questions = (data.get("tool_input") or {}).get("questions") or []
    if not questions or turned_down(uid(data)):
        return

    # Claim the session's voice first, so an older question still waiting stands down.
    key = session_key(data)
    marker = Marker(key, uid(data))
    try:
        run(data, questions, marker, key)
    finally:
        marker.release()


def run(data, questions, marker, key):
    path = rs.find_transcript(data)
    intro = intro_text(path, data.get("tool_use_id") or "")
    parts = segments(questions)
    if intro:
        parts[0] = (intro + "\n\n" + parts[0][0], False)

    cwd = data.get("cwd") or ""
    source = rs.source_name(path, cwd)
    where = rs.origin()
    spoken = []
    for md, pause in parts:
        text, _ = rs.marked(md)
        text, spans, _ = rs.unmark(text)
        if not text:
            continue
        try:
            clickable = rs.links(text, spans, cwd)
        except Exception:
            clickable = []
        spoken.append((text, clickable, pause))
    if not spoken:
        return
    # What the turn has made so far goes with the question: "which of these?" is no
    # use to a phone that can't see them. (An older read-summary.py doesn't look.)
    try:
        named = [l["path"] for _, clickable, _ in spoken for l in clickable if "path" in l]
        media = rs.turn_media(path, named, cwd) if hasattr(rs, "turn_media") else []
    except Exception:
        media = []

    if not rs.agent_running():
        chime()
        rs.speak_directly("\n\n".join(t for t, _, _ in spoken), source, where)
        return

    # Its own key: the session's Stop-hook turn must never be swapped for options
    # (the agent keeps only the newest waiting item per key).
    ask(marker, spoken, source, key + ":question", where, cwd, media)


def ask(marker, spoken, source, key, where, cwd, media=None):
    deadline = time.time() + BUDGET
    prev, queued_at = None, 0.0
    for text, clickable, pause in spoken:
        if prev:
            if not wait_for(lambda: done(prev) or marker.superseded(), deadline):
                return
            if marker.superseded():
                withdraw(prev)
                return
            if stopped_since(queued_at):
                return
            if pause:
                time.sleep(PAUSE_SECONDS)
        elif not wait_for(lambda: idle() or marker.superseded(), deadline):
            return
        if marker.superseded():
            return
        if not prev:
            chime()
            # After the chime too: it lasts about a second, time enough for a newer one.
            if marker.superseded():
                return
        try:
            # The first piece carries the media: the options follow by themselves.
            prev = (rs.enqueue(text, source, key, where, clickable, cwd, media=media) if media and not prev
                    else rs.enqueue(text, source, key, where, clickable, cwd))
        except OSError as e:
            print(f"speakhud: could not queue question ({e})", file=sys.stderr)
            return
        queued_at = time.time()


if __name__ == "__main__":
    main()
