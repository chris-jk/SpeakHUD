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
import sys, json, os, re, glob, time, subprocess, shlex, shutil, textwrap, importlib.util

WAIT_SECONDS = 3.0      # max time to wait for the final message to be flushed
POLL_SECONDS = 0.1
# Must match Spool.dir in speak-hud.swift, override included (tests/SpoolTests.swift
# pins both). The variable is for tests: set it on one side only and turns go unheard.
QUEUE_DIR = os.path.expanduser(
    os.environ.get("SPEAKHUD_QUEUE_DIR") or "~/.local/state/speakhud/queue"
)
SPOOL_VERSION = 1       # Spool.version: the agent drops any other `v` rather than misread it
HEARTBEAT = "agent.heartbeat"   # Spool.heartbeatName, touched by the agent every 3s
HEARTBEAT_STALE = 10.0  # seconds; see agent_running()
# How long to keep looking for a fresh beat before speaking directly. Covers a Mac just
# woken from sleep (the last beat predates it until the agent's timer next fires) and a
# spool dir the agent is about to recreate. The hook is async, so waiting costs nothing
# heard; speaking directly next to a live agent is a second voice. Tests set it to 0.
HEARTBEAT_GRACE = float(os.environ.get("SPEAKHUD_HEARTBEAT_GRACE") or 4.0)
# iTerm2 sets ITERM_SESSION_ID to "w4t0p0:<UUID>"; the UUID is the session's AppleScript id.
ITERM_SESSION = re.compile(r"^(?:w\d+t\d+p\d+:)?([0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12})$")
APP_EXEC = re.compile(r"\.app/Contents/MacOS/")
# The hook that colors each terminal's window frame by project (claude-launcher's
# terminal-project.py), if it's installed. Its session_frame_color() is asked for the
# color so the HUD's pill can match the window.
TERMINAL_HOOK = os.path.expanduser("~/.claude/hooks/terminal-project.py")


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


# Where Claude Code keeps a session's name in its transcript: one entry per write, the
# newest counts. A name the user gave it (/rename) beats the one Claude made up.
TITLE_KEYS = {"custom-title": "customTitle", "ai-title": "aiTitle"}


def session_title(path):
    """What Claude Code calls this session, which is what it puts in the terminal's
    title bar. None until the first one is written."""
    found = {}
    try:
        with open(path) as f:
            for line in f:
                if "-title" not in line:   # skip parsing the turns, which are the bulk
                    continue
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                key = TITLE_KEYS.get(entry.get("type")) if isinstance(entry, dict) else None
                title = entry.get(key) if key else None
                if isinstance(title, str) and title.strip():
                    found[key] = " ".join(title.split())
    except OSError:
        return None
    return found.get("customTitle") or found.get("aiTitle")


def source_name(path, cwd):
    """The name on the HUD's pill: the session's title, so the pill reads like the
    window it goes back to. The folder Claude is in is only the fallback, for a session
    with no title yet. It used to be the name, and it changes whenever Claude changes
    folder: one window went by three names, and two windows by the same one."""
    return ((path and session_title(path))
            or os.path.basename((cwd or "").rstrip("/")) or "Claude Code")


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
# Inline code is wrapped in these while the rest is cleaned, so emphasis stripping can't
# eat the `_` in a path, and so unmark() can say where each code span ended up.
CODE_OPEN, CODE_CLOSE = "\ue000", "\ue001"
CODE_SPAN = re.compile(CODE_OPEN + "([^" + CODE_CLOSE + "]*)" + CODE_CLOSE)
IN_CODE = re.compile("(" + CODE_OPEN + "[^" + CODE_CLOSE + "]*" + CODE_CLOSE + ")")
# A fenced block becomes a paragraph of its own, FENCE_OPEN + its index + FENCE_CLOSE,
# so unmark() can say where it was in the spoken text: never spoken, but the HUD
# shows the ones with commands in them, back where they were.
FENCE_OPEN, FENCE_CLOSE = "\ue002", "\ue003"
FENCE_MARK = re.compile(FENCE_OPEN + r"(\d+)" + FENCE_CLOSE)
MARKS = (CODE_OPEN, CODE_CLOSE, FENCE_OPEN, FENCE_CLOSE)


