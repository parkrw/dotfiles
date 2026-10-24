#!/usr/bin/env python3
# Tests for tasklog and its cklog/vanlog names, run as the CLI. Builds
# throwaway repos whose origins are fake CloudKey, vanillin and personal URLs;
# nothing is fetched. TASKLOG_DIR keeps each test's DBs in a temp dir.
#
#   python3 scripts/.local/bin/test_tasklog.py
import datetime
import json
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor

BIN = os.path.dirname(os.path.abspath(__file__))
TODAY = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")


def git(*argv):
    subprocess.run(["git", *argv], check=True, capture_output=True)


class Case(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.repos = {}
        for name, origin in [
            ("core", "https://github.com/CloudKey-io/core.git"),
            ("core-ssh", "git@github.com:cloudkey-io/core"),
            ("core-sshurl", "ssh://git@github.com/CloudKey-io/core.git"),
            ("core-token", "https://x-access-token:t0k@github.com/CloudKey-io/core/"),
            ("web", "https://github.com/CloudKey-io/web"),
            ("van", "https://github.com/parkrw/vanillin.git"),
            ("other", "https://github.com/parkrw/gorag.git"),
            ("noorigin", None),
        ]:
            path = os.path.join(cls.tmp.name, name)
            git("init", "-q", "-b", "main", path)
            if origin:
                git("-C", path, "remote", "add", "origin", origin)
            cls.repos[name] = os.path.realpath(path)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def setUp(self):
        d = tempfile.TemporaryDirectory()
        self.addCleanup(d.cleanup)
        self.dir = d.name
        self.env = dict(os.environ, TASKLOG_DIR=os.path.join(self.dir, "db"))
        self.env.pop("CLAUDE_CODE_SESSION_ID", None)

    # A read-only reader cannot checkpoint, so a DB last closed by one keeps
    # its -wal and -shm files beside it.
    def dbs(self):
        return sorted(f for f in os.listdir(self.env["TASKLOG_DIR"]) if f.endswith(".db"))

    def run_cli(self, *argv, repo="core", tool="cklog", stdin="", env=None):
        exe = tool if os.path.isabs(tool) else os.path.join(BIN, tool)
        return subprocess.run([exe, *argv], cwd=self.repos[repo], input=stdin, capture_output=True,
                              text=True, env=dict(self.env, **(env or {})))

    def ok(self, *argv, **kw):
        p = self.run_cli(*argv, **kw)
        self.assertEqual(p.returncode, 0, p.stderr)
        return p.stdout

    def fails(self, code, *argv, **kw):
        p = self.run_cli(*argv, **kw)
        self.assertEqual(p.returncode, code, f"stdout: {p.stdout} stderr: {p.stderr}")
        return p.stderr

    def db(self, name="ck.db"):
        c = sqlite3.connect(os.path.join(self.env["TASKLOG_DIR"], name), isolation_level=None)
        self.addCleanup(c.close)
        return c

    def sql(self, query, name="ck.db"):
        return self.db(name).execute(query).fetchone()[0]

    def seed(self):
        self.ok("plan", "add", "platform-overview", "--path", "PLAN.md", "--title", "Platform overview")
        self.ok("state", "platform-overview", "P5", "building", "--branch", "overview-p5", "--head",
                "abc123def456789", "--subject", "web: glance row", "--worktree", "/wt/core-p5")
        self.ok("state", "platform-overview", "P5", "ready", "--pr", "412")


class Names(Case):
    def test_each_name_refuses_a_repo_it_does_not_own(self):
        for tool, repo in [("vanlog", "core"), ("cklog", "van"), ("cklog", "other"),
                           ("tasklog", "other"), ("tasklog", "noorigin")]:
            with self.subTest(tool=tool, repo=repo):
                self.fails(2, "plan", "list", tool=tool, repo=repo)

    def test_tasklog_picks_ck_from_a_core_origin(self):
        self.ok("plan", "list", tool="tasklog")
        self.assertEqual(self.dbs(), ["ck.db"])

    def test_a_name_that_is_no_log_resolves_by_origin(self):
        link = os.path.join(self.dir, "constructorlog")
        os.symlink(os.path.join(BIN, "tasklog"), link)
        self.ok("plan", "list", tool=link)

    def test_the_names_keep_separate_dbs(self):
        self.ok("plan", "list")
        self.ok("plan", "list", tool="vanlog", repo="van")
        self.assertEqual(self.dbs(), ["ck.db", "van.db"])

    def test_a_fresh_db_is_migrated_to_wal(self):
        self.ok("plan", "list")
        got = self.sql("SELECT (SELECT user_version FROM pragma_user_version) || ' ' || "
                       "(SELECT journal_mode FROM pragma_journal_mode) || ' ' || "
                       "(SELECT group_concat(name) FROM (SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name))")
        self.assertEqual(got, "1 wal decisions,events,flakes,plans,prs,suite_runs")

    def test_an_empty_tasklog_dir_uses_the_default_dir(self):
        home = os.path.join(self.dir, "home")
        self.ok("plan", "list", env={"HOME": home, "TASKLOG_DIR": ""})
        self.assertTrue(os.path.isfile(os.path.join(home, ".local/state/claude/tasks/ck.db")))


class State(Case):
    def test_bad_input_fails(self):
        self.ok("plan", "add", "platform-overview")
        for argv in [("plan", "add", "platform-overview"), ("state", "nope", "P1", "building"),
                     ("plan", "add", ""), ("event", "platform-overview", " ", "note"),
                     ("state", "platform-overview", "P1", "done"),
                     ("state", "platform-overview", "P5", "ready", "--pr", "abc")]:
            with self.subTest(argv=argv):
                self.fails(1, *argv)

    def test_state_changes_only_what_it_names(self):
        self.seed()
        row = json.loads(self.ok("show", "--json", "platform-overview"))[0]
        self.assertEqual([row[k] for k in ("code", "state", "pr", "branch", "head", "subject")],
                         ["P5", "ready", 412, "overview-p5", "abc123def456789", "web: glance row"])

    def test_show_prints_a_table(self):
        self.seed()
        out = self.ok("show", "platform-overview")
        self.assertRegex(out, r"(?m)^plan +code +state +pr +branch +head +updated +subject$")
        self.assertRegex(out, r"(?m)^platform-overview +P5 +ready +412 +overview-p5 +abc123def456 +"
                              r"\d{4}-\d\d-\d\dT\d\d:\d\d +web: glance row$")

    def test_every_clone_of_core_sees_the_same_plan(self):
        self.seed()
        for repo in ("core-ssh", "core-sshurl", "core-token"):
            with self.subTest(repo=repo):
                self.assertIn("overview-p5", self.ok("show", "platform-overview", repo=repo))

    def test_state_writes_state_events(self):
        self.seed()
        out = self.ok("log", "platform-overview", "P5")
        self.assertIn("state  building branch=overview-p5 worktree=/wt/core-p5 head=abc123def456789 "
                      "subject=web: glance row", out)
        self.assertIn("state  ready pr=412", out)

    def test_show_hides_closed_rows_unless_all(self):
        self.seed()
        for code, state in [("P4", "merged"), ("P3", "dropped"), ("P2", "blocked")]:
            self.ok("state", "platform-overview", code, state)
        out = self.ok("show")
        self.assertNotIn("P4", out)
        self.assertNotIn("P3", out)
        self.assertIn("P5", out)
        self.assertIn("P2", out)
        out = self.ok("show", "--all")
        self.assertIn("P4", out)
        self.assertIn("P3", out)
        self.assertIn("platform-overview  2     Platform overview", self.ok("plan", "list"))

    def test_log_since(self):
        self.seed()
        self.fails(1, "log", "platform-overview", "--since", "soon")
        self.assertEqual(self.ok("log", "platform-overview", "--since", "2999-01-01"), "")
        self.assertIn("state  ready", self.ok("log", "platform-overview", "P5", "--since", "2000-01-01"))

    def test_plans_and_show_belong_to_their_repo(self):
        self.seed()
        self.assertEqual(self.ok("plan", "list", repo="web"), "")
        self.fails(1, "show", "platform-overview", repo="web")


class Text(Case):
    def test_stdin_text_lands_byte_for_byte(self):
        self.seed()
        text = "it's \"done\" — ran `git push origin main` && $(rm -rf /)\nsecond line"
        self.ok("event", "platform-overview", "P5", "note", "-", stdin=text)
        self.assertEqual(self.sql("SELECT text FROM events WHERE kind = 'note'"), text)

    def test_an_event_with_no_text_logs_its_kind_alone(self):
        self.seed()
        self.ok("event", "platform-overview", "P6", "started")
        out = self.ok("log", "platform-overview", "P6")
        self.assertRegex(out, r"^[^\n]*  P6  started\n$")

    def test_the_session_id_is_stored(self):
        self.seed()
        self.ok("event", "platform-overview", "P5", "review", "round 1", env={"CLAUDE_CODE_SESSION_ID": "sess-1"})
        self.assertEqual(self.sql("SELECT session FROM events WHERE kind = 'review'"), "sess-1")


class Concurrency(Case):
    # As in core, the first open sets WAL with no lock around it, so these
    # race against a DB that exists, which is every run after the first.
    def race(self, argvs):
        self.ok("plan", "add", "race")
        with ThreadPoolExecutor(len(argvs)) as pool:
            return list(pool.map(lambda argv: self.run_cli(*argv), argvs))

    def test_20_concurrent_plan_adds_all_land(self):
        runs = self.race([("plan", "add", f"race-{i}") for i in range(20)])
        self.assertEqual([p.stderr for p in runs if p.returncode], [])
        self.assertEqual(len(re.findall(r"(?m)^race-", self.ok("plan", "list"))), 20)

    def test_20_concurrent_events_all_land(self):
        runs = self.race([("event", "race", "R1", "tick", f"writer {i}") for i in range(20)])
        self.assertEqual([p.stderr for p in runs if p.returncode], [])
        self.assertEqual(self.ok("log", "race").count("tick  writer"), 20)

    def test_a_read_runs_while_another_session_holds_the_write_lock(self):
        self.seed()
        writer = self.db()
        writer.execute("BEGIN IMMEDIATE")
        self.addCleanup(writer.execute, "ROLLBACK")
        self.assertIn("overview-p5", self.ok("show"))


class Flakes(Case):
    def match(self, *ids, repo="core"):
        return self.ok("flake", "match", repo=repo, stdin="\n".join(ids) + "\n")

    def test_match_sorts_known_and_new_and_counts_sightings(self):
        self.ok("flake", "add", "chart-math > pointGrid", "load-sensitive")
        self.ok("flake", "add", "panel-table padding", "first note")
        self.ok("flake", "add", "panel-table padding")
        self.assertEqual(self.match("packages/ui/test/chart-math.test.js > chart-math > pointGrid spreads points",
                                    "apps/web/test/glance-row.test.jsx > renders", ""),
                         "KNOWN packages/ui/test/chart-math.test.js > chart-math > pointGrid spreads points\n"
                         "NEW apps/web/test/glance-row.test.jsx > renders\n")
        out = self.ok("flake", "list")
        self.assertIn(f"chart-math > pointGrid  1     {TODAY}", out)
        self.assertIn("panel-table padding     0", out)
        self.assertNotIn("first note", out)

    def test_a_blank_id_is_refused(self):
        self.fails(1, "flake", "add", "")
        self.fails(1, "flake", "add", " ")
        self.assertEqual(self.match("apps/web/test/new.test.jsx > breaks"), "NEW apps/web/test/new.test.jsx > breaks\n")

    def test_flakes_belong_to_their_repo(self):
        self.ok("flake", "add", "chart-math > pointGrid")
        self.assertEqual(self.ok("flake", "list", tool="vanlog", repo="van"), "")
        self.assertEqual(self.ok("flake", "list", repo="web"), "")
        self.assertEqual(self.match("chart-math > pointGrid spreads points", repo="web"),
                         "NEW chart-math > pointGrid spreads points\n")

    def test_rm(self):
        self.ok("flake", "add", "panel-table padding")
        self.ok("flake", "rm", "panel-table padding")
        self.fails(1, "flake", "rm", "panel-table padding")
        self.ok("flake", "add", " padded id ")
        self.ok("flake", "rm", " padded id ")


class Brief(Case):
    def test_brief_carries_the_row_decisions_events_and_flakes(self):
        self.seed()
        self.ok("decide", "platform-overview", "-", "--by", "human", "--quote", "don't hide it",
                stdin='keep "hide" off\n')
        self.ok("event", "platform-overview", "P5", "review", "round 1: 2 findings")
        self.ok("flake", "add", "chart-math > pointGrid", "load-sensitive")
        out = self.ok("brief", "platform-overview", "P5")
        for want in ["# platform-overview P5 — Platform overview",
                     f"Plan: {self.repos['core']}/PLAN.md",
                     "- worktree: /wt/core-p5",
                     "- pr: 412",
                     "keep \"hide\" off (human)\n  > don't hide it",
                     "review: round 1: 2 findings",
                     "- `chart-math > pointGrid` — load-sensitive"]:
            self.assertIn(want, out)

    def test_brief_keeps_the_last_10_events_of_its_code_oldest_first(self):
        self.seed()
        for i in range(1, 13):
            self.ok("event", "platform-overview", "P7", "tick", f"e{i:02d}")
        self.ok("event", "platform-overview", "P8", "tick", "other code")
        out = self.ok("brief", "platform-overview", "P7")
        self.assertEqual(re.findall(r"tick: (e\d+)", out), [f"e{i:02d}" for i in range(3, 13)])
        section = out.split("## Last 10 events")[1].split("## Known flakes")[0]
        self.assertEqual(len(re.findall(r"(?m)^- ", section)), 10)

    def test_brief_of_a_bare_plan_says_what_is_missing(self):
        self.ok("plan", "add", "bare")
        out = self.ok("brief", "bare", "B1")
        self.assertTrue(out.startswith("# bare B1\n\nPlan: none recorded\n"), out)
        for want in ["No row yet.", "## Decisions\n\nNone recorded.", "## Last 10 events\n\nNone recorded.",
                     "## Known flakes\n\nNone recorded."]:
            self.assertIn(want, out)

    def test_a_multi_line_quote_stays_in_the_blockquote(self):
        self.ok("plan", "add", "bare")
        self.ok("decide", "bare", "-", "--quote", "line one\nline two", stdin="ship it\n")
        out = self.ok("brief", "bare", "B1")
        self.assertIn(f"- {TODAY} ship it\n", out)
        self.assertIn("  > line one\n  > line two", out)


class Transactions(Case):
    def setUp(self):
        super().setUp()
        self.ok("plan", "add", "tx")
        self.ok("state", "tx", "T1", "building")
        self.ok("flake", "add", "one")
        self.ok("flake", "add", "two")

    def test_state_keeps_the_row_when_its_event_fails(self):
        self.db().execute("CREATE TRIGGER no_state BEFORE INSERT ON events WHEN NEW.kind = 'state' "
                          "AND NEW.text LIKE 'ready%' BEGIN SELECT RAISE(ABORT, 'injected'); END")
        self.fails(1, "state", "tx", "T1", "ready")
        self.assertEqual(self.sql("SELECT state FROM prs WHERE code = 'T1'"), "building")

    def test_a_failed_match_records_no_sighting(self):
        self.db().execute("CREATE TRIGGER no_two BEFORE UPDATE ON flakes WHEN NEW.test_id = 'two' "
                          "BEGIN SELECT RAISE(ABORT, 'injected'); END")
        self.fails(1, "flake", "match", stdin="x one\nx two\n")
        self.assertEqual(self.sql("SELECT sum(seen) FROM flakes"), 0)


class Usage(Case):
    def test_bad_commands_fail_with_usage(self):
        self.fails(1, "frob")
        self.fails(1, "toString")
        self.assertIn("plan add <slug> | plan list", self.fails(1, "plan", "frob"))
        self.assertIn("flake add <test_id> [note] | list | rm <test_id> | match", self.fails(1, "flake", "frob"))
        self.fails(1, "show", "--frob")

    def test_argument_counts_are_exact(self):
        self.ok("plan", "add", "platform-overview")
        self.fails(1, "event", "platform-overview", "P5", "note", "hello", "world")
        self.fails(1, "state", "platform-overview", "P5")


if __name__ == "__main__":
    unittest.main(verbosity=1 if "-q" in sys.argv else 2)
