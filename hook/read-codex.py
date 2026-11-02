#!/usr/bin/env python3
"""Codex CLI notify adapter. The shared reader lives beside this file."""
import importlib.util
import json
import os
from pathlib import Path
import re
import socket
import sqlite3
import sys

spec = importlib.util.spec_from_file_location(
    "read_summary", os.path.join(os.path.dirname(__file__), "read-summary.py"))
reader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reader)


def thread_name(thread):
    """Read Codex's current conversation name, including a user's rename."""
    if not isinstance(thread, str) or not thread:
        return None
    home = Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex")
    # Read-only: a missing/newer database must not create one or break speech.
    try:
        with sqlite3.connect((home / "state_5.sqlite").as_uri() + "?mode=ro",
                             uri=True, timeout=0.2) as db:
            row = db.execute("SELECT name FROM threads WHERE id = ?", (thread,)).fetchone()
        return row[0] if row and isinstance(row[0], str) and row[0].strip() else None
    except (OSError, ValueError, sqlite3.Error):
        return None


def agent_panes():
    """Read the same private socket used by SpeakHUD's Reveal and Reply."""
    path = Path.home() / "Library/Application Support/AgentTerminal/link.sock"
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(0.3)
        connection.connect(str(path))
        connection.sendall(b'{"op":"survey"}\n')
        data = bytearray()
        while not data.endswith(b"\n"):
            chunk = connection.recv(65536)
            if not chunk or len(data) + len(chunk) > 4 * 1024 * 1024:
                return []
            data.extend(chunk)
        reply = json.loads(data)
        return reply.get("panes", []) if isinstance(reply, dict) and reply.get("ok") else []


def terminal_origin(thread, cwd, inherited):
    """A shared Codex daemon inherits the FIRST TUI's terminal, not this one's.

    Direct CLI hooks still have a tty and can use their own ancestry. A detached
    hook matches the thread's name and folder against Agent Terminal's live OSC
    window titles, whichever terminal happened to start the daemon. No match keeps an
    iTerm2 daemon's origin, but never Agent Terminal's: its panes close for good.
    Never choose between duplicate names. No terminal contents are persisted.
    """
    if inherited.get("tty"):
        return inherited
    fallback = {} if inherited.get("term") == "AgentTerminal" else inherited
    # Until Codex names a thread, its pane's title is only the folder.
    folder = os.path.basename(cwd.rstrip("/")) or "/"
    name = thread_name(thread)
    expected = name + " | " + folder if name else folder
    try:
        matches = []
        for pane in agent_panes():
            if not isinstance(pane, dict):
                continue
            title = pane.get("name", "")
            session = pane.get("session", "")
            if not isinstance(title, str) or not isinstance(session, str):
                continue
            # Codex prefixes its OSC title with a braille spinner while working.
            title = re.sub(r"^[\u2800-\u28ff]\s+", "", title)
            if title == expected and re.fullmatch(
                    r"A6E47E00-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}", session):
                matches.append(pane)
        if len(matches) == 1:
            origin = {"term": "AgentTerminal", "session": matches[0]["session"].upper()}
            color = matches[0].get("color")
            if isinstance(color, str) and re.fullmatch(r"#[0-9a-fA-F]{6}", color):
                origin["color"] = color
            return origin
    except (OSError, ValueError, TypeError):
        pass
    return fallback


def main():
    try:
        data = json.loads(sys.argv[1])
    except (IndexError, ValueError):
        return
    if not isinstance(data, dict) or data.get("type") != "agent-turn-complete":
        return
    # Some clients share Codex's user config. Speak only for the CLI; older CLI
    # notifications have no client field.
    if data.get("client") not in (None, "codex-tui"):
        return
    raw = data.get("last-assistant-message")
    if not isinstance(raw, str) or not raw.strip():
        return
    text, fences = reader.marked(raw)
    text, spans, anchors = reader.unmark(text)
    if not text:
        return
    cwd = data.get("cwd") if isinstance(data.get("cwd"), str) else ""
    try:
        clickable = reader.links(text, spans, cwd)
        shown = reader.blocks(anchors, fences, cwd)
    except Exception as error:
        print(f"speakhud: could not mark Codex links ({error})", file=sys.stderr)
        clickable, shown = [], []
    source = "Codex · " + (os.path.basename(cwd.rstrip("/")) or "CLI")
    thread = data.get("thread-id")
    # No thread id means no coalescing: never merge unrelated unknown sessions.
    key = "codex:" + thread if isinstance(thread, str) and thread else ""
    where = terminal_origin(thread, cwd, reader.origin())
    if reader.agent_running():
        try:
            # No reply="prompt": voice/phone replies currently recognize Claude's
            # prompt only. A Codex turn must never opt into that input path.
            reader.enqueue(text, source, key, where, clickable, cwd, shown)
            return
        except OSError as error:
            print(f"speakhud: could not queue Codex turn ({error})", file=sys.stderr)
    reader.speak_directly(text, source, where,
                          hud=os.path.join(os.path.dirname(__file__), "speak-hud"))


if __name__ == "__main__":
    main()