def clean(text):
    """Strip markdown to speakable prose, keeping the shape of the response."""
    return unmark(marked(text)[0])[0]


def marked(text):
    """(clean() with every inline code span left wrapped in CODE_OPEN/CODE_CLOSE and
    every fenced block left as its own FENCE_MARK paragraph, [(lang, body)] by index).

    Flattening every newline turns a structured answer into one unreadable run-on in
    the HUD, and robs the synthesizer of the pauses that paragraph breaks give it.
    So: paragraphs stay paragraphs, list items stay one-per-line, and only the runs
    of spaces *within* a line get collapsed.
    """
    for mark in MARKS:
        text = text.replace(mark, "")
    # Fenced code blocks aren't spoken — reading code aloud is useless.
    fences = []

    def fence(m):
        lang, body = m.group(1).strip(), m.group(2)
        if not body.strip():                # ```npm test``` on one line
            lang, body = "", lang
        fences.append((lang.lower(), body))
        return "\n\n" + FENCE_OPEN + str(len(fences) - 1) + FENCE_CLOSE + "\n\n"
    text = re.sub(r"```([^\n`]*)\n?(.*?)```", fence, text, flags=re.DOTALL)
    # Keep what's *inside* inline code. Deleting it leaves "it called , which…" —
    # a broken sentence on screen and a stumble when spoken. Fenced blocks are the
    # genuinely unreadable ones, and those are already gone. A span that wraps a line
    # is only unwrapped: a paragraph break could split its marks.
    text = re.sub(r"`([^`]*)`", lambda m: m.group(1) if "\n" in m.group(1) or not m.group(1).strip()
                  else CODE_OPEN + m.group(1) + CODE_CLOSE, text)
    # Command links ([$ npm test](typecmd:…), Cmd+click types them) are code; not spoken.
    text = re.sub(r"\[[^\]]*\]\(typecmd:[^\)]*\)", "", text)
    # A line that held only a command link is left a bare bullet or checkbox; drop it.
    text = re.sub(r"(?m)^[ \t]*(?:(?:[-+*]|\d+[.)])(?:[ \t]+\[[ xX]\])?|\[[ xX]\])[ \t]*$\n?", "", text)
    text = re.sub(r"\[([^\]]*)\]\([^\)]*\)", r"\1", text)  # links -> label

    blocks = []
    for block in re.split(r"\n\s*\n", text):     # blank line = paragraph break
        lines = [l for l in (l.strip() for l in block.splitlines()) if l]
        # Detect bullets before stripping emphasis, or "*" markers vanish first.
        listy = any(BULLET.match(l) for l in lines)
        out = []
        for line in lines:
            line = BULLET.sub("", line)          # the marker itself isn't speakable
            line = "".join(part if part.startswith(CODE_OPEN) else prose(part)
                           for part in IN_CODE.split(line)).strip()
            if line:
                out.append(line)
        if out:
            # One item per line reads as a list; a wrapped paragraph reads as prose.
            blocks.append("\n".join(out) if listy else " ".join(out))
    return "\n\n".join(blocks).strip(), fences


def prose(part):
    part = re.sub(r"[*_#>]+", "", part)       # emphasis / headers / quotes
    return re.sub(r"[ \t]+", " ", part)


def u16(s):
    """Length in UTF-16 units: what NSString ranges, and so the HUD, count in."""
    return len(s.encode("utf-16-le", "surrogatepass")) // 2


