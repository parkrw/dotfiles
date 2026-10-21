#!/usr/bin/env node
// review-insights render — the review ledger as one HTML page with its data
// embedded, and a plain-text digest of the same numbers for writing its
// recommendations.
//
//   node render.mjs <ledger.json> --out <page.html> [--notes <notes.json>]
//
// <ledger.json> is `claude-review-stats --json`, which carries the area/cause
// taxonomy, so the meanings and remedies on the page are the ones the stats
// report prints. Every number is computed here, once per scope (all repos and
// each repo), and embedded; the page only draws. The digest goes to stdout.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const SEVERITIES = ["blocker", "major", "minor"];
const OUTCOMES = ["fixed", "elsewhere", "dropped", "resolved", "repeated", "open", "shipped"];
const EXAMPLES = 4;

function die(msg) {
  process.stderr.write(`review-insights: ${msg}\n`);
  process.exit(1);
}

function parseArgs(argv) {
  const o = { ledger: "", out: "", notes: "" };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--out") o.out = argv[++i] ?? "";
    else if (a === "--notes") o.notes = argv[++i] ?? "";
    else if (!a.startsWith("-") && !o.ledger) o.ledger = a;
    else die(`unknown argument: ${a}`);
  }
  if (!o.ledger || !o.out) die("usage: render.mjs <ledger.json> --out <page.html> [--notes <notes.json>]");
  return o;
}

const readJson = (p, what) => {
  try {
    return JSON.parse(fs.readFileSync(p, "utf8"));
  } catch (e) {
    die(`cannot read ${what} ${p}: ${e.message}`);
  }
};

const groupBy = (xs, key) => {
  const m = new Map();
  for (const x of xs) {
    const k = key(x);
    if (!m.has(k)) m.set(k, []);
    m.get(k).push(x);
  }
  return [...m];
};
const count = (xs, pred) => xs.reduce((n, x) => n + (pred(x) ? 1 : 0), 0);
const sum = (xs) => xs.reduce((a, b) => a + b, 0);
const quantile = (xs, q) => {
  if (!xs.length) return 0;
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.floor(q * s.length))];
};
const round = (x, d = 2) => Math.round(x * 10 ** d) / 10 ** d;
const repoPath = (r) => r.repo || r.worktree || "unknown";
const repoName = (r) => repoLabels.get(repoPath(r)) ?? "unknown";
const segments = (p, n) => p.split("/").filter(Boolean).slice(-n).join("/");
// "all" keys the all-repos scope, so no repo label may be "all".
function labelRepos(runs) {
  const paths = [...new Set(runs.map(repoPath))];
  return new Map(
    paths.map((p) => {
      const depth = p.split("/").filter(Boolean).length;
      let n = 1;
      while (n < depth && (segments(p, n) === "all" || paths.some((q) => q !== p && segments(q, n) === segments(p, n)))) n++;
      const label = segments(p, n);
      return [p, label && label !== "all" ? label : p];
    }),
  );
}
// A run with no verdict line failed closed; claude-review-stats does not count it as a round.
const roundsOf = (chain) => count(chain, (r) => r.verdict !== "none");
const sevRank = (s) => (SEVERITIES.indexOf(s) + 4) % 4;
const reviewerOf = (r) => `${r.engine}/${r.run?.models?.[0] ?? r.model ?? "?"}${r.effort ? `/${r.effort}` : ""}`;

const utcMondayOf = (ts) => {
  const d = new Date(ts);
  d.setUTCHours(0, 0, 0, 0);
  d.setUTCDate(d.getUTCDate() - ((d.getUTCDay() + 6) % 7));
  return d.toISOString().slice(0, 10);
};

const bySeverity = (fs) => Object.fromEntries(SEVERITIES.map((s) => [s, count(fs, (f) => f.severity === s)]));
const byOutcome = (fs) => Object.fromEntries(OUTCOMES.map((o) => [o, count(fs, (f) => f.outcome === o)]));
const examplesOf = (fs, runById) =>
  [...fs]
    .sort((a, b) => sevRank(a.severity) - sevRank(b.severity) || a.text.length - b.text.length)
    .slice(0, EXAMPLES)
    .map((f) => ({ severity: f.severity, path: f.path, line: f.line ?? null, text: f.text, repo: repoName(runById.get(f.run) ?? {}) }));

