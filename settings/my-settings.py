#!/usr/bin/env python3
"""Keep Chris's SpeakHUD settings in this repo and put them on another Mac.

  python3 settings/my-settings.py install            fill in anything not set yet
  python3 settings/my-settings.py install --force    overwrite what is set
  python3 settings/my-settings.py install --claude   also turn on reading Claude replies aloud
  python3 settings/my-settings.py save               copy this Mac's settings into the repo

--claude is opt-in: on a Mac that runs agents it would read every agent's turn aloud.
Pairing keys (~/.config/speakhud/phone.json) are never saved; a Mac pairs on its own.
Add --dry-run to see what would change. SETTINGS_DOMAIN points at a test domain.
"""
import json, os, plistlib, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
FILE = os.path.join(HERE, "defaults.json")
DOMAIN = os.environ.get("SETTINGS_DOMAIN", "com.chris.speakhud.shared")
KEYS = ["readTurns", "listenAfterReading", "listenWhileReading", "speakRateIndex",
        "voicePerProject", "waitWhileAudioPlays", "pauseWhileRecording"]
HOTKEY = os.path.expanduser("~/.config/speakhud/config.json")
LABEL = "com.chris.speakhud.agent"


def current():
    out = subprocess.run(["defaults", "export", DOMAIN, "-"], capture_output=True)
    return plistlib.loads(out.stdout) if out.returncode == 0 and out.stdout else {}


def write(key, value):
    kind = {bool: "-bool", int: "-int", float: "-float", str: "-string"}[type(value)]
    text = str(value).lower() if isinstance(value, bool) else str(value)
    subprocess.run(["defaults", "write", DOMAIN, key, kind, text], check=True)


def app():
    for root in ("/Applications", os.path.expanduser("~/Applications")):
        path = root + "/SpeakHUD.app/Contents/MacOS/speak-hud"
        if os.path.exists(path):
            return path


def save():
    have = current()
    data = {"prefs": {k: have[k] for k in KEYS if k in have}}
    if os.path.exists(HOTKEY):
        data["hotkey"] = json.load(open(HOTKEY)).get("hotkey")
    with open(FILE, "w") as f:
        json.dump(data, f, indent=2, sort_keys=True)
        f.write("\n")
    print("saved %d settings to %s" % (len(data["prefs"]), FILE))


def install(force, claude, dry):
    data = json.load(open(FILE))
    binary = app()
    if not binary and not dry and "SETTINGS_DOMAIN" not in os.environ:
        sys.exit("SpeakHUD isn't installed yet: run ./build.sh from a terminal first.")
    have = current()
    for key, value in sorted(data["prefs"].items()):
        if key in have and not force:
            print("kept   %s = %s (--force overwrites)" % (key, have[key]))
            continue
        print("set    %s = %s" % (key, value))
        if not dry:
            write(key, value)
    if dry or "SETTINGS_DOMAIN" in os.environ:
        return
    if data.get("hotkey"):
        subprocess.run([binary, "--set-hotkey", data["hotkey"]], check=True)
    if claude:
        subprocess.run([binary, "--setup-claude"], check=True)
    subprocess.run(["launchctl", "kickstart", "-k", "gui/%d/%s" % (os.getuid(), LABEL)])


if __name__ == "__main__":
    args = sys.argv[1:]
    if args[:1] == ["save"]:
        save()
    elif args[:1] == ["install"]:
        install("--force" in args, "--claude" in args, "--dry-run" in args)
    else:
        sys.exit(__doc__)
