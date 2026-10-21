#!/usr/bin/env python3
"""Codex CLI notify adapter. The shared reader lives beside this file."""
import importlib.util
import json
import os
import sys

spec = importlib.util.spec_from_file_location(
    "read_summary", os.path.join(os.path.dirname(__file__), "read-summary.py"))
reader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reader)


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
    where = reader.origin()
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