function aggregate(runs, findings, tax, runById) {
  const costs = runs.map((r) => r.run?.total_cost_usd).filter((c) => typeof c === "number");
  const mins = runs.map((r) => r.run?.duration_ms).filter((d) => typeof d === "number").map((d) => d / 60000);
  const chains = groupBy(runs, (r) => `${r.worktree}\0${r.branch}`).map(([, rs]) => rs.sort((a, b) => a.ts.localeCompare(b.ts)));
  const rounds = chains.map(roundsOf).filter(Boolean);
  // What a round follows: the first judges the task, a round after a FAIL
  // judges the fix, a round after a PASS judges new commits on a branch that
  // had already passed.
  const kinds = { first: [], afterFail: [], afterPass: [] };
  const kindOf = new Map();
  for (const c of chains) {
    const live = c.filter((r) => r.verdict !== "none");
    live.forEach((r, i) => {
      const k = i === 0 ? "first" : live[i - 1].verdict === "PASS" ? "afterPass" : "afterFail";
      kinds[k].push(r);
      kindOf.set(r, k);
    });
  }
  const priced = (rs) => {
    const cs = rs.map((r) => r.run?.total_cost_usd).filter((c) => typeof c === "number");
    return cs.length ? round(sum(cs)) : null;
  };
  const oneMinor = (r) => r.verdict === "FAIL" && r.findings.length === 1 && r.findings[0].severity === "minor";
  const kindStats = (rs) => ({ n: rs.length, fail: count(rs, (r) => r.verdict === "FAIL"), findings: sum(rs.map((r) => r.findings.length)), cost: priced(rs) });
  const roundKinds = { first: kindStats(kinds.first), afterFail: kindStats(kinds.afterFail), afterPass: kindStats(kinds.afterPass), oneMinor: count(runs, oneMinor) };
  const categorized = findings.filter((f) => f.cause && tax.causes[f.cause]);
  const rereviewed = groupBy(runs.filter((r) => r.diff && r.verdict !== "none"), (r) => r.diff).filter(([, rs]) => rs.length > 1);

  const causes = groupBy(categorized, (f) => f.cause)
    .map(([k, fs]) => ({
      key: k,
      meaning: tax.causes[k].meaning,
      remedy: tax.causes[k].remedy,
      n: fs.length,
      share: round(fs.length / categorized.length, 4),
      repeated: count(fs, (f) => f.outcome === "repeated"),
      severity: bySeverity(fs),
      examples: examplesOf(fs, runById),
    }))
    .sort((a, b) => b.n - a.n);

  const areas = groupBy(findings.filter((f) => f.area && tax.areas[f.area]), (f) => f.area)
    .map(([k, fs]) => ({ key: k, meaning: tax.areas[k], n: fs.length, severity: bySeverity(fs) }))
    .sort((a, b) => b.n - a.n);

  // Categorization runs on demand, so the cause and area tables stop at the
  // newest categorized finding; the date makes a stale table visible.
  const categorizedThrough = categorized.reduce((m, f) => (runById.get(f.run)?.ts > m ? runById.get(f.run).ts : m), "") || null;
  const uncategorizedSince = categorizedThrough ? count(findings, (f) => !(f.cause && tax.causes[f.cause]) && runById.get(f.run)?.ts > categorizedThrough) : 0;

  const firstLive = (c) => c.find((r) => r.verdict !== "none");
  const weeks = groupBy(runs, (r) => utcMondayOf(r.ts))
    .map(([w, rs]) => {
      const n = sum(rs.map((r) => r.findings.length));
      const started = chains.filter((c) => firstLive(c) && utcMondayOf(firstLive(c).ts) === w);
      return {
        week: w, reviews: rs.length, pass: count(rs, (r) => r.verdict === "PASS"), fail: count(rs, (r) => r.verdict === "FAIL"), findings: n, perReview: round(n / rs.length),
        branches: started.length, roundsMedian: quantile(started.map(roundsOf).filter(Boolean), 0.5), firstPass: count(started, (c) => firstLive(c).verdict === "PASS"),
        oneMinor: count(rs, oneMinor), afterPass: count(rs, (r) => kindOf.get(r) === "afterPass"), cost: priced(rs),
      };
    })
    .sort((a, b) => a.week.localeCompare(b.week));

  const reviewers = groupBy(runs, reviewerOf)
    .map(([k, rs]) => {
      const priced = rs.map((r) => r.run?.total_cost_usd).filter((c) => typeof c === "number");
      return { key: k, reviews: rs.length, fail: count(rs, (r) => r.verdict === "FAIL"), perReview: round(sum(rs.map((r) => r.findings.length)) / rs.length), costPerReview: priced.length ? round(sum(priced) / priced.length) : null };
    })
    .sort((a, b) => b.reviews - a.reviews);

  const repos = groupBy(runs, repoName)
    .map(([k, rs]) => {
      const cs = groupBy(rs, (r) => `${r.worktree}\0${r.branch}`).map(([, c]) => c);
      const priced = rs.map((r) => r.run?.total_cost_usd).filter((c) => typeof c === "number");
      return { key: k, reviews: rs.length, fail: count(rs, (r) => r.verdict === "FAIL"), perReview: round(sum(rs.map((r) => r.findings.length)) / rs.length), branches: cs.length, roundsMedian: quantile(cs.map(roundsOf).filter(Boolean), 0.5), cost: priced.length ? round(sum(priced)) : null };
    })
    .sort((a, b) => b.reviews - a.reviews);

  const branches = chains
    .map((c) => {
      const last = c[c.length - 1];
      const priced = c.map((r) => r.run?.total_cost_usd).filter((x) => typeof x === "number");
      return { branch: last.branch, repo: repoName(last), rounds: roundsOf(c), findings: sum(c.map((r) => r.findings.length)), cost: priced.length ? round(sum(priced)) : null, verdict: last.verdict, last: last.ts };
    })
    .sort((a, b) => b.rounds - a.rounds || b.findings - a.findings)
    .slice(0, 12);

  const hotspots = groupBy(findings, (f) => `${repoName(runById.get(f.run) ?? {})}\0${f.path}`)
    .map(([k, fs]) => {
      const [repo, file] = k.split("\0");
      return { repo, path: file, n: fs.length, severity: bySeverity(fs), branches: new Set(fs.map((f) => runById.get(f.run)?.branch)).size };
    })
    .sort((a, b) => b.n - a.n)
    .slice(0, 10);

  const attention = findings
    .filter((f) => f.outcome === "open" || f.outcome === "shipped")
    .map((f) => {
      const r = runById.get(f.run) ?? {};
      return { outcome: f.outcome, severity: f.severity, path: f.path, line: f.line ?? null, text: f.text, repo: repoName(r), branch: r.branch ?? "", ts: r.ts ?? "" };
    })
    .sort((a, b) => sevRank(a.severity) - sevRank(b.severity) || (a.outcome === b.outcome ? 0 : a.outcome === "open" ? -1 : 1) || b.ts.localeCompare(a.ts));

  return {
    range: { from: runs[0]?.ts ?? "", to: runs[runs.length - 1]?.ts ?? "" },
    runs: { n: runs.length, pass: count(runs, (r) => r.verdict === "PASS"), fail: count(runs, (r) => r.verdict === "FAIL"), none: count(runs, (r) => r.verdict === "none"), gate: count(runs, (r) => r.source === "gate"), transcript: count(runs, (r) => r.source === "transcript") },
    branchCount: chains.length,
    rounds: { median: quantile(rounds, 0.5), p90: quantile(rounds, 0.9), max: Math.max(0, ...rounds) },
    cost: { total: costs.length ? round(sum(costs)) : null, perReview: costs.length ? round(sum(costs) / costs.length) : null, minutesPerReview: mins.length ? round(sum(mins) / mins.length, 1) : null, priced: costs.length },
    findings: { n: findings.length, severity: bySeverity(findings), outcome: byOutcome(findings), categorized: categorized.length, perReview: runs.length ? round(findings.length / runs.length) : 0 },
    late: Object.fromEntries(groupBy(findings.filter((f) => f.late), (f) => f.late).map(([k, fs]) => [k, fs.length])),
    flaky: { rereviewed: rereviewed.length, flipped: rereviewed.filter(([, rs]) => new Set(rs.map((r) => r.verdict)).size > 1).length },
    roundKinds,
    categorizedThrough,
    uncategorizedSince,
    causes,
    areas,
    weeks,
    reviewers,
    repos,
    branches,
    hotspots,
    attention: { open: count(attention, (a) => a.outcome === "open"), shipped: count(attention, (a) => a.outcome === "shipped"), items: attention.slice(0, 40) },
  };
}

