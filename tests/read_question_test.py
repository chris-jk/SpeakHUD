#!/usr/bin/env python3
"""Runs the REAL hook/read-question.py against a temp spool and a fake HUD that takes
each item, "speaks" it for SPEAK seconds and lets go of its file, as the agent does.
HOME and PATH point into the temp dir, so a fall-through to speaking directly hits a
stub `say` that logs instead of the real voice."""
import glob, json, os, shutil, subprocess, sys, tempfile, threading, time, unittest
from datetime import datetime, timezone

HOOK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "hook", "read-question.py")
PAUSE, SPEAK = 0.6, 0.3
# Stand in for afplay and say: log the call instead of making a sound.
STUB = "#!/bin/sh\npython3 -c 'import time; print(time.time())' >> \"{log}\"\n"


class FakeHUD(threading.Thread):
    def __init__(self, queue, log):
        super().__init__(daemon=True)
        self.queue, self.log = queue, log
        self.heard, self.started, self.items = [], [], []
        self.running, self.paused, self.stop_next = True, False, False

    def run(self):
        while self.running:
            os.utime(os.path.join(self.queue, "agent.heartbeat"))  # as the agent does, every beat
            for f in [] if self.paused else sorted(glob.glob(os.path.join(self.queue, "*.json"))):
                taken = f[:-5] + ".taken"
                os.rename(f, taken)
                with open(taken) as fh:
                    item = json.load(fh)
                start = time.time()
                self.started.append(item["text"])
                self.items.append(item)
                time.sleep(SPEAK)
                if self.stop_next:  # you pressed Stop: logged, every file let go
                    self.stop_next = False
                    with open(self.log, "a") as fh:
                        ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
                        fh.write(f"[{ts}] stop: discarded 0 queued item(s)\n")
                    os.unlink(taken)
                    break
                os.unlink(taken)
                self.heard.append((item["text"], item["key"], start, time.time()))
            time.sleep(0.02)


def question(text, *options, multi=False):
    return {"question": text, "header": "H", "multiSelect": multi,
            "options": [{"label": l, "description": d} for l, d in options]}


