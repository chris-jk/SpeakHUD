#!/usr/bin/env python3
"""Real Codex adapter + installer, isolated from the user's config and speakers."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
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

    def test_missing_source_does_not_register(self):
        with self.assertRaises(OSError):
            setup.run("install", str(self.binary), self.home / "absent")
        self.assertFalse(self.config.exists())


class AdapterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="speakhud-codex-adapter-")
        self.root = Path(self.temp.name)
        self.queue = self.root / "queue"
        self.queue.mkdir()
        (self.queue / "agent.heartbeat").touch()
        self.env = dict(os.environ, HOME=str(self.root), SPEAKHUD_QUEUE_DIR=str(self.queue),
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
        self.assertEqual(item["source"], "Codex · speakhud")
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
def direct(text, source, where, hud):
    assert hud.endswith("/hook/speak-hud"), hud
    assert source == "Codex · speakhud", source
adapter.reader.speak_directly = direct
sys.argv = [sys.argv[1], sys.argv[2]]
adapter.main()
'''
        result = subprocess.run([sys.executable, "-c", code, str(REPO / "hook/read-codex.py"),
                                 json.dumps(self.payload())], env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.items(), [])


if __name__ == "__main__":
    unittest.main()