def unmark(text):
    """(the spoken text, its code spans [(at, len, code)], and where each fenced block
    was [(at, index)]). Offsets are UTF-16 units into the spoken text; a block's `at`
    is the end of the paragraph before it (0 if none), where the HUD puts it back."""
    out, spans, anchors, at = [], [], [], 0

    def emit(s):
        nonlocal at
        for mark in MARKS:
            s = s.replace(mark, "")
        out.append(s)
        at += u16(s)

    # The text is "\n\n"-joined paragraphs (see marked()), and a fence is one whole.
    for para in text.split("\n\n") if text else []:
        m = FENCE_MARK.fullmatch(para)
        if m:
            anchors.append((at, int(m.group(1))))
            continue
        if out:
            emit("\n\n")
        pos = 0
        for c in CODE_SPAN.finditer(para):
            emit(para[pos:c.start()])
            spans.append((at, u16(c.group(1)), c.group(1)))
            emit(c.group(1))
            pos = c.end()
        emit(para[pos:])
    return "".join(out), spans, anchors


# -- what's clickable ------------------------------------------------------------
# The hook decides, not the HUD: it has Claude's PATH (is `flutter` a command?) and
# working directory (where is `tests/run.sh`?). URLs the HUD finds on its own.

# Words a shell runs that `which` won't find.
SHELL_WORDS = {"cd", "export", "source", ".", "alias", "unalias", "unset", "eval", "exec",
               "set", "pushd", "popd", "ulimit", "umask", "type", "command", "builtin",
               "setopt", "unsetopt", "autoload", "hash", "rehash", "nohup", "time"}
PROMPT = re.compile(r"^[!$]\s+")                # `! cmd` (Claude Code's shell escape), `$ cmd`
ENV_ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
LINE_REF = re.compile(r":\d+(?::\d+)?$")        # file.py:12, file.py:12:4
# A /… or ~/… path in the prose. The lookbehind keeps out URLs, "and/or" and "1/2".
BARE_PATH = re.compile(r"(?<![\w~/.:@\\-])~?/[^\s\"'<>()\[\]{}`,;]+")
MAX_LINK = 1000                                  # TextLink's limit on the Swift side


def links(text, spans, cwd):
    """[{"at", "len", "path"}] for a file or folder to open, [{"at", "len", "run"}] for
    a command to type into a terminal (never run). Inline code is tried as a command
    and then a path; bare /… and ~/… paths in the prose count only if they exist."""
    out = []
    for at, n, code in spans:
        link = code_link(code, cwd)
        if link:
            out.append(dict(at=at, len=n, **link))
    for m in BARE_PATH.finditer(text):
        raw = m.group(0).rstrip(".:!?")
        at = u16(text[:m.start()])
        n = u16(raw)
        if any(a < at + n and at < a + l for a, l, _ in spans):
            continue
        target = path_target(raw, cwd, loose=False)
        if target:
            out.append({"at": at, "len": n, "path": target})
    return sorted(out, key=lambda l: l["at"])


SHELL_LANGS = {"", "bash", "sh", "zsh", "shell", "console", "shell-session", "terminal", "fish"}
PROMPT_LINE = re.compile(r"^[$%]\s+")          # `$ cmd` / `% cmd` in a console block
MAX_BLOCK = 8000                                # CodeBlock's limit on the Swift side


def blocks(anchors, fences, cwd):
    """[{"at", "code", "links"}]: the fenced blocks worth showing — shell ones with a
    command in them — where they go back into the spoken text, and their command lines
    as {"at", "len", "run"} with at/len UTF-16 within `code`. The rest stay unseen."""
    out = []
    for at, i in anchors:
        lang, body = fences[i]
        if lang not in SHELL_LANGS:
            continue
        code = textwrap.dedent(body).strip("\n").rstrip()
        if not code or u16(code) > MAX_BLOCK:
            continue
        found = block_links(code, cwd, prompted=lang in ("console", "shell-session"))
        if found:
            out.append({"at": at, "code": code, "links": found})
    return out


