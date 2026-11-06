#!/usr/bin/env python3
# Tests for owed, run as the CLI. TASKLOG_DIR keeps each test's DB in a temp
# dir; the repos are throwaway inits with fake origins, nothing is fetched.
#
#   python3 scripts/.local/bin/test_owed.py
import datetime
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor

BIN = os.path.dirname(os.path.abspath(__file__))
OWED = os.path.join(BIN, "owed")
TODAY = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")


def git(*argv):
    subprocess.run(["git", *argv], check=True, capture_output=True)


class Case(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.repos = {}
        for name, origin in [
            ("core", "git@github.com:CloudKey-io/core.git"),
            ("van", "https://github.com/parkrw/vanillin"),
            ("plain", None),
        ]:
            path = os.path.join(cls.tmp.name, name)
            git("init", "-q", "-b", "main", path)
            if origin:
                git("-C", path, "remote", "add", "origin", origin)
            cls.repos[name] = os.path.realpath(path)
        cls.repos["nowhere"] = os.path.realpath(os.path.join(cls.tmp.name, "scratch dir"))
        os.makedirs(cls.repos["nowhere"])

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def setUp(self):
        d = tempfile.TemporaryDirectory()
        self.addCleanup(d.cleanup)
        self.env = dict(os.environ, TASKLOG_DIR=os.path.join(d.name, "db"))
        self.env.pop("CLAUDE_CODE_SESSION_ID", None)

    def run_cli(self, *argv, repo="core", stdin="", env=None):
        return subprocess.run([OWED, *argv], cwd=self.repos[repo], input=stdin, capture_output=True,
                              text=True, env=dict(self.env, **(env or {})))

    def ok(self, *argv, **kw):
        p = self.run_cli(*argv, **kw)
        self.assertEqual(p.returncode, 0, p.stderr)
        return p.stdout

    def fails(self, *argv, **kw):
        p = self.run_cli(*argv, **kw)
        self.assertEqual(p.returncode, 1, f"stdout: {p.stdout} stderr: {p.stderr}")
        return p.stderr

    def test_add_lists_and_done_hides(self):
        self.assertEqual(self.ok("add", "merge PR 12"), "owed 1: merge PR 12\n")
        self.ok("add", "approve the deploy", repo="van")
        out = self.ok()
        self.assertIn(f"1   {TODAY}  CloudKey-io/core  merge PR 12", out)
        self.assertIn(f"2   {TODAY}  parkrw/vanillin   approve the deploy", out)
        self.assertEqual(self.ok("done", "1"), "done 1: merge PR 12\n")
        self.assertNotIn("merge PR 12", self.ok("list"))
        self.assertIn("approve the deploy", self.ok("list"))
        all_rows = self.ok("list", "--all")
        self.assertIn("merge PR 12", all_rows)
        self.assertIn("done", all_rows.splitlines()[0])

    def test_no_items_prints_nothing(self):
        self.assertEqual(self.ok(), "")

    def test_the_tag_falls_back_to_the_directory_name(self):
        self.ok("add", "x", repo="plain")
        self.ok("add", "y", repo="nowhere")
        out = self.ok("list")
        self.assertIn("  plain  ", out)
        self.assertIn("  scratch dir  ", out)

    def test_stdin_text_lands_byte_for_byte(self):
        text = "gh pr merge https://github.com/CloudKey-io/core/pull/9 --squash --match-head-commit abc 'q' \"dq\" $x `b`"
        self.ok("add", "-", stdin=text + "\n")
        self.assertIn(text, self.ok())

    def test_the_session_id_is_stored(self):
        self.ok("add", "x", env={"CLAUDE_CODE_SESSION_ID": "sess-1"})
        self.ok("add", "y")
        c = sqlite3.connect(os.path.join(self.env["TASKLOG_DIR"], "memory.db"))
        self.addCleanup(c.close)
        self.assertEqual([r[0] for r in c.execute("SELECT session FROM owed ORDER BY id")], ["sess-1", None])

    def test_done_takes_several_ids_and_is_idempotent(self):
        for t in "abc":
            self.ok("add", t)
        self.assertEqual(self.ok("done", "1", "3"), "done 1: a\ndone 3: c\n")
        self.assertEqual(self.ok("done", "1"), "done 1: a\n")
        self.assertEqual(self.ok().count("\n"), 2)

    def test_bad_input_fails(self):
        self.assertIn("no item 7", self.fails("done", "7"))
        self.assertIn("ids", self.fails("done", "seven"))
        self.assertIn("blank", self.fails("add", "-", stdin="  \n"))
        self.assertIn("commands", self.fails("frob"))
        self.assertIn("arguments", self.fails("add"))
        self.assertEqual(self.ok(), "")

    def test_a_failed_done_marks_nothing(self):
        self.ok("add", "a")
        self.fails("done", "1", "9")
        self.assertIn("a", self.ok())

    def test_20_concurrent_adds_all_land(self):
        with ThreadPoolExecutor(20) as pool:
            list(pool.map(lambda i: self.ok("add", f"item {i}"), range(20)))
        self.assertEqual(self.ok().count("\n"), 21)

    def test_owed_keeps_its_own_db_beside_tasklogs(self):
        self.ok("add", "a")
        self.assertEqual(sorted(f for f in os.listdir(self.env["TASKLOG_DIR"]) if f.endswith(".db")), ["memory.db"])


if __name__ == "__main__":
    unittest.main()
