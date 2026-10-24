#!/usr/bin/env python3
# Tests for suite: the machine-wide slot lock, exit codes, and the KNOWN/NEW
# red summary. SUITE_DIR, SUITE_LOG_DIR and TASKLOG_DIR keep every lock, log
# and DB in a temp dir.
#
#   python3 scripts/.local/bin/test_suite.py
import os
import re
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest

BIN = os.path.dirname(os.path.abspath(__file__))
SUITE = os.path.join(BIN, "suite")


def git(*argv):
    subprocess.run(["git", *argv], check=True, capture_output=True)


class Case(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.core = os.path.realpath(os.path.join(cls.tmp.name, "core"))
        git("init", "-q", "-b", "main", cls.core)
        git("-C", cls.core, "remote", "add", "origin", "https://github.com/CloudKey-io/core.git")
        git("-C", cls.core, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init")

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def setUp(self):
        d = tempfile.TemporaryDirectory()
        self.addCleanup(d.cleanup)
        self.dir = d.name
        self.locks = os.path.join(self.dir, "locks")
        self.logs = os.path.join(self.dir, "logs")
        self.env = dict(os.environ, SUITE_DIR=self.locks, SUITE_LOG_DIR=self.logs,
                        TASKLOG_DIR=os.path.join(self.dir, "db"), SUITE_SLOTS="1")
        self.slot = os.path.join(self.locks, "slot-0")

    def start(self, *argv, cwd=None, env=None, **kw):
        e = dict(self.env, **(env or {}))
        e = {k: v for k, v in e.items() if v is not None}
        return subprocess.Popen([SUITE, *argv], cwd=cwd or self.core, env=e, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, **kw)

    def suite(self, *argv, **kw):
        p = self.start(*argv, **kw)
        out = p.communicate(timeout=60)[0].decode("utf-8", "replace")
        return p.returncode, out

    def pair(self, env=None):
        """Two concurrent `suite sleep 2` runs; returns the wall seconds and both outputs."""
        t = time.monotonic()
        a = self.start("sleep", "2", env=env)
        time.sleep(0.3)
        b = self.start("sleep", "2", env=env)
        outs = [p.communicate(timeout=30)[0].decode() for p in (a, b)]
        return time.monotonic() - t, outs

    def dead_pid(self):
        p = subprocess.Popen(["true"])
        p.wait()
        return p.pid

    def hold(self, holder=None, old=False):
        os.makedirs(self.slot, exist_ok=True)
        if holder is not None:
            with open(os.path.join(self.slot, "holder"), "w") as f:
                f.write(holder)
        if old:
            os.utime(self.slot, (0, 0))

    def runs(self):
        db = sqlite3.connect(os.path.join(self.env["TASKLOG_DIR"], "ck.db"))
        db.row_factory = sqlite3.Row
        self.addCleanup(db.close)
        return db.execute("SELECT * FROM suite_runs ORDER BY id").fetchall()


class Lock(Case):
    def test_two_runs_take_turns_at_n1_and_the_waiter_names_the_holder(self):
        wall, outs = self.pair()
        self.assertGreaterEqual(wall, 4)
        waiter = next(o for o in outs if "held by" in o)
        self.assertRegex(waiter, r"pid \d+ +core main +sleep 2 +since ")
        waits = sorted(r["wait_ms"] for r in self.runs())
        self.assertLess(waits[0], 1000)
        self.assertGreaterEqual(waits[1], 1000)
        self.assertIn(f"waited {waits[1] // 1000}s", waiter)

    def test_two_runs_overlap_at_n2_and_leave_no_slot_held(self):
        wall, _ = self.pair(env={"SUITE_SLOTS": "2"})
        self.assertLess(wall, 4)
        self.assertEqual(os.listdir(self.locks), [])

    def test_the_slots_file_sets_n_and_n_defaults_to_1(self):
        home = os.path.join(self.dir, "home")
        os.makedirs(os.path.join(home, ".config/suite"))
        with open(os.path.join(home, ".config/suite/slots"), "w") as f:
            f.write("2\n")
        self.assertLess(self.pair(env={"SUITE_SLOTS": None, "HOME": home})[0], 4)
        empty = os.path.join(self.dir, "empty-home")
        os.makedirs(empty)
        self.assertGreaterEqual(self.pair(env={"SUITE_SLOTS": None, "HOME": empty})[0], 4)

    def test_a_zero_slot_count_is_refused(self):
        self.assertEqual(self.suite("true", env={"SUITE_SLOTS": "0"})[0], 64)

    def test_a_bare_suite_exits_64_and_takes_no_slot(self):
        self.assertEqual(self.suite()[0], 64)
        self.assertFalse(os.path.exists(self.slot))

    def test_an_uncontended_run_reports_waited_0s(self):
        # Whole-second clocks read either side of a boundary would say 1s.
        late = [out for out in (self.suite("true")[1] for _ in range(300)) if "waited 0s" not in out]
        self.assertEqual(late, [])


class Takeover(Case):
    def test_a_dead_holders_slot_is_taken_over(self):
        dead = self.dead_pid()
        self.hold(f"pid={dead}\nrepo=core\ncmd=npm test\n")
        t = time.monotonic()
        code, out = self.suite("true")
        self.assertLess(time.monotonic() - t, 3)
        self.assertIn(f"dead pid {dead}", out)

    def test_a_young_takeover_guard_is_left_alone_and_an_old_one_cleared(self):
        dead = self.dead_pid()
        self.hold(f"pid={dead}\n")
        guard = self.slot + ".takeover"
        os.makedirs(guard)
        p = self.start("true")
        time.sleep(3)
        self.assertIsNone(p.poll())
        self.assertTrue(os.path.isdir(guard))
        os.utime(guard, (0, 0))
        t = time.monotonic()
        out = p.communicate(timeout=10)[0].decode()
        self.assertLess(time.monotonic() - t, 5)
        self.assertIn(f"dead pid {dead}", out)
        self.assertFalse(os.path.exists(guard))

    def test_a_holderless_slot_is_left_alone_while_young(self):
        self.hold()
        p = self.start("true")
        time.sleep(3)
        self.assertIsNone(p.poll())
        self.assertFalse(os.path.exists(os.path.join(self.slot, "holder")))
        os.rmdir(self.slot)
        self.assertIn("suite: exit 0", p.communicate(timeout=10)[0].decode())

    def test_an_old_holderless_slot_is_taken_over(self):
        self.hold(old=True)
        self.assertIn("no holder", self.suite("true")[1])


class Run(Case):
    def test_the_exit_code_passes_through_and_the_summary_names_it(self):
        code, out = self.suite("sh", "-c", "exit 3")
        self.assertEqual(code, 3)
        self.assertIn("suite: exit 3, 0 new, 0 known, waited 0s", out)

    def test_a_missing_command_exits_127_and_frees_the_slot(self):
        self.assertEqual(self.suite("no-such-command-xyz")[0], 127)
        self.assertFalse(os.path.exists(self.slot))

    def test_a_non_utf8_byte_keeps_the_exit_reds_and_summary(self):
        code, out = self.suite("sh", "-c", r'printf "ok \377\n FAIL  test/latin.test.js > caf\351\n"; exit 3',
                               env={"LANG": "en_US.UTF-8"})
        self.assertEqual(code, 3)
        self.assertIn("suite: exit 3, 1 new, 0 known", out)

    def interrupt(self, sig):
        p = self.start("sleep", "30", start_new_session=True)
        for _ in range(50):
            if os.path.exists(os.path.join(self.slot, "holder")):
                break
            time.sleep(0.1)
        os.killpg(p.pid, sig)
        p.communicate(timeout=10)
        return p.returncode

    def test_sigint_to_the_group_releases_the_slot_and_exits_130(self):
        self.assertEqual(self.interrupt(signal.SIGINT), 130)
        self.assertFalse(os.path.exists(self.slot))

    def test_sigterm_to_the_group_releases_the_slot_and_exits_143(self):
        self.assertEqual(self.interrupt(signal.SIGTERM), 143)
        self.assertFalse(os.path.exists(self.slot))


FIXTURE = """\
✗ @cloudkey/ui  12.1s
 \x1b[31mFAIL\x1b[39m  test/chart-math.test.js > chart-math > pointGrid spreads points
 FAIL  test/glance-row.test.jsx > GlanceRow > renders the count
 FAIL  test/glance-row.test.jsx > GlanceRow > renders the count
FAIL  chart-heatmap: legend swatches — expected 5, got 4
FAIL client, ui — 12.1s wall, 40.0s of work
"""


class Reds(Case):
    def setUp(self):
        super().setUp()
        self.fixture = os.path.join(self.dir, "fixture.log")
        with open(self.fixture, "w") as f:
            f.write(FIXTURE)
        self.cat = ("sh", "-c", f"cat '{self.fixture}'; exit 1")

    def test_reds_are_sorted_against_the_flake_registry_and_recorded(self):
        subprocess.run([os.path.join(BIN, "cklog"), "flake", "add", "chart-math > pointGrid"], cwd=self.core,
                       env=self.env, check=True, capture_output=True)
        code, out = self.suite(*self.cat)
        self.assertIn("KNOWN RED test/chart-math.test.js > chart-math > pointGrid spreads points", out)
        self.assertIn("NEW RED test/glance-row.test.jsx > GlanceRow > renders the count", out)
        self.assertIn("NEW RED chart-heatmap: legend swatches\n", out)
        self.assertIn("suite: exit 1, 2 new, 1 known, waited 0s", out)
        [r] = self.runs()
        iso = r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ"
        self.assertEqual((r["exit"], r["new_reds"], r["known_reds"], r["cmd"][:5], r["worktree"], r["branch"]),
                         (1, 2, 1, "sh -c", self.core, "main"))
        self.assertEqual(r["head"], subprocess.run(["git", "-C", self.core, "rev-parse", "HEAD"],
                                                   capture_output=True, text=True).stdout.strip())
        self.assertRegex(r["started"], iso)
        self.assertRegex(r["ended"], iso)
        self.assertLessEqual(r["started"], r["ended"])
        self.assertLess(r["wait_ms"], 1000)
        self.assertTrue(r["log"].startswith(self.logs + "/"))
        with open(r["log"]) as f:
            self.assertIn("chart-heatmap: legend swatches — expected 5", f.read())

    def test_an_unowned_repos_reds_are_all_new(self):
        other = os.path.join(self.dir, "other")
        git("init", "-q", "-b", "main", other)
        self.assertIn("suite: exit 1, 3 new, 0 known", self.suite(*self.cat, cwd=other)[1])


class Naming(Case):
    def holder_and_log(self, cwd):
        out = self.suite("sh", "-c", 'cat "$SUITE_DIR/slot-0/holder"', cwd=cwd)[1]
        return re.search(r"(?m)^repo=(.*)$", out).group(1), os.listdir(self.logs)[0]

    def test_a_linked_worktree_is_named_for_its_repo(self):
        wt = os.path.join(self.dir, "core-wt")
        git("-C", self.core, "worktree", "add", "-q", wt)
        self.addCleanup(git, "-C", self.core, "worktree", "remove", "--force", wt)
        repo, log = self.holder_and_log(wt)
        self.assertEqual(repo, "core")
        self.assertRegex(log, r"-core-\d+\.log$")

    def test_a_dir_outside_git_is_named_for_itself(self):
        plain = os.path.join(self.dir, "plain")
        os.makedirs(plain)
        repo, log = self.holder_and_log(plain)
        self.assertEqual(repo, "plain")
        self.assertRegex(log, r"-plain-\d+\.log$")


if __name__ == "__main__":
    unittest.main(verbosity=1 if "-q" in sys.argv else 2)