def block_links(code, cwd, prompted):
    """Each command line in a shell block. A line ending in `\\` runs on into the next,
    and is typed as one line. In a console block (`prompted`) only `$ ` lines count."""
    lines = code.split("\n")
    starts, p = [], 0
    for line in lines:
        starts.append(p)
        p += len(line) + 1
    out, i = [], 0
    while i < len(lines):
        j = i
        while lines[j].rstrip().endswith("\\") and j + 1 < len(lines):
            j += 1
        parts = [l.rstrip()[:-1] if k < j else l for k, l in enumerate(lines[i:j + 1], start=i)]
        cmd = " ".join(part.strip() for part in parts).strip()
        first = lines[i]
        start = starts[i] + len(first) - len(first.lstrip())
        end = starts[j] + len(lines[j].rstrip())
        i = j + 1
        m = PROMPT_LINE.match(cmd)
        if m:
            cmd = cmd[m.end():]
        elif prompted:
            continue                            # output, not a command
        if not cmd or cmd.startswith("#") or len(cmd) > MAX_LINK \
                or any(ord(c) < 32 or 127 <= ord(c) <= 159 for c in cmd):
            continue
        if is_command(cmd, cwd):
            out.append({"at": u16(code[:start]), "len": u16(code[start:end]), "run": cmd})
    return out


def code_link(code, cwd):
    s = code.strip()
    if not s or len(s) > MAX_LINK or any(ord(c) < 32 or 127 <= ord(c) <= 159 for c in s):
        return None
    m = PROMPT.match(s)
    if m:
        return {"run": s[m.end():]}
    # `./x` is how you say "run x"; `x` alone is the file.
    if s.startswith("./") and not any(c.isspace() for c in s) and runnable(s, cwd):
        return {"run": s}
    if any(c.isspace() for c in s) and is_command(s, cwd):
        return {"run": s}
    target = path_target(s, cwd, loose=True)
    return {"path": target} if target else None


def is_command(s, cwd):
    try:
        words = shlex.split(s)
    except ValueError:      # unbalanced quotes: prose with an apostrophe, not a command
        return False
    while words and ENV_ASSIGN.match(words[0]):
        words = words[1:]
    if not words:
        return False
    first = words[0]
    if "/" in first:
        return runnable(first, cwd)
    return first in SHELL_WORDS or shutil.which(first) is not None


def runnable(s, cwd):
    p = path_target(s, cwd, loose=False)
    return bool(p) and os.path.isfile(p) and os.access(p, os.X_OK)


def path_target(s, cwd, loose):
    """The absolute path `s` names if it exists. `loose` (inline code, so meant as a
    path) also takes one whose folder exists, since clicking opens that folder."""
    s = LINE_REF.sub("", s)
    if not s or len(s) > MAX_LINK:
        return None
    shaped = s.startswith(("/", "~/", "./", "../")) or "/" in s.rstrip("/")
    p = os.path.expanduser(s)
    if not os.path.isabs(p):
        if not cwd:
            return None
        p = os.path.join(cwd, p)
    p = os.path.normpath(p)
    if os.path.exists(p):
        return p
    # Not straight under /: `/chrome` or `/help` is a Claude Code slash command, not a path.
    parent = os.path.dirname(p)
    if loose and shaped and parent != "/" and os.path.isdir(parent):
        return p
    return None

def origin():
    """Which terminal this turn came from, so clicking the HUD's project pill can take
    you back to it: {"term", "session", "tty", "app_pid", "color"}, each only if found.

    The hook inherits Claude's environment, so iTerm2's own variable names the exact
    pane. The process tree adds the tty (how Terminal.app finds a tab) and the app
    hosting the terminal (all any other terminal can offer). The color is the
    terminal's window frame, so the pill can look like the window it goes to. Best
    effort and never raises: a turn that can't say where it came from is still read.
    """
    out = {}
    term = os.environ.get("TERM_PROGRAM", "")
    if term:
        out["term"] = term
    m = ITERM_SESSION.match(os.environ.get("ITERM_SESSION_ID", ""))
    if m:
        out["session"] = m.group(1).upper()
    try:
        ps = subprocess.run(["/bin/ps", "-axo", "pid=,ppid=,tty=,comm="],
                            capture_output=True, text=True, timeout=2).stdout
    except (OSError, subprocess.SubprocessError):
        ps = ""
    tty, app_pid = ancestry(ps, os.getpid())
    if tty:
        out["tty"] = tty
    if app_pid:
        out["app_pid"] = app_pid
    color = frame_color()
    if color:
        out["color"] = color
    return out