function digest(scopes) {
  const a = scopes.all;
  const pct = (x) => `${Math.round(x * 100)}%`;
  const clip = (s, n) => (s.length > n ? `${s.slice(0, n)}…` : s);
  const usd = (x) => (x == null ? "n/a" : `$${x}`);
  const L = [];
  L.push(`REVIEW LEDGER ${a.range.from.slice(0, 10)} .. ${a.range.to.slice(0, 10)}`);
  L.push(`reviews ${a.runs.n} (PASS ${a.runs.pass}, FAIL ${a.runs.fail}); ${a.runs.transcript} imported from transcripts, ${a.runs.gate} recorded by the gate`);
  L.push(`branches ${a.branchCount}; rounds per branch median ${a.rounds.median}, p90 ${a.rounds.p90}, max ${a.rounds.max}`);
  L.push(`cost ${usd(a.cost.total)} over ${a.cost.priced} priced reviews, ${usd(a.cost.perReview)}/review, ${a.cost.minutesPerReview ?? "n/a"} min/review`);
  L.push(`findings ${a.findings.n} (${a.findings.perReview}/review): blocker ${a.findings.severity.blocker}, major ${a.findings.severity.major}, minor ${a.findings.severity.minor}; categorized ${a.findings.categorized}, uncategorized ${a.findings.n - a.findings.categorized}`);
  L.push(`outcomes ${OUTCOMES.map((o) => `${o} ${a.findings.outcome[o]}`).join(", ")}`);
  L.push(`flaky: ${a.flaky.flipped} of ${a.flaky.rereviewed} unchanged diffs reviewed twice changed verdict`);
  const kind = (k) => `${k.n} (${usd(k.cost)}, ${k.findings} findings)`;
  L.push(`rounds: first ${kind(a.roundKinds.first)}, after a FAIL ${kind(a.roundKinds.afterFail)}, after a PASS ${kind(a.roundKinds.afterPass)}; FAIL rounds listing one minor only ${a.roundKinds.oneMinor} of ${a.runs.fail}`);
  L.push(`late finds: after-file-change ${a.late["after-file-change"] ?? 0}, after-other-change ${a.late["after-other-change"] ?? 0}, missed-earlier ${a.late["missed-earlier"] ?? 0}, unknown ${a.late.unknown ?? 0}`);
  L.push(`categorized through ${a.categorizedThrough ? a.categorizedThrough.slice(0, 10) : "n/a"}; ${a.uncategorizedSince} findings since then have no cause, so CAUSES and AREAS stop there`);
  L.push("");
  L.push("REPOS (reviews, FAIL rate, findings/review, branches, median rounds, cost)");
  for (const r of a.repos) L.push(`  ${r.key}: ${r.reviews}, ${pct(r.fail / r.reviews)}, ${r.perReview}, ${r.branches}, ${r.roundsMedian}, ${usd(r.cost)}`);
  L.push("");
  L.push("WEEKS (week, reviews, FAIL, findings/review, branches started, median rounds, first-round PASS, one-minor FAILs, rounds after a PASS, cost)");
  for (const w of a.weeks) L.push(`  ${w.week}: ${w.reviews}, ${w.fail}, ${w.perReview}, ${w.branches}, ${w.roundsMedian}, ${w.branches ? pct(w.firstPass / w.branches) : "-"}, ${w.oneMinor}, ${w.afterPass}, ${usd(w.cost)}`);
  L.push("");
  L.push("CAUSES (why the author's change let it through; share of categorized findings)");
  for (const c of a.causes) {
    L.push(`  ${c.key}: ${c.n} (${pct(c.share)}), repeated ${c.repeated}, blocker ${c.severity.blocker} major ${c.severity.major} minor ${c.severity.minor} — remedy: ${c.remedy || "none"}`);
    for (const e of c.examples) L.push(`    [${e.severity}] ${e.repo} ${e.path}${e.line ? `:${e.line}` : ""} — ${clip(e.text, 220)}`);
  }
  L.push("");
  L.push("AREAS (what the defect is)");
  for (const r of a.areas) L.push(`  ${r.key}: ${r.n}, blocker ${r.severity.blocker} major ${r.severity.major} minor ${r.severity.minor}`);
  L.push("");
  L.push("HOTSPOTS (files with the most findings)");
  for (const h of a.hotspots) L.push(`  ${h.repo} ${h.path}: ${h.n} across ${h.branches} branches`);
  L.push("");
  L.push(`STILL LISTED (open ${a.attention.open}: last review failed with it; shipped ${a.attention.shipped}: last review passed with it listed)`);
  for (const f of a.attention.items.slice(0, 12)) L.push(`  ${f.outcome} [${f.severity}] ${f.repo} ${f.branch} ${f.path}${f.line ? `:${f.line}` : ""} — ${clip(f.text, 160)}`);
  return L.join("\n") + "\n";
}

