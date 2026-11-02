#!/usr/bin/env python3
"""Real Codex adapter + installer, isolated from the user's config and speakers."""
import importlib.util
import json
import os
from pathlib import Path
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("setup_codex", REPO / "hook/setup-codex.py")
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="speakhud-codex-")
        self.home = Path(self.temp.name) / "codex home 'quoted'"
        self.home.mkdir()
        self.config = self.home / "config.toml"
        self.env = patch.dict(os.environ, CODEX_HOME=str(self.home))
        self.env.start()
        self.binary = Path(self.temp.name) / "speak-hud"
        self.binary.write_bytes(b"#!/bin/sh\nexit 0\n")

    def tearDown(self):
        self.env.stop()
        self.temp.cleanup()

    def run_setup(self, action):
        return setup.run(action, str(self.binary), REPO / "hook")

    def test_install_repair_remove_preserves_config(self):
        original = b'# custom formatting\r\nmodel = "test"\r\n[other]\r\nnotify = ["nested"]\r\n'
        self.config.write_bytes(original)
        self.config.chmod(0o600)
        self.assertEqual(self.run_setup("status"), "not installed")
        self.assertEqual(self.run_setup("install"), "installed")
        installed = self.config.read_bytes()
        self.assertTrue(installed.endswith(original))
        parsed = setup.tomllib.loads(installed.decode())
        self.assertEqual(parsed["other"]["notify"], ["nested"])
        self.assertEqual(parsed["notify"][1], str(self.home / "speakhud/read-codex.py"))
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.run_setup("status"), "installed")
        self.assertEqual(self.run_setup("install"), "installed")
        self.assertEqual(self.config.read_bytes(), installed)
        (self.home / "speakhud/read-summary.py").unlink()
        self.assertIn("read-summary.py missing", self.run_setup("status"))
        self.assertEqual(self.run_setup("install"), "installed")
        self.binary.write_bytes(b"new build")
        self.assertIn("binary differs", self.run_setup("status"))
        self.run_setup("install")
        self.assertEqual(self.run_setup("status"), "installed")
        self.assertEqual((self.home / "speakhud-config.toml.bak").read_bytes(), original)
        self.assertEqual(self.run_setup("remove"), "removed")
        self.assertEqual(self.config.read_bytes(), original)
        self.assertEqual(self.run_setup("remove"), "nothing to remove")

    def test_conflicting_notify_and_invalid_toml_are_untouched(self):
        for original in [b'notify = ["other",\n "notifier"] # keep\n', b'notify = []\n',
                         b'"notify" = ["other"]\n', b'broken = [\n',
                         b'notify = "wrong type"\n']:
            with self.subTest(original=original):
                self.config.write_bytes(original)
                with self.assertRaises(ValueError):
                    self.run_setup("install")
                self.assertEqual(self.config.read_bytes(), original)
                self.assertFalse((self.home / "speakhud").exists())

    def test_multiline_string_is_preserved(self):
        original = 'description = """\nnotify = ["a string, not a key"]\n"""\n'
        self.config.write_text(original)
        self.run_setup("install")
        self.assertEqual(self.run_setup("status"), "installed")
        self.run_setup("remove")
        self.assertEqual(self.config.read_text(), original)

    def test_missing_config_and_symlink(self):
        self.run_setup("install")
        self.assertEqual(self.run_setup("status"), "installed")
        self.run_setup("remove")
        self.assertEqual(self.config.read_bytes(), b"")
        self.config.unlink()
        target = self.home / "actual.toml"
        target.write_text('model = "test"\n')
        self.config.symlink_to(target)
        self.run_setup("install")
        self.assertTrue(self.config.is_symlink())
        self.run_setup("remove")
        self.assertTrue(self.config.is_symlink())
        self.assertEqual(target.read_text(), 'model = "test"\n')

    def test_modified_managed_block_is_not_removed(self):
        self.run_setup("install")
        text = self.config.read_text().replace("read-codex.py", "someone-else.py")
        self.config.write_text(text)
        self.assertEqual(self.run_setup("remove"), "nothing to remove")
        with self.assertRaises(ValueError):
            self.run_setup("install")
        self.assertEqual(self.config.read_text(), text)

    def test_block_below_a_key_codex_added_stays_ours(self):
        # Codex writes its own settings into config.toml, and one landed above the block
        # (10-21: project_doc_fallback_filenames). The block is still ours, where it is.
        original = b'model = "test"\n'
        self.config.write_bytes(original)
        self.assertEqual(self.run_setup("install"), "installed")
        added = b'project_doc_fallback_filenames = ["CLAUDE.md"]\n\n'
        self.config.write_bytes(added + self.config.read_bytes())
        self.assertEqual(self.run_setup("status"), "installed")
        self.binary.write_bytes(b"new build")
        self.assertIn("binary differs", self.run_setup("status"))
        self.assertEqual(self.run_setup("install"), "installed")
        repaired = self.config.read_text()
        self.assertEqual(repaired.count(setup.BEGIN), 1, "a repair replaces the block in place")
        self.assertTrue(repaired.startswith(added.decode()))
        self.assertEqual(setup.tomllib.loads(repaired)["project_doc_fallback_filenames"], ["CLAUDE.md"])
        self.assertEqual(self.run_setup("remove"), "removed")
        self.assertEqual(self.config.read_bytes(), added + original)

    def test_block_under_a_table_is_not_ours(self):
        # The same lines under a [table] set that table's notify, not Codex's.
        self.run_setup("install")
        moved = "[tools]\nx = 1\n" + self.config.read_text()
        self.config.write_text(moved)
        self.assertEqual(self.run_setup("status"), "not installed")
        self.assertEqual(self.run_setup("remove"), "nothing to remove")
        self.assertEqual(self.config.read_text(), moved)

    def test_missing_source_does_not_register(self):
        with self.assertRaises(OSError):
            setup.run("install", str(self.binary), self.home / "absent")
        self.assertFalse(self.config.exists())


class AdapterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sh-codex-", dir="/tmp")
        self.root = Path(self.temp.name)
        self.queue = self.root / "queue"
        self.queue.mkdir()
        (self.queue / "agent.heartbeat").touch()
        self.env = dict(os.environ, HOME=str(self.root), SPEAKHUD_QUEUE_DIR=str(self.queue),
                        CODEX_HOME=str(self.root / ".codex"),
                        SPEAKHUD_HEARTBEAT_GRACE="0", TERM_PROGRAM="iTerm.app",
                        ITERM_SESSION_ID="w4t0p0:41E78242-1234-5678-9012-123456789ABC")

    def tearDown(self):
        self.temp.cleanup()

    def notify(self, payload):
        result = subprocess.run([sys.executable, str(REPO / "hook/read-codex.py"),
                                 payload if isinstance(payload, str) else json.dumps(payload)],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")

    def payload(self, thread="one"):
        return {"type": "agent-turn-complete", "thread-id": thread, "cwd": str(REPO),
                "last-assistant-message": "**Done.** Run `git status`.\n\n```bash\ngit status\n```"}

    def items(self):
        return [json.loads(path.read_text()) for path in sorted(self.queue.glob("*.json"))]

    def test_queued_responses_keep_links_origin_and_session(self):
        self.notify(self.payload())
        self.notify(self.payload("two"))
        self.notify(self.payload())
        items = self.items()
        self.assertEqual([item["key"] for item in items], ["codex:one", "codex:two", "codex:one"])
        item = items[0]
        self.assertEqual(item["v"], 1)
        self.assertEqual(item["source"], "Codex · " + REPO.name)  # the folder, whatever a worktree calls it
        self.assertIn("Done. Run git status.", item["text"])
        self.assertNotIn("```", item["text"])
        self.assertTrue(any(link.get("run") == "git status" for link in item["links"]))
        self.assertEqual(item["blocks"][0]["code"].strip(), "git status")
        self.assertEqual(item["origin"]["session"], "41E78242-1234-5678-9012-123456789ABC")
        self.assertNotIn("reply", item)

    def test_blank_malformed_and_other_clients_are_ignored(self):
        for payload in ["{broken", "[]", "null", {}, {"type": "approval-requested"},
                        dict(self.payload(), **{"last-assistant-message": None}),
                        dict(self.payload(), **{"last-assistant-message": "```js\nlet x = 1;\n```"}),
                        dict(self.payload(), client="codex-desktop")]:
            self.notify(payload)
        self.assertEqual(self.items(), [])

    def test_missing_thread_does_not_coalesce(self):
        payload = self.payload()
        del payload["thread-id"]
        self.notify(payload)
        self.assertEqual(self.items()[0]["key"], "")

    def test_dead_agent_uses_own_binary(self):
        # Import with a sandbox HOME; replace process launch, so no speaker is touched.
        code = '''
import importlib.util, sys
spec = importlib.util.spec_from_file_location("adapter", sys.argv[1])
adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter)
adapter.reader.agent_running = lambda: False
adapter.reader.origin = lambda: {}
expected = "Codex · " + sys.argv[3]
def direct(text, source, where, hud):
    assert hud.endswith("/hook/speak-hud"), hud
    assert source == expected, source
adapter.reader.speak_directly = direct
sys.argv = [sys.argv[1], sys.argv[2]]
adapter.main()
'''
        result = subprocess.run([sys.executable, "-c", code, str(REPO / "hook/read-codex.py"),
                                 json.dumps(self.payload()), REPO.name], env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.items(), [])


class AgentTerminalTests(AdapterTests):
    old = "A6E47E00-0000-0000-0000-000000000001"
    here = "A6E47E00-0000-0000-0000-000000000002"
    other = "A6E47E00-0000-0000-0000-000000000003"

    inherited = None

    def notify(self, payload):
        if self.inherited is None:   # AdapterTests' own cases, run again by inheritance
            return super().notify(payload)
        # What a hook under the detached daemon sees, whichever shell runs the tests.
        code = '''
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("adapter", sys.argv[1])
adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter)
inherited = json.loads(sys.argv[2])
adapter.reader.origin = lambda: inherited
sys.argv = [sys.argv[0], sys.argv[3]]
adapter.main()
'''
        result = subprocess.run([sys.executable, "-c", code, str(REPO / "hook/read-codex.py"), json.dumps(self.inherited),
                                 json.dumps(payload)], env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def prepare(self, name="Fix the pill"):
        self.inherited = {"term": "AgentTerminal", "session": self.old, "app_pid": 44477}
        home = self.root / ".codex"
        home.mkdir()
        with sqlite3.connect(home / "state_5.sqlite") as db:
            db.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, name TEXT)")
            db.execute("INSERT INTO threads VALUES (?, ?)", ("one", name))
            db.execute("INSERT INTO threads VALUES (?, ?)", ("two", "Other conversation"))

    def pane(self, session, name):
        return {"session": session, "name": name + " | " + REPO.name,
                "color": "#12ab34", "screen": "private terminal text"}

    def with_panes(self, panes, action):
        # The adapter uses the real socket protocol, but never the user's app.
        path = self.root / "Library/Application Support/AgentTerminal/link.sock"
        path.parent.mkdir(parents=True, exist_ok=True)
        errors = []
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
            server.bind(str(path))
            server.listen(1)
            server.settimeout(3)
            def serve():
                try:
                    connection, _ = server.accept()
                    with connection:
                        connection.settimeout(3)
                        self.assertEqual(connection.recv(4096), b'{"op":"survey"}\n')
                        connection.sendall(json.dumps({"ok": True, "panes": panes}).encode() + b"\n")
                except Exception as error:
                    errors.append(error)
            worker = threading.Thread(target=serve)
            worker.start()
            try:
                action()
            finally:
                worker.join(4)
                path.unlink()
        self.assertFalse(worker.is_alive())
        self.assertEqual(errors, [])

    def test_daemon_uses_each_threads_live_pane_not_its_inherited_pane(self):
        self.prepare()
        panes = [self.pane(self.old, "Old conversation"),
                 self.pane(self.here, "⠧ Fix the pill"),
                 self.pane(self.other, "Other conversation")]
        self.with_panes(panes, lambda: self.notify(self.payload()))
        self.with_panes(panes, lambda: self.notify(self.payload("two")))
        self.assertEqual([item["origin"]["session"] for item in self.items()], [self.here, self.other])
        self.assertEqual(self.items()[0]["origin"]["color"], "#12ab34")
        self.assertNotIn("private terminal text", json.dumps(self.items()))

    def test_resumed_thread_and_renamed_thread_use_new_pane(self):
        self.prepare("Renamed conversation")
        self.with_panes([self.pane(self.other, "Renamed conversation")],
                        lambda: self.notify(self.payload()))
        self.assertEqual(self.items()[0]["origin"]["session"], self.other)

    def test_duplicate_names_never_choose_a_pane(self):
        self.prepare()
        self.with_panes([self.pane(self.here, "Fix the pill"), self.pane(self.other, "Fix the pill")],
                        lambda: self.notify(self.payload()))
        self.assertFalse(self.items()[0].get("origin"))

    def test_closed_pane_and_near_matches_never_use_daemon_origin(self):
        self.prepare()
        panes = [self.pane(self.old, "Fix the pill extra"), self.pane(self.here, "Fix the pill")]
        panes[1]["name"] += " extra"
        self.with_panes(panes, lambda: self.notify(self.payload()))
        self.assertFalse(self.items()[0].get("origin"))

    def test_unavailable_socket_still_queues_speech_without_stale_origin(self):
        self.prepare()
        self.notify(self.payload())
        self.assertIn("Done.", self.items()[0]["text"])
        self.assertFalse(self.items()[0].get("origin"))

    def test_unavailable_database_still_queues_speech_without_stale_origin(self):
        self.inherited = {"term": "AgentTerminal", "session": self.old, "app_pid": 44477}
        self.notify(self.payload())
        self.assertFalse(self.items()[0].get("origin"))

    def test_unnamed_thread_matches_the_bare_folder_title(self):
        self.prepare(None)
        pane = dict(self.pane(self.here, "x"), name="⠹ " + REPO.name)
        named = self.pane(self.other, "Other conversation")
        self.with_panes([pane, named], lambda: self.notify(self.payload()))
        self.assertEqual(self.items()[0]["origin"]["session"], self.here)

    def test_two_unnamed_threads_in_one_folder_never_choose_a_pane(self):
        self.prepare(None)
        panes = [dict(self.pane(s, "x"), name=REPO.name) for s in (self.here, self.other)]
        self.with_panes(panes, lambda: self.notify(self.payload()))
        self.assertFalse(self.items()[0].get("origin"))

    def test_named_thread_never_takes_a_bare_folder_title(self):
        self.prepare()
        pane = dict(self.pane(self.here, "x"), name=REPO.name)
        self.with_panes([pane], lambda: self.notify(self.payload()))
        self.assertFalse(self.items()[0].get("origin"))

    def test_daemon_started_in_iterm_still_finds_the_agent_terminal_pane(self):
        self.prepare()
        self.inherited = {"term": "iTerm.app", "session": "41E78242-1234-5678-9012-123456789ABC"}
        self.with_panes([self.pane(self.here, "Fix the pill")], lambda: self.notify(self.payload()))
        self.assertEqual(self.items()[0]["origin"]["session"], self.here)

    def test_daemon_started_in_iterm_keeps_its_origin_with_no_matching_pane(self):
        self.prepare()
        self.inherited = {"term": "iTerm.app", "session": "41E78242-1234-5678-9012-123456789ABC"}
        self.notify(self.payload())
        self.assertEqual(self.items()[0]["origin"]["session"], self.inherited["session"])

    def test_cli_with_its_own_tty_keeps_its_own_pane(self):
        self.prepare()
        self.inherited = dict(self.inherited, tty="/dev/ttys009")
        self.notify(self.payload())
        self.assertEqual(self.items()[0]["origin"]["session"], self.old)


if __name__ == "__main__":
    unittest.main()