def frame_color():
    """"#rrggbb" of this terminal's window frame, from the hook that paints it, or None:
    no such hook, or it hasn't colored this session (one started outside any project)."""
    try:
        spec = importlib.util.spec_from_file_location("terminal_project", TERMINAL_HOOK)
        hook = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(hook)
        color = hook.session_frame_color()
    except (Exception, SystemExit):   # someone else's file: whatever it does, the turn is still read
        return None
    if isinstance(color, str) and re.fullmatch(r"#[0-9A-Fa-f]{6}", color):
        return color.lower()
    return None


def ancestry(ps, pid):
    """(tty, app_pid) for `pid` from `ps -axo pid=,ppid=,tty=,comm=` output: the first
    controlling terminal up the tree, and the outermost `.app` above it. Outermost,
    because a terminal inside an Electron app runs under a nested helper .app."""
    table = {}
    for line in ps.splitlines():
        parts = line.split(None, 3)
        if len(parts) == 4 and parts[0].isdigit() and parts[1].isdigit():
            table[int(parts[0])] = (int(parts[1]), parts[2], parts[3])
    tty, app_pid, seen = None, None, set()
    while pid > 1 and pid in table and pid not in seen:
        seen.add(pid)
        ppid, t, comm = table[pid]
        if not tty and re.fullmatch(r"ttys\d+", t):
            tty = "/dev/" + t
        if APP_EXEC.search(comm):
            app_pid = pid
        pid = ppid
    return tty, app_pid


def agent_running():
    """True only if the agent has proved recently that it is draining the spool.

    The agent touches HEARTBEAT from the same main-thread timer that polls the spool,
    so a fresh mtime means "alive and not hung", which a process-list match (the old
    `pgrep -f "speak-hud --agent"`) couldn't say: a wedged agent, or any command line
    containing that string, passed it, and turns were queued where nobody would read
    them. It beats every 3s; HEARTBEAT_STALE allows two missed beats plus timer slack
    before giving up on it. If the agent died inside that window, the turn waits in
    the spool for the restarted agent (up to Spool.maxAge), as it always has.
    """
    deadline = time.time() + HEARTBEAT_GRACE
    while True:
        if heartbeat_fresh():
            return True
        if time.time() >= deadline:
            return False
        time.sleep(0.25)


def heartbeat_fresh():
    try:
        beat = os.stat(os.path.join(QUEUE_DIR, HEARTBEAT)).st_mtime
    except OSError:
        return False    # never started, or not since the spool dir was cleared
    age = time.time() - beat
    # A beat from the "future" is a clock set back; the next real beat corrects it.
    return -HEARTBEAT_STALE < age < HEARTBEAT_STALE