const opts = parseArgs(process.argv.slice(2));
const ledger = readJson(opts.ledger, "ledger");
if (!ledger.taxonomy?.causes || !ledger.taxonomy?.areas) die("ledger has no taxonomy; regenerate it with a current claude-review-stats --json");
const notes = opts.notes ? readJson(opts.notes, "notes") : null;

const runs = (ledger.runs ?? []).filter((r) => r.ts).sort((a, b) => a.ts.localeCompare(b.ts));
const runById = new Map(runs.map((r) => [r.id, r]));
const findings = (ledger.findings ?? []).filter((f) => runById.has(f.run));
for (const r of runs) r.findings = [];
for (const f of findings) runById.get(f.run).findings.push(f);
if (!runs.length) die("the ledger has no runs");
const repoLabels = labelRepos(runs);

const scopes = { all: aggregate(runs, findings, ledger.taxonomy, runById) };
for (const [repo, rs] of groupBy(runs, repoName)) {
  const ids = new Set(rs.map((r) => r.id));
  scopes[repo] = aggregate(rs, findings.filter((f) => ids.has(f.run)), ledger.taxonomy, runById);
}

const explorer = findings.map((f) => {
  const r = runById.get(f.run);
  return { s: f.severity, p: f.path, l: f.line ?? null, t: f.text, e: f.effect ?? "", a: f.area ?? "", c: f.cause ?? "", o: f.outcome, r: repoName(r), b: r.branch, ts: r.ts.slice(0, 10) };
});

const data = { generated: new Date().toISOString(), taxonomy: ledger.taxonomy, scopes, explorer, notes };
const here = path.dirname(fileURLToPath(import.meta.url));
const template = fs.readFileSync(path.join(here, "page.html"), "utf8");
const marker = "__REVIEW_INSIGHTS_DATA__";
if (!template.includes(marker)) die(`page.html has no ${marker} marker`);
// A finding's text can hold "</script>"; escaping every "<" keeps it inside the JSON block.
const page = template.replace(marker, () => JSON.stringify(data).replace(/</g, "\\u003c"));
fs.writeFileSync(opts.out, page);
process.stdout.write(digest(scopes));
process.stderr.write(`review-insights: wrote ${opts.out} (${Math.round(page.length / 1024)} KB)${notes ? "" : " without recommendations"}\n`);
