#!/usr/bin/env python3
"""Install the notify adapter without reformatting the user's Codex config.

Python 3.11+ supplies tomllib. Parsing the whole config before editing avoids
mistaking a nested notify key, multiline string, or comment for a root setting.
Only our exact managed block can be removed. An existing notifier is preserved.
"""
import json
import os
from pathlib import Path
import stat
import sys
import tempfile

try:
    import tomllib
except ImportError:
    print("error: Codex setup needs Python 3.11 or later (brew install python)")
    sys.exit(1)

BEGIN = "# SpeakHUD Codex CLI — begin\n"
END = "# SpeakHUD Codex CLI — end\n"
SCRIPTS = ("read-codex.py", "read-summary.py", "setup-codex.py")


def atomic_write(path, data, mode):
    path = path.resolve()  # keep a user's symlink intact
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".speakhud-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            os.fchmod(stream.fileno(), mode)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def run(action, binary=None, sources=None):
    home = Path(os.environ.get("CODEX_HOME") or "~/.codex").expanduser().absolute()
    config = home / "config.toml"
    install = home / "speakhud"
    sources = Path(sources or Path(__file__).parent)
    original = config.read_bytes() if config.exists() else b""
    text = original.decode("utf-8")
    root = tomllib.loads(text)
    command = [sys.executable, str(install / "read-codex.py")]
    block = BEGIN + "notify = " + json.dumps(command, ensure_ascii=False) + "\n" + END
    # Ownership requires both markers at the start, one notify setting, and our
    # exact script path. Never remove a notifier just because its name looks ours.
    owned = None
    if text.startswith(BEGIN) and END in text:
        end = text.index(END) + len(END)
        candidate = text[:end]
        parsed = tomllib.loads(candidate[len(BEGIN):-len(END)])
        notify = parsed.get("notify")
        if (set(parsed) == {"notify"} and isinstance(notify, list)
                and len(notify) == 2 and notify[1] == command[1]
                and root.get("notify") == notify):
            owned = candidate

    if action == "status":
        if owned is None:
            return "not installed" + (": another notify command is configured" if "notify" in root else "")
        problems = []
        for name in SCRIPTS:
            target, source = install / name, sources / name
            if not target.is_file():
                problems.append(name + " missing")
            elif source.is_file() and target.read_bytes() != source.read_bytes():
                problems.append(name + " differs from bundled copy")
        target = install / "speak-hud"
        if not os.access(target, os.X_OK):
            problems.append("binary missing")
        elif binary and target.read_bytes() != Path(binary).read_bytes():
            problems.append("binary differs from this build")
        if root["notify"] != command:
            problems.append("Python interpreter changed")
        return "stale: " + "; ".join(problems) if problems else "installed"

    if action == "remove":
        if owned is None:
            return "nothing to remove"
        updated = text[len(owned):]
    elif action == "install":
        if "notify" in root and owned is None:
            raise ValueError(f"{config} already has a notify command; left it untouched")
        if not binary or not Path(binary).is_file():
            raise ValueError("could not locate the SpeakHUD executable")
        # Validate all sources before copying any of them or registering the hook.
        payloads = [(install / name, (sources / name).read_bytes(), 0o644) for name in SCRIPTS]
        payloads.append((install / "speak-hud", Path(binary).read_bytes(), 0o755))
        updated = block + (text[len(owned):] if owned else text)
        tomllib.loads(updated)
        for path, data, mode in payloads:
            atomic_write(path, data, mode)
    else:
        raise ValueError("expected install, remove, or status")

    encoded = updated.encode("utf-8")
    if encoded != original:
        # One original backup per installation; never replace it on repair.
        backup = home / "speakhud-config.toml.bak"
        if action == "install" and not backup.exists():
            atomic_write(backup, original, 0o600)
        # Refuse to clobber an edit made while we were copying files.
        current = config.read_bytes() if config.exists() else b""
        if current != original:
            raise ValueError("Codex config changed during setup; retry")
        mode = stat.S_IMODE(config.stat().st_mode) if config.exists() else 0o600
        atomic_write(config, encoded, mode)
    return "installed" if action == "install" else "removed"


if __name__ == "__main__":
    try:
        print(run(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None))
    except (OSError, ValueError, IndexError) as error:
        print(f"error: {error}")
        sys.exit(1)