def enqueue(text, source, key, where=None, links=None, cwd=None, blocks=None, reply=None):
    """Hand the turn to the agent. Write-then-rename so it never reads a partial file.

    The fields are the contract with Spool.drain in speak-hud.swift, pinned by
    tests/SpoolTests.swift: rename one here and that test fails. Changing what they
    mean means bumping `v` on both sides.
    """
    os.makedirs(QUEUE_DIR, exist_ok=True)
    # Zero-padded nanosecond prefix so a plain filename sort is arrival order; the
    # random tail keeps a same-instant tie between two terminals from clobbering.
    stem = f"{time.time_ns():019d}-{os.urandom(4).hex()}"
    tmp = os.path.join(QUEUE_DIR, stem + ".tmp")
    try:
        item = {"v": SPOOL_VERSION, "text": text, "source": source, "key": key,
                "created": time.time()}
        if where:
            item["origin"] = where
        if links:
            item["links"] = links
        if cwd:
            item["cwd"] = cwd
        if blocks:
            item["blocks"] = blocks
        if reply:
            item["reply"] = reply
        with open(tmp, "w") as f:
            json.dump(item, f)
        os.rename(tmp, os.path.join(QUEUE_DIR, stem + ".json"))
        return stem     # read-question.py watches for the agent to let go of it
    except OSError:
        # Don't leave a partial .tmp behind to accumulate; the agent ignores them,
        # but nothing else would ever clean them up.
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def pipe_to(argv, text):
    """Start argv and hand it `text` on stdin. False if it won't start, stops reading,
    or exits with an error straight away."""
    try:
        # Its output isn't ours to show, and holding our stdout/stderr open would make
        # the hook look busy until the speech ends.
        p = subprocess.Popen(argv, stdin=subprocess.PIPE,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError as e:    # missing, not executable, bad #! line
        print(f"speakhud: could not start {argv[0]} ({e})", file=sys.stderr)
        return False
    try:
        # "replace": a lone surrogate from the transcript shouldn't cost the whole turn.
        p.stdin.write(text.encode("utf-8", "replace"))
        p.stdin.close()
    except OSError as e:    # BrokenPipeError: it exited without reading
        print(f"speakhud: {argv[0]} stopped reading ({e})", file=sys.stderr)
        for step in (p.stdin.close, p.kill):
            try:
                step()
            except OSError:
                pass
        return False
    # A short turn fits in the pipe buffer, so a reader that dies at launch (dyld,
    # signature, crash) never raises BrokenPipe. Give it a moment to fail: exiting
    # non-zero in that window means it didn't take the turn; still running means it did.
    try:
        rc = p.wait(timeout=0.5)
    except subprocess.TimeoutExpired:
        return True
    if rc != 0:
        print(f"speakhud: {argv[0]} exited {rc} at launch", file=sys.stderr)
    return rc == 0


def speak_directly(text, source, where=None):
    """No agent to queue behind: read it here, as this hook used to. Never raises.

    `say` gets the text on stdin (`-f -`, per `man say`), never in argv: a turn that
    starts with "-" would otherwise be parsed as options.
    """
    hud = os.path.expanduser("~/.claude/bin/speak-hud")
    argv = [hud, "--source", source]
    if where:
        argv += ["--origin", json.dumps(where)]
    if os.path.exists(hud) and pipe_to(argv, text):
        return
    if not pipe_to(["say", "-f", "-"], text):
        print("speakhud: nothing could speak this turn", file=sys.stderr)


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

    text, fences = marked(text)
    text, spans, anchors = unmark(text)
    if not text:
        return

    cwd = data.get("cwd") or ""
    try:
        clickable, shown = links(text, spans, cwd), blocks(anchors, fences, cwd)
    except Exception as e:  # a classification bug shouldn't cost the turn its voice
        print(f"speakhud: could not mark links ({e})", file=sys.stderr)
        clickable, shown = [], []
    source = source_name(path, cwd)
    # Coalesce on the session, not the project: two terminals in the same repo are
    # two independent conversations and both deserve to be heard. The transcript is
    # per-session too, so it's the right fallback; `cwd` would merge those terminals
    # back together. `path` is non-empty here — main() returned early otherwise.
    key = data.get("session_id") or path
    where = origin()

    if agent_running():
        try:
            # A turn that has ended leaves its terminal at Claude's prompt, which is
            # where a spoken answer goes. (A question from read-question.py doesn't.)
            enqueue(text, source, key, where, clickable, cwd, shown, reply="prompt")
            return
        except OSError as e:
            # A full disk or an unwritable spool shouldn't mean silence.
            print(f"speakhud: could not queue turn ({e}); speaking directly", file=sys.stderr)
    speak_directly(text, source, where)


if __name__ == "__main__":
    main()