class ReadQuestion(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.queue = os.path.join(self.tmp, "state", "queue")
        os.makedirs(self.queue)
        open(os.path.join(self.queue, "agent.heartbeat"), "w").close()
        self.transcript = os.path.join(self.tmp, "t.jsonl")
        open(self.transcript, "w").close()
        self.chimes, self.said = os.path.join(self.tmp, "chimes"), os.path.join(self.tmp, "said")
        bin_ = os.path.join(self.tmp, "bin")
        os.makedirs(bin_)
        for name, log in (("player", self.chimes), ("say", self.said)):
            p = os.path.join(bin_, name)
            with open(p, "w") as f:
                f.write(STUB.format(log=log))
            os.chmod(p, 0o755)
        self.player = os.path.join(bin_, "player")
        self.env = dict(os.environ, HOME=self.tmp, PATH=bin_ + ":/usr/bin:/bin",
                        SPEAKHUD_QUEUE_DIR=self.queue, SPEAKHUD_HEARTBEAT_GRACE="0",
                        READQ_PAUSE=str(PAUSE), READQ_PLAYER=self.player, READQ_CHIME=self.chimes,
                        READQ_AGENT_LOG=os.path.join(self.tmp, "agent.log"))
        self.hud = FakeHUD(self.queue, self.env["READQ_AGENT_LOG"])
        self.hud.start()

    def tearDown(self):
        self.hud.running = False
        self.hud.join()
        self.assertFalse(os.path.exists(self.said), "a test fell through to speaking directly")
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_hook(self, data, *args, wait=True):
        p = subprocess.Popen([sys.executable, HOOK, *args], stdin=subprocess.PIPE, env=self.env)
        p.stdin.write(json.dumps(data).encode())
        p.stdin.close()
        if wait:
            self.assertEqual(p.wait(timeout=20), 0)
            self.drain()
        return p

    def ask(self, *questions, wait=True, tool_id="tu1", session="s1", flushed=True):
        if flushed:  # Claude Code has written this call to the transcript
            with open(self.transcript, "a") as f:
                f.write(json.dumps({"type": "assistant", "message": {"content": [
                    {"type": "tool_use", "id": tool_id, "name": "AskUserQuestion"}]}}) + "\n")
        data = {"session_id": session, "cwd": self.tmp, "transcript_path": self.transcript,
                "tool_name": "AskUserQuestion", "tool_use_id": tool_id,
                "tool_input": {"questions": list(questions)}}
        if session is None:
            del data["session_id"]
        return self.run_hook(data, wait=wait)

    def answer(self, tool_id="tu1"):
        self.run_hook({"session_id": "s1", "tool_use_id": tool_id, "tool_name": "AskUserQuestion"},
                      "--answered")

    def drain(self):
        """The hook exits once its last item is queued; let the HUD finish speaking it."""
        deadline = time.time() + 10
        while glob.glob(os.path.join(self.queue, "*.json")) + glob.glob(os.path.join(self.queue, "*.taken")):
            self.assertLess(time.time(), deadline, "the HUD never drained the spool")
            time.sleep(0.02)

    def until(self, cond, what):
        deadline = time.time() + 10
        while not cond():
            self.assertLess(time.time(), deadline, what)
            time.sleep(0.02)

    def chime_times(self):
        if not os.path.exists(self.chimes):
            return []
        with open(self.chimes) as f:
            return [float(l) for l in f]

    def texts(self):
        return [h[0] for h in self.hud.heard]

    def test_question_then_pause_then_options(self):
        self.ask(question("Which **method**?", ("OAuth (Recommended)", "Safer."), ("Key", "Simpler.")))
        self.assertEqual(self.texts(), ["Which method?", "1. OAuth (Recommended). Safer.\n2. Key. Simpler."])
        gap = self.hud.heard[1][2] - self.hud.heard[0][3]
        self.assertGreaterEqual(gap, PAUSE, "the options wait out the pause after the question ends")
        self.assertEqual({h[1] for h in self.hud.heard}, {"s1:question"},
                         "its own key, so it never replaces the session's spoken reply")
        self.assertEqual([i.get("reply") for i in self.hud.items], [None, None],
                         "a question isn't a turn at Claude's prompt: no mic opens to answer it there")
        self.assertEqual(os.listdir(os.path.join(self.tmp, "state", "questions")), [], "marker released")

    def test_answering_stops_the_options(self):
        p = self.ask(question("Ship it?", ("Yes", ""), ("No", "")), wait=False)
        self.until(lambda: self.hud.started, "the question never started")
        self.answer()
        self.assertEqual(p.wait(timeout=20), 0)
        self.drain()
        self.assertEqual(self.texts(), ["Ship it?"], "answered: no options after it")

    def test_another_questions_answer_doesnt_stop_this_one(self):
        p = self.ask(question("Ship it?", ("Yes", ""), ("No", "")), wait=False)
        self.until(lambda: self.hud.started, "the question never started")
        self.answer(tool_id="other")
        self.assertEqual(p.wait(timeout=20), 0)
        self.drain()
        self.assertEqual(self.texts(), ["Ship it?", "1. Yes.\n2. No."])

    def test_stop_silences_the_options(self):
        self.hud.stop_next = True
        self.ask(question("Ship it?", ("Yes", ""), ("No", "")))
        self.assertEqual(self.hud.started, ["Ship it?"], "Stop on the question: nothing more")

    def test_chime_once_right_before_the_question(self):
        self.ask(question("First?", ("A", ""), ("B", "")), question("Second?", ("C", ""), ("D", "")))
        [chimed] = self.chime_times()
        self.assertLessEqual(chimed, self.hud.heard[0][2], "the chime comes before the question")

    def test_chime_waits_for_whatever_is_being_read(self):
        with open(os.path.join(self.queue, "0-busy.json"), "w") as f:
            json.dump({"v": 1, "text": "A long answer.", "source": "x", "key": "other"}, f)
        self.ask(question("Now?", ("A", ""), ("B", "")))
        self.assertEqual(self.texts()[0], "A long answer.")
        [chimed] = self.chime_times()
        self.assertGreaterEqual(chimed, self.hud.heard[0][3], "no chime over another item")

    def test_a_question_that_waits_too_long_gives_up(self):
        self.hud.paused = True
        with open(os.path.join(self.queue, "0-busy.json"), "w") as f:
            json.dump({"v": 1, "text": "Held.", "source": "x", "key": "other"}, f)
        self.env["READQ_MAX_WAIT"] = "0.5"
        p = self.ask(question("Now?", ("A", ""), ("B", "")), wait=False)
        self.assertEqual(p.wait(timeout=20), 0)
        self.assertEqual(sorted(os.listdir(self.queue)), ["0-busy.json", "agent.heartbeat"],
                         "nothing queued after the wait ran out")
        self.assertEqual(self.chime_times(), [], "and no chime")
        self.hud.paused = False

    def test_text_written_before_asking_leads_the_question(self):
        p = self.ask(question("Ship it?", ("Yes", ""), ("No", "")), wait=False, flushed=False)
        time.sleep(0.3)  # the hook got here before the transcript was flushed
        with open(self.transcript, "w") as f:
            f.write(json.dumps({"type": "user", "message": {"content": "go"}}) + "\n")
            f.write(json.dumps({"type": "assistant", "message": {"content": [
                {"type": "text", "text": "Two to settle."},
                {"type": "tool_use", "id": "tu1", "name": "AskUserQuestion"}]}}) + "\n")
        self.assertEqual(p.wait(timeout=20), 0)
        self.drain()
        self.assertEqual(self.texts(), ["Two to settle.\n\nShip it?", "1. Yes.\n2. No."])

    def test_multi_select_says_so(self):
        self.ask(question("Which?", ("A", ""), ("B", ""), multi=True))
        self.assertTrue(self.texts()[1].startswith("Pick any that apply.\n1. A."))

    def test_several_questions_in_one_call_read_in_order(self):
        self.ask(question("First?", ("A", ""), ("B", "")), question("Second?", ("C", ""), ("D", "")))
        self.assertEqual(self.texts(),
                         ["Question 1 of 2. First?", "1. A.\n2. B.", "Question 2 of 2. Second?", "1. C.\n2. D."])

    def test_a_newer_question_drops_the_older_ones_options(self):
        old = self.ask(question("Old?", ("A", ""), ("B", "")), wait=False, tool_id="tu1")
        self.until(lambda: "Old?" in self.hud.started, "the old question never started")
        self.ask(question("New?", ("C", ""), ("D", "")), tool_id="tu2")
        self.assertEqual(old.wait(timeout=20), 0)
        self.drain()
        self.assertNotIn("1. A.\n2. B.", self.texts())
        self.assertEqual(self.texts()[-2:], ["New?", "1. C.\n2. D."])
        self.assertEqual(len(self.chime_times()), 2, "one chime per question")

    def test_a_superseded_hook_never_chimes(self):
        self.hud.paused = True
        with open(os.path.join(self.queue, "0-busy.json"), "w") as f:
            json.dump({"v": 1, "text": "Held.", "source": "x", "key": "other"}, f)
        old = self.ask(question("Old?", ("A", ""), ("B", "")), wait=False, tool_id="tu1")
        time.sleep(0.5)  # the old hook is waiting for the spool to empty
        new = self.ask(question("New?", ("C", ""), ("D", "")), wait=False, tool_id="tu2")
        self.assertEqual(old.wait(timeout=20), 0)
        self.assertEqual(self.chime_times(), [], "the old hook left without a chime")
        self.hud.paused = False
        self.assertEqual(new.wait(timeout=20), 0)
        self.drain()
        self.assertEqual(self.texts(), ["Held.", "New?", "1. C.\n2. D."])

    def test_no_session_id_still_reads(self):
        self.ask(question("Ship it?", ("Yes", ""), ("No", "")), session=None)
        self.assertEqual(self.texts(), ["Ship it?", "1. Yes.\n2. No."],
                         "the transcript path stands in for the key, slashes and all")


if __name__ == "__main__":
    unittest.main(verbosity=1)
