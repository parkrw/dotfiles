#!/usr/bin/env python3
# Tests for suite-gate.py, run as the hook: JSON in, a decision out. Builds a
# throwaway repo with a workspace subdir. HOOK overrides the gate under test.
#
#   python3 claude/.claude/hooks/scripts/test_suite_gate.py
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest

HOOK = os.environ.get("HOOK") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "suite-gate.py")


class Gate(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        t = os.path.realpath(cls.tmp.name)
        cls.repo, cls.web, cls.plain, cls.home = (os.path.join(t, p) for p in ("repo", "repo/apps/web", "plain", "home"))
        subprocess.run(["git", "init", "-q", "-b", "main", cls.repo], check=True)
        subprocess.run(["git", "init", "-q", "-b", "main", os.path.join(cls.home, "repo")], check=True)
        os.makedirs(cls.web)
        os.makedirs(cls.plain)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def hook(self, cmd, cwd, home=None):
        env = dict(os.environ, HOME=home or os.path.join(self.tmp.name, "nohome"))
        p = subprocess.run([HOOK], input=json.dumps({"tool_input": {"command": cmd}, "cwd": cwd}),
                           capture_output=True, text=True, env=env, cwd=self.repo)
        self.assertEqual(p.returncode, 0, p.stderr)
        return json.loads(p.stdout) if p.stdout else None

    def decision(self, cmd, cwd, **kw):
        out = self.hook(cmd, cwd, **kw)
        return out["hookSpecificOutput"]["permissionDecision"] if out else "defer"

    def check(self, cases, want):
        for cwd, cmd in cases:
            with self.subTest(cmd=cmd, cwd=cwd):
                self.assertEqual(self.decision(cmd, cwd), want)

    def test_full_root_runs_without_suite_are_denied(self):
        r, p, w = self.repo, self.plain, self.web
        self.check([
            (r, "npm test"), (r, "npm t"), (r, "npm run test"), (r, "npm run-script test"),
            (r, "npm test --silent"), (r, "npm test -s"), (r, "npm test --quiet"), (r, "npm test -q"),
            (r, "npm test --workspaces"), (r, "npm test -ws"), (r, "npm test --if-present"),
            (r, "CI=1 npm test"), (p, f"cd {r} && npm test"), (w, "cd ../.. && npm test 2>&1 | tail -20"),
            (p, f'cd "{r}" && npm test'), (p, f"cd '{r}' && npm test"),
            (r, "npm test > /tmp/out.log 2>&1"), (r, "git status; npm test"),
            (r, "npm test > /tmp/out.log 2>&1 &"), (r, "npm test &> /tmp/out.log"), (r, "npm test &>/tmp/out.log"),
            (r, "npm test < /dev/null"),
        ], "deny")

    def test_the_deny_names_the_suite_command(self):
        self.assertEqual(self.hook("npm test", self.repo)["hookSpecificOutput"]["permissionDecisionReason"],
                         "run: suite npm test (in background)")

    def test_scoped_runs_and_suite_runs_are_allowed(self):
        r, p, w = self.repo, self.plain, self.web
        self.check([
            (r, "suite npm test"), (p, f"cd {r} && suite npm test"), (r, "npm test -w @cloudkey/web"),
            (r, "npm run test --workspace=@cloudkey/web"), (r, "npm test -- apps/web/test/x.test.jsx"),
            (r, "npx vitest run apps/web/test/glance-row.test.jsx"), (w, "npm test"), (r, "cd apps/web && npm test"),
            (p, "npm test"), (r, "npm run test:coverage"), (r, "npm install"), (r, "echo npm test"),
        ], "defer")

    def test_text_a_command_writes_is_not_judged(self):
        self.check([
            (self.repo, "cat > notes.md <<'EOF'\nnpm test\nEOF"),
            (self.repo, "cat > notes.md <<\\EOF\nnpm test\nEOF"),
            (self.repo, "gh pr create --title t --body \"$(cat <<'EOF'\n```\nnpm test\n```\nEOF\n)\""),
            (self.repo, 'git commit -m "fix; npm test"'),
            (self.repo, 'git commit -m "fix\nnpm test"'),
            (self.repo, "npm test -- a#b"),
        ], "defer")

    def test_comments_continuations_and_heredoc_ends_do_not_hide_a_full_run(self):
        self.check([
            (self.repo, "npm test  # whole suite"),
            (self.repo, "# don't parallelise\nnpm test"),
            (self.repo, "npm test \\\n  --silent"),
            (self.repo, "true;# don't\nnpm test"),
            (self.repo, "cat <<<EOF\nnpm test"),
            (self.repo, "cat <<-EOF\nnpm test\n\tEOF\nnpm test"),
        ], "deny")

    def test_a_40_kb_command_is_judged_well_inside_the_hook_timeout(self):
        t = time.monotonic()
        self.assertEqual(self.decision("echo npm " + "x" * 40000, self.repo), "defer")
        self.assertLess(time.monotonic() - t, 3)

    def test_an_empty_cwd_falls_back_to_the_hooks_own_directory(self):
        self.assertEqual(self.decision("npm test", ""), "deny")

    def test_cd_home_resolves_against_home(self):
        self.assertEqual(self.decision("cd ~/repo && npm test", self.plain, home=self.home), "deny")
        self.assertEqual(self.decision("cd && npm test", os.path.join(self.home, "repo"), home=self.home), "defer")

    def test_the_kill_switch_lets_everything_through(self):
        hooks = os.path.join(self.home, ".claude/hooks")
        os.makedirs(hooks, exist_ok=True)
        open(os.path.join(hooks, ".no-suite-gate"), "w").close()
        self.addCleanup(os.remove, os.path.join(hooks, ".no-suite-gate"))
        self.assertEqual(self.decision("npm test", self.repo, home=self.home), "defer")

    def test_bad_input_fails_open(self):
        p = subprocess.run([HOOK], input="not json", capture_output=True, text=True)
        self.assertEqual((p.returncode, p.stdout), (0, ""))


if __name__ == "__main__":
    unittest.main(verbosity=1 if "-q" in sys.argv else 2)
